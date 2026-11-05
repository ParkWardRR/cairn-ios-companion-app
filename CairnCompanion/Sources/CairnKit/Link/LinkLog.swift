import Foundation

/// One line of the link log.
public struct LinkLogEntry: Equatable, Sendable, Identifiable {
    public let id: Int
    public let at: Date
    /// The state the machine was in when this happened.
    public let state: String
    public let detail: String
    public let kind: Kind

    public enum Kind: String, Sendable {
        /// A state change. These are what a bench run is read from.
        case transition
        /// Something the radio reported.
        case event
        /// Something the machine asked the radio to do.
        case effect
        /// A failure, with its own numeric code in `detail`.
        case failure
    }

    public init(id: Int, at: Date, state: String, detail: String, kind: Kind) {
        self.id = id
        self.at = at
        self.state = state
        self.detail = detail
        self.kind = kind
    }

    /// `19:04:36.128  securing   ATT 5 · the read was refused` — one line, fixed columns, so a
/// phone log and the dongle's serial output can be read side by side.
    public func line(relativeTo origin: Date? = nil) -> String {
        let stamp: String
        if let origin {
            stamp = String(format: "%+9.3f", at.timeIntervalSince(origin))
        } else {
            stamp = LinkLog.wallClock(at)
        }
        return "\(stamp)  \(state.padding(toLength: 12, withPad: " ", startingAt: 0))\(detail)"
    }
}

/// A fixed-size ring of log lines.
///
/// On disk and exportable, because firmware
/// [#44](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/44) has been open
/// since 2026-10-10 waiting for a second central to say what it saw, and "it did not pair" is
/// not an answer. A ring rather than a growing file: a drive is hours long at 1 Hz, and the
/// interesting part is always the last few minutes.
public struct LinkLog: Equatable, Sendable {
    public static let defaultCapacity = 500

    public let capacity: Int
    private var ring: [LinkLogEntry] = []
    private var nextID = 0
    /// How many lines have been dropped off the back, so an export cannot pretend to be whole.
    public private(set) var dropped = 0

    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
        ring.reserveCapacity(self.capacity)
    }

    /// Oldest first.
    public var entries: [LinkLogEntry] { ring }

    public var isEmpty: Bool { ring.isEmpty }

    @discardableResult
    public mutating func append(at: Date, state: String, detail: String, kind: LinkLogEntry.Kind) -> LinkLogEntry {
        let entry = LinkLogEntry(id: nextID, at: at, state: state, detail: detail, kind: kind)
        nextID += 1
        ring.append(entry)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
            dropped += 1
        }
        return entry
    }

    /// The last `count` lines, newest first — what the Dongle screen shows.
    public func recent(_ count: Int) -> [LinkLogEntry] {
        ring.suffix(count).reversed()
    }

    /// Only the state changes and failures: the shape of a bench row, without the chatter.
    public var transitions: [LinkLogEntry] {
        ring.filter { $0.kind == .transition || $0.kind == .failure }
    }

    /// The whole log as text, with a header naming what it is. Seconds are relative to the first
    /// line so the column can be compared with the firmware's own uptime log.
    public func export(header: [String] = []) -> String {
        var out = header.map { "# \($0)\n" }.joined()
        if dropped > 0 { out += "# \(dropped) earlier line(s) rolled off the ring\n" }
        guard let origin = ring.first?.at else { return out + "# the log is empty\n" }
        out += "# t=0 is \(Self.absolute(origin))\n"
        for entry in ring { out += entry.line(relativeTo: origin) + "\n" }
        return out
    }

    /// Built per call rather than held: a date formatter is not `Sendable`, and a log line is
    /// not on a path where one allocation matters.
    static func wallClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    static func absolute(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
