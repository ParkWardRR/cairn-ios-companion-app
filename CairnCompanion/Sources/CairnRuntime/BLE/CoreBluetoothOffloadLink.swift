import CairnKit
import CairnProtocol
import CoreBluetooth
import Foundation

/// The offload characteristics of the connected dongle, as `OffloadClient`'s `OffloadLink`.
///
/// `CoreBluetoothCentral` owns the peripheral and its delegate callbacks and forwards the three
/// that matter here: an indication on `OFFLOAD_CONTROL`, a notification on `OFFLOAD_DATA`, and
/// the radio clearing after backpressure. Everything touching CoreBluetooth runs on the main
/// actor.
public final class CoreBluetoothOffloadLink: OffloadLink, @unchecked Sendable {
    public enum LinkError: Error { case notConnected, writeFailed(String) }

    private let peripheral: CBPeripheral
    private let control: CBCharacteristic
    private let data: CBCharacteristic
    private let continuation: AsyncStream<OffloadWireEvent>.Continuation
    public let events: AsyncStream<OffloadWireEvent>
    public let attMTU: Int

    // Main-actor state: the write in flight, and anyone waiting for the radio to clear.
    @MainActor private var controlWrite: CheckedContinuation<Void, Error>?
    @MainActor private var radioWaiters: [CheckedContinuation<Void, Never>] = []
    @MainActor private var ended = false

    @MainActor
    init(peripheral: CBPeripheral, control: CBCharacteristic, data: CBCharacteristic) {
        self.peripheral = peripheral
        self.control = control
        self.data = data
        // ATT MTU = the largest write-without-response payload plus the 3-byte ATT header.
        self.attMTU = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        var c: AsyncStream<OffloadWireEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        self.continuation = c
    }

    // MARK: - OffloadLink

    public func writeControl(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                guard !self.ended, self.peripheral.state == .connected else {
                    return done.resume(throwing: LinkError.notConnected)
                }
                self.controlWrite = done
                self.peripheral.writeValue(bytes, for: self.control, type: .withResponse)
            }
        }
    }

    public func writeData(_ frames: [Data]) async throws {
        for frame in frames {
            await waitForRadio()
            try await MainActor.run {
                guard !self.ended, self.peripheral.state == .connected else { throw LinkError.notConnected }
                self.peripheral.writeValue(frame, for: self.data, type: .withoutResponse)
            }
        }
    }

    @MainActor
    private func waitForRadio() async {
        while !ended && !peripheral.canSendWriteWithoutResponse {
            await withCheckedContinuation { radioWaiters.append($0) }
        }
    }

    // MARK: - Forwarded by the central, on the main actor

    @MainActor func received(_ which: CairnGATT.Characteristic, value: Data) {
        switch which {
        case .offloadControl: continuation.yield(.indication(value))
        case .offloadData: continuation.yield(.notification(value))
        default: break
        }
    }

    @MainActor func controlWriteFinished(error: Error?) {
        guard let pending = controlWrite else { return }
        controlWrite = nil
        if let error {
            pending.resume(throwing: LinkError.writeFailed(error.localizedDescription))
        } else {
            pending.resume()
        }
    }

    @MainActor func radioReady() {
        let waiting = radioWaiters
        radioWaiters = []
        waiting.forEach { $0.resume() }
    }

    /// The connection is gone, or the central is done with this link. Anything waiting is
    /// released rather than left hanging: an offload that cannot finish must fail, not stall.
    @MainActor func end() {
        guard !ended else { return }
        ended = true
        controlWrite?.resume(throwing: LinkError.notConnected)
        controlWrite = nil
        radioReady()
        continuation.yield(.disconnected)
        continuation.finish()
    }
}
