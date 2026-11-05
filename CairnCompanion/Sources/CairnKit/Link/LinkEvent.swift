import CairnProtocol
import Foundation

/// What the radio can be in.
public enum CentralState: Equatable, Sendable {
    case unknown, resetting, unsupported, unauthorised, poweredOff, poweredOn

    var offReason: LinkOffReason? {
        switch self {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorised: .unauthorised
        case .poweredOff: .poweredOff
        case .poweredOn: nil
        }
    }
}

/// Everything that can happen to the link, as one value each.
///
/// The rule the audit paid for: **one CoreBluetooth delegate call becomes one event, with its
/// error preserved**. There is no path by which a failure arrives as an absence. That includes
/// `didUpdateNotificationStateFor`, whose error the old app never looked at.
public enum LinkEvent: Equatable, Sendable {
    // From the owner
    case startRequested
    case stopRequested
    /// The Retry button. Leaves `needsForget` and `backoff` immediately.
    case retryRequested
    /// The Forget button: drop the stored identifier and start over by scanning.
    case forgetRequested

    // From the central manager
    case centralStateChanged(CentralState)
    /// `willRestoreState`: iOS relaunched the app for this dongle. A peripheral that is already
    /// connected skips straight to discovery — there is nothing to connect.
    case restored(PeripheralRef, connected: Bool)
    case discovered(PeripheralRef, rssi: Int)
    case connected(PeripheralRef)
    case failedToConnect(PeripheralRef, LinkFailure?)
    case disconnected(PeripheralRef, LinkFailure?, isReconnecting: Bool)

    // From the peripheral
    case servicesDiscovered([String], LinkFailure?)
    case characteristicsDiscovered([CairnGATT.Characteristic], LinkFailure?)
    case valueRead(CairnGATT.Characteristic, Data?, LinkFailure?)
    case notificationStateChanged(CairnGATT.Characteristic, enabled: Bool, LinkFailure?)
    case notified(CairnGATT.Characteristic, Data)
    /// `maximumWriteValueLength(for: .withoutResponse)`, measured after the link came up and
    /// again on each re-measure the machine asks for.
    case writeLengthMeasured(Int)
    case rssiRead(Int)

    /// The clock. The machine never reads `Date()` itself, so every deadline in it is testable.
    case tick

    /// What goes in the log line for this event.
    var logDetail: String {
        switch self {
        case .startRequested: "start requested"
        case .stopRequested: "stop requested"
        case .retryRequested: "retry requested"
        case .forgetRequested: "forget requested"
        case .centralStateChanged(let state): "central \(state)"
        case .restored(let p, let connected): "restored \(p.short)\(connected ? " (connected)" : "")"
        case .discovered(let p, let rssi): "discovered \(p) at \(rssi) dBm"
        case .connected(let p): "connected \(p.short)"
        case .failedToConnect(let p, let failure):
            "failed to connect \(p.short)" + (failure.map { ": \($0)" } ?? "")
        case .disconnected(let p, let failure, let isReconnecting):
            "disconnected \(p.short)\(isReconnecting ? " (reconnecting)" : "")"
                + (failure.map { ": \($0)" } ?? "")
        case .servicesDiscovered(let uuids, let failure):
            failure.map { "service discovery failed: \($0)" } ?? "services \(uuids.count)"
        case .characteristicsDiscovered(let found, let failure):
            failure.map { "characteristic discovery failed: \($0)" }
                ?? "characteristics \(found.map(\.title).sorted().joined(separator: " "))"
        case .valueRead(let characteristic, let data, let failure):
            failure.map { "read \(characteristic.title) failed: \($0)" }
                ?? "read \(characteristic.title) \(data?.count ?? 0) B"
        case .notificationStateChanged(let characteristic, let enabled, let failure):
            failure.map { "subscribe \(characteristic.title) failed: \($0)" }
                ?? "\(enabled ? "subscribed to" : "unsubscribed from") \(characteristic.title)"
        case .notified(let characteristic, let data): "\(characteristic.title) \(data.count) B"
        case .writeLengthMeasured(let length): "write length \(length) B"
        case .rssiRead(let rssi): "\(rssi) dBm"
        case .tick: "tick"
        }
    }

    /// Notifies and ticks arrive at 1 Hz or faster and would bury everything else in the log.
    var isWorthLogging: Bool {
        switch self {
        case .tick, .notified, .rssiRead: false
        default: true
        }
    }
}
