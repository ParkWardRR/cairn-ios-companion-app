import CairnProtocol
import Foundation

/// What arrives from the dongle on the two offload characteristics, in order.
public enum OffloadWireEvent: Sendable, Equatable {
    /// An indication on OFFLOAD_CONTROL (a response or a transfer-done).
    case indication(Data)
    /// A notification on OFFLOAD_DATA (bundle bytes).
    case notification(Data)
    /// The link went away. Nothing more will arrive.
    case disconnected
}

/// The BLE link as the offload client sees it: two characteristics and an MTU. CoreBluetooth
/// implements it in the app; tests implement it with a model of the dongle, so the whole loop is
/// exercised without a radio.
public protocol OffloadLink: Sendable {
    /// The negotiated ATT MTU. The dongle answers every request `IO_ERROR` below 43.
    var attMTU: Int { get }
    /// Everything the dongle sends, in order. Read by exactly one consumer.
    var events: AsyncStream<OffloadWireEvent> { get }
    /// Writes a request to OFFLOAD_CONTROL (with response).
    func writeControl(_ data: Data) async throws
    /// Writes receipt frames to OFFLOAD_DATA (without response), pacing itself to the radio.
    func writeData(_ frames: [Data]) async throws
}
