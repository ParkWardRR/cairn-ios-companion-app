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

// LinkEventKind, LinkEvent and LinkEventLog lived here. LinkLog replaced them: the same ring,
// but every entry carries the state it happened in and a failure carries its own numeric code,
// which is what firmware #44 has been waiting for. See CairnKit/Link/LinkLog.swift.
