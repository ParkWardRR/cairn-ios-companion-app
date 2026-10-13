import Foundation

public struct TransmitThrottle: Sendable {
    public enum PowerMode: Sendable {
        case charger
        case battery
        case batterySaver
    }

    public var powerMode: PowerMode {
        didSet { minInterval = Self.interval(for: powerMode) }
    }
    public private(set) var minInterval: TimeInterval
    private var lastSent: Date?

    public init(powerMode: PowerMode = .battery) {
        self.powerMode = powerMode
        self.minInterval = Self.interval(for: powerMode)
    }

    public mutating func shouldSend(_ fix: PhoneGNSSFix) -> Bool {
        if let lastSent, fix.timestamp.timeIntervalSince(lastSent) < minInterval { return false }
        lastSent = fix.timestamp
        return true
    }

    public mutating func reset() { lastSent = nil }

    private static func interval(for mode: PowerMode) -> TimeInterval {
        switch mode {
        case .charger:      0.0
        case .battery:      0.9
        case .batterySaver: 4.5
        }
    }
}
