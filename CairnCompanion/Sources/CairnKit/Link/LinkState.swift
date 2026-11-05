import CairnProtocol
import Foundation

/// One peripheral, as the machine sees it: an identifier and a name, no object.
///
/// `CairnKit` never holds a `CBPeripheral`. The adapter keeps the real object and hands the
/// machine this, which means the whole link can be replayed from a log in a test.
public struct PeripheralRef: Equatable, Sendable, Hashable, CustomStringConvertible {
    public let id: String
    public let name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    public var description: String { name.map { "\($0) \(short)" } ?? short }
    /// The first 8 characters of the identifier: enough to tell two dongles apart in a log line.
    public var short: String { String(id.prefix(8)) }
}

/// Why the radio cannot be used at all.
public enum LinkOffReason: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorised
    case poweredOff
    /// The radio is fine; nobody has asked for a link.
    case notWanted

    public var title: String {
        switch self {
        case .unknown: "Waiting for Bluetooth"
        case .resetting: "Bluetooth is restarting"
        case .unsupported: "This device has no Bluetooth LE"
        case .unauthorised: "Cairn is not allowed to use Bluetooth"
        case .poweredOff: "Bluetooth is off"
        case .notWanted: "Not connecting"
        }
    }

    /// Whether anything the app does could change this. Nothing can be done about an
    /// unsupported radio; Settings can fix the other two.
    public var isUserFixable: Bool {
        self == .poweredOff || self == .unauthorised
    }
}

/// What the app knows about a dongle whose link is up.
public struct LinkReady: Equatable, Sendable {
    public let peripheral: PeripheralRef
    public let version: ProtocolVersion
    /// The characteristics this firmware actually exposes. A feature needs its bit *and* its
    /// characteristic; the old app checked only the bit, so offload was dead code for a month.
    public let present: Set<CairnGATT.Characteristic>
    /// `maximumWriteValueLength(for: .withoutResponse)`, which must be at least 28.
    public let writeLength: Int
    /// What the dongle said about itself, once `DEVICE_INFO` has been read. Nil until then,
    /// and nil forever on a firmware that does not set capability bit 3.
    public var deviceInfo: DeviceInfo?
    public let readyAt: Date

    public init(
        peripheral: PeripheralRef,
        version: ProtocolVersion,
        present: Set<CairnGATT.Characteristic>,
        writeLength: Int,
        deviceInfo: DeviceInfo? = nil,
        readyAt: Date
    ) {
        self.peripheral = peripheral
        self.version = version
        self.present = present
        self.writeLength = writeLength
        self.deviceInfo = deviceInfo
        self.readyAt = readyAt
    }

    public func has(_ characteristic: CairnGATT.Characteristic) -> Bool {
        present.contains(characteristic)
    }

    /// Bundle offload is usable: the capability bit is set **and** both characteristics are here.
    public var canOffload: Bool {
        version.hasBundleOffload && has(.offloadControl) && has(.offloadData)
    }

    /// The dongle will take a position hint and a clock.
    public var canPrime: Bool { has(.gnssFix) && has(.utcSync) }
}

/// Where the link is.
///
/// The states and the rules between them are the plan's R1. Two of them exist only because of
/// what the audit found: `securing` is named for the fact that reading `PROTOCOL_VERSION` is
/// what makes iOS pair, so a pairing failure has a state to fail *in*; and `needsForget` is a
/// state you can leave, unlike the old app's terminal "stale pairing", which cleared the
/// connection wish and left the session armed so that Start did nothing afterwards.
public enum LinkState: Equatable, Sendable {
    case off(LinkOffReason)
    case idle
    case scanning(deadline: Date)
    case connecting(PeripheralRef, deadline: Date)
    case discovering(PeripheralRef, since: Date)
    /// The `PROTOCOL_VERSION` read is in flight. This is where iOS pairs.
    case securing(PeripheralRef, since: Date)
    case ready(LinkReady)
    case backoff(attempt: Int, reason: LinkFailure, until: Date)
    case needsForget(LinkFailure)

    public var peripheral: PeripheralRef? {
        switch self {
        case .connecting(let p, _), .discovering(let p, _), .securing(let p, _): p
        case .ready(let r): r.peripheral
        case .off, .idle, .scanning, .backoff, .needsForget: nil
        }
    }

    public var isReady: Bool { if case .ready = self { true } else { false } }

    /// What the Dongle screen puts in its headline.
    public var title: String {
        switch self {
        case .off(let reason): reason.title
        case .idle: "Idle"
        case .scanning: "Looking for the dongle"
        case .connecting: "Connecting"
        case .discovering: "Reading the service"
        case .securing: "Pairing"
        case .ready: "Ready"
        case .backoff(let attempt, _, _): "Retrying, attempt \(attempt)"
        case .needsForget: "Pairing needs your help"
        }
    }

    /// A short name for a log line and for a test assertion, with no payload in it.
    public var name: String {
        switch self {
        case .off: "off"
        case .idle: "idle"
        case .scanning: "scanning"
        case .connecting: "connecting"
        case .discovering: "discovering"
        case .securing: "securing"
        case .ready: "ready"
        case .backoff: "backoff"
        case .needsForget: "needsForget"
        }
    }

    /// The failure worth showing, if any.
    public var failure: LinkFailure? {
        switch self {
        case .backoff(_, let reason, _), .needsForget(let reason): reason
        default: nil
        }
    }

    /// When this state expires on its own. The adapter schedules a tick for exactly then rather
    /// than polling, and a test can jump straight to it.
    public var deadline: Date? {
        switch self {
        case .scanning(let deadline), .connecting(_, let deadline): deadline
        case .backoff(_, _, let until): until
        default: nil
        }
    }
}

/// The backoff schedule: 1 s, then doubling to a 15 s ceiling.
///
/// Carried over from the old app's `ReconnectPolicy`, which had the right numbers. What it did
/// not have was a counter that rose on every failing path — it rose only inside one retry
/// helper, so a connect that failed outright left it at zero and the app retried forever at one
/// second with nothing on screen. Here the attempt count is part of the state.
public enum LinkBackoff {
    public static let base: TimeInterval = 1
    public static let ceiling: TimeInterval = 15

    public static func delay(attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return base }
        let exponent = min(attempt - 1, 10) // the ceiling applies long before this matters
        return min(base * Double(1 << exponent), ceiling)
    }
}
