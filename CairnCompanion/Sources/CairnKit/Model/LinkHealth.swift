import CairnProtocol
import Foundation

/// How recently a notify channel was heard from. The dongle sends `GNSS_QUALITY` and
/// `COMPANION_STATUS` at 1 Hz, so a healthy link is never more than a second or two behind.
public enum Freshness: Sendable, Equatable {
    case never
    case live
    case stale
    case silent
}

public enum LinkHealth {
    /// Matches the firmware's phone-GNSS staleness window; "Streaming" means a status inside this window.
    public static let liveWindow: TimeInterval = 3
    /// Beyond this the channel is treated as gone even though the link may still be up.
    public static let silentAfter: TimeInterval = 10

    public static func freshness(lastHeard: Date?, now: Date) -> Freshness {
        guard let lastHeard else { return .never }
        let age = now.timeIntervalSince(lastHeard)
        if age < liveWindow { return .live }
        if age < silentAfter { return .stale }
        return .silent
    }

    /// Fixes written but not yet reported by the dongle. A couple are always in flight at 1 Hz, so
    /// only a growing gap means the dongle has stopped accepting.
    public static func unacked(sent: Int, status: CompanionStatus?) -> Int {
        guard let status else { return sent }
        return max(0, sent - Int(status.acceptedCount) - Int(status.rejectedCount))
    }

    public static let unackedWarning = 5

    /// `4 s`, `1 m 05 s`, `2 h 03 m`. Negative ages clamp to zero.
    public static func ageLabel(_ age: TimeInterval) -> String {
        let seconds = Int(max(0, age).rounded(.down))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) m \(String(format: "%02d", seconds % 60)) s" }
        return "\(seconds / 3600) h \(String(format: "%02d", (seconds % 3600) / 60)) m"
    }
}

public enum LinkEventKind: String, Codable, Sendable, Equatable {
    case armed, disarmed
    case bluetoothUnavailable
    case ready
    /// The link went away (disconnect, failed connect, radio off, or a post-link retry).
    case dropped
    case failed
    case streamingLost, streamingResumed
}

public struct LinkEvent: Codable, Sendable, Equatable {
    public let at: Date
    public let kind: LinkEventKind
    public let detail: String?

    public init(at: Date, kind: LinkEventKind, detail: String? = nil) {
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

/// A capped record of link transitions, newest last. Feeds the status timeline in the UI and, later, drive history.
public struct LinkEventLog: Sendable, Equatable {
    public static let capacity = 200

    public private(set) var events: [LinkEvent] = []

    public init() {}

    public mutating func append(_ event: LinkEvent) {
        events.append(event)
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }

    public mutating func removeAll() { events.removeAll() }

    /// Drops since the app was last armed. `removeAll` on disarm resets it.
    public var dropCount: Int { events.lazy.filter { $0.kind == .dropped }.count }

    public var lastDrop: Date? { events.last { $0.kind == .dropped }?.at }
}
