import CairnProtocol
import Foundation

public enum OffloadClientError: Error, Equatable, Sendable {
    /// The dongle refused the request itself (`BUSY`, `TRIP_ACTIVE`, `UNKNOWN_BUNDLE`, ...).
    case refused(OffloadOpcode, OffloadStatus)
    /// A transfer failed its length, sequence or CRC check on every attempt.
    case transferFailed(OffloadTransferFailure)
    /// The receipt upload ended without an outcome. Nothing was stored or deleted.
    case receiptUploadFailed(OffloadStatus)
    case timedOut(OffloadOpcode)
    case disconnected
    /// The link's MTU is below what the dongle serves (43).
    case mtuTooSmall(Int)
    case protocolViolation(String)
}

/// One offload conversation with a dongle: the requests of offload.md section 3 as async calls.
/// The dongle serves one operation at a time and so does this client (callers `await` each).
public actor OffloadClient {
    private let link: any OffloadLink
    private let timeout: Duration
    private let maxTransferAttempts: Int
    private var session = OffloadSession()
    private var eventTask: Task<Void, Never>?
    private var inbox: [UInt8: [OffloadEvent]] = [:]
    private var waiters: [UInt8: (generation: Int, continuation: CheckedContinuation<OffloadEvent, Error>)] = [:]
    private var generation = 0
    private var ended = false

    public init(link: any OffloadLink, timeout: Duration = .seconds(12), maxTransferAttempts: Int = 3) {
        self.link = link
        self.timeout = timeout
        self.maxTransferAttempts = maxTransferAttempts
        session.updateMTU(link.attMTU)
    }

    /// Starts reading the link. Call once before the first request.
    public func start() throws {
        guard session.canOffload else { throw OffloadClientError.mtuTooSmall(session.attMTU) }
        let events = link.events
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.handle(.disconnected)
        }
    }

    public func stop() {
        eventTask?.cancel()
        finish(with: OffloadClientError.disconnected)
    }

    // MARK: - Requests

    /// Every sealed bundle the dongle holds, across pages.
    public func list() async throws -> [OffloadListEntry] {
        var entries: [OffloadListEntry] = []
        var first: UInt16 = 0
        while true {
            let id = session.makeRequestID()
            try await write(session.send(.list(requestID: id, firstIndex: first)), opcode: .list)
            let page: OffloadListPage
            switch try await next(id, .list) {
            case .listPage(_, let p): page = p
            case .refused(_, let op, let status): throw OffloadClientError.refused(op, status)
            case let other: throw OffloadClientError.protocolViolation("LIST answered with \(other)")
            }
            entries += page.entries
            first = page.firstIndex + UInt16(page.entries.count)
            if page.entries.isEmpty || Int(first) >= Int(page.total) { return entries }
        }
    }

    /// `manifest.cbor` followed by the 64-byte `manifest.sig`.
    public func manifest(_ bundleID: OffloadBundleID) async throws -> Data {
        try await transfer(.getManifest) { id in .getManifest(requestID: id, bundleID: bundleID) }
    }

    /// A range of the bundle byte stream, at most 64 KiB.
    public func read(_ bundleID: OffloadBundleID, offset: UInt64, length: UInt32) async throws -> Data {
        try await transfer(.read) { id in .read(requestID: id, bundleID: bundleID, offset: offset, length: length) }
    }

    /// Hands the server's receipt back. The dongle verifies it against its pinned key before it
    /// stores anything or deletes anything.
    public func putReceipt(_ bundleID: OffloadBundleID, receipt: Data) async throws -> PutReceiptOutcome {
        guard receipt.count <= Int(OffloadRequest.maximumReceiptLength) else {
            throw OffloadClientError.protocolViolation("receipt of \(receipt.count) bytes exceeds \(OffloadRequest.maximumReceiptLength)")
        }
        let id = session.makeRequestID()
        try await write(
            session.send(.putReceipt(requestID: id, bundleID: bundleID, receiptLength: UInt16(receipt.count))),
            opcode: .putReceipt)
        switch try await next(id, .putReceipt) {
        case .receiptReady: break
        case .refused(_, let op, let status): throw OffloadClientError.refused(op, status)
        case let other: throw OffloadClientError.protocolViolation("PUT_RECEIPT answered with \(other)")
        }
        let frames: [Data]
        do { frames = try session.receiptFrames(requestID: id, receipt: receipt) } catch {
            throw OffloadClientError.protocolViolation("\(error)")
        }
        try await link.writeData(frames)
        switch try await next(id, .putReceipt) {
        case .receiptOutcome(_, let outcome): return outcome
        case .receiptUploadFailed(_, let status): throw OffloadClientError.receiptUploadFailed(status)
        case let other: throw OffloadClientError.protocolViolation("PUT_RECEIPT ended with \(other)")
        }
    }

    public func abort() async {
        let id = session.makeRequestID()
        guard (try? await write(session.send(.abort(requestID: id)), opcode: .abort)) != nil else { return }
        _ = try? await next(id, .abort)
    }

    // MARK: - Transfers

    private func transfer(
        _ opcode: OffloadOpcode, _ make: @Sendable (UInt8) -> OffloadRequest
    ) async throws -> Data {
        var lastFailure: OffloadTransferFailure?
        for _ in 0..<maxTransferAttempts {
            let id = session.makeRequestID()
            try await write(session.send(make(id)), opcode: opcode)
            do {
                while true {
                    switch try await next(id, opcode) {
                    case .transferStarted: continue
                    case .transferComplete(_, _, let data): return data
                    case .refused(_, let op, let status): throw OffloadClientError.refused(op, status)
                    case .transferFailed(_, _, let failure):
                        // A lost or reordered notification, a bad length or CRC: ask again. A
                        // dongle that ended the transfer for its own reasons is not asked again
                        // here (a trip started; the caller waits for the drive to end).
                        if case .device(let status) = failure, status != .ioError {
                            throw OffloadClientError.refused(opcode, status)
                        }
                        lastFailure = failure
                    case let other:
                        throw OffloadClientError.protocolViolation("\(opcode) answered with \(other)")
                    }
                    break
                }
            } catch OffloadClientError.timedOut(let op) {
                // A stalled transfer holds the dongle for 8 s; free it, then report.
                await abort()
                throw OffloadClientError.timedOut(op)
            }
        }
        throw OffloadClientError.transferFailed(lastFailure ?? .device(.ioError))
    }

    // MARK: - Plumbing

    private func write(_ bytes: Data, opcode: OffloadOpcode) async throws {
        guard !ended else { throw OffloadClientError.disconnected }
        try await link.writeControl(bytes)
    }

    private func handle(_ event: OffloadWireEvent) {
        switch event {
        case .notification(let data):
            try? session.receiveNotification(data)
        case .indication(let data):
            guard let decoded = try? session.receiveIndication(data) else { return }
            deliver(decoded)
        case .disconnected:
            finish(with: OffloadClientError.disconnected)
        }
    }

    private func deliver(_ event: OffloadEvent) {
        let id = Self.requestID(of: event)
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(returning: event)
        } else {
            inbox[id, default: []].append(event)
        }
    }

    private func next(_ id: UInt8, _ opcode: OffloadOpcode) async throws -> OffloadEvent {
        if var queued = inbox[id], !queued.isEmpty {
            let first = queued.removeFirst()
            inbox[id] = queued.isEmpty ? nil : queued
            return first
        }
        if ended { throw OffloadClientError.disconnected }
        generation += 1
        let mine = generation
        let limit = timeout
        let watchdog = Task { [weak self] in
            // A cancelled sleep returns at once; only a sleep that ran its course may time out.
            guard (try? await Task.sleep(for: limit)) != nil, !Task.isCancelled else { return }
            await self?.expire(id, generation: mine, opcode)
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { waiters[id] = (mine, $0) }
    }

    /// Times out the wait it was started for, and no later wait that reuses the request id.
    private func expire(_ id: UInt8, generation: Int, _ opcode: OffloadOpcode) {
        guard let waiter = waiters[id], waiter.generation == generation else { return }
        waiters.removeValue(forKey: id)
        waiter.continuation.resume(throwing: OffloadClientError.timedOut(opcode))
    }

    private func finish(with error: Error) {
        ended = true
        let pending = waiters
        waiters = [:]
        for (_, waiter) in pending { waiter.continuation.resume(throwing: error) }
    }

    private static func requestID(of event: OffloadEvent) -> UInt8 {
        switch event {
        case .listPage(let id, _), .transferStarted(let id, _, _), .transferComplete(let id, _, _),
             .transferFailed(let id, _, _), .receiptReady(let id), .receiptOutcome(let id, _),
             .receiptUploadFailed(let id, _), .aborted(let id), .refused(let id, _, _):
            id
        }
    }
}
