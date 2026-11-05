import CairnProtocol
import Foundation

/// What the adapter should do next.
///
/// The machine issues these and performs none of them, which is what makes the bench matrix
/// testable: `FakeCentral` obeys the same list that `CoreBluetoothCentral` does, so every row of
/// the matrix runs in CI before the dongle sees it.
public enum LinkEffect: Equatable, Sendable {
    case scan(service: String)
    case stopScan
    /// `CBConnectPeripheralOptionEnableAutoReconnect` is always on: the system brings a dropped
    /// link back faster and more reliably than a timer can, and the old app never set it.
    case connect(PeripheralRef)
    case cancelConnection(PeripheralRef)
    case discoverServices(service: String)
    /// With a `nil` filter, always. A filter is what hid `0030` and `0031` from the old app and
    /// made bundle offload dead code; the machine decides what to use from what came back.
    case discoverCharacteristics(service: String)
    case read(CairnGATT.Characteristic)
    case setNotify(CairnGATT.Characteristic, Bool)
    case measureWriteLength
    case readRSSI
    /// Remember this dongle, so the next launch connects instead of scanning. Written only on
    /// the first `ready` — the old app wrote it in `didConnect`, before bonding had succeeded,
    /// and from then on only ever connected to it, with no timeout and no fallback to a scan.
    case persistIdentifier(String)
    case forgetIdentifier
    /// Ask the owner to forget the dongle in iOS Settings. The app cannot delete an iOS bond,
    /// which is the whole reason `needsForget` exists as a state.
    case askToForgetInSettings(LinkFailure)

    var logDetail: String? {
        switch self {
        case .scan: "scanning"
        case .stopScan: nil
        case .connect(let p): "connecting to \(p)"
        case .cancelConnection: "cancelling the connection"
        case .discoverServices: nil
        case .discoverCharacteristics: "discovering characteristics (no filter)"
        case .read(let c): "reading \(c.title)"
        case .setNotify(let c, let on): "\(on ? "subscribing to" : "unsubscribing from") \(c.title)"
        case .measureWriteLength, .readRSSI: nil
        case .persistIdentifier(let id): "remembered \(String(id.prefix(8)))"
        case .forgetIdentifier: "forgot the stored dongle"
        case .askToForgetInSettings: "asking the owner to forget Cairn in Settings"
        }
    }
}
