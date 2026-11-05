import CairnProtocol
import Foundation

/// What to send the dongle's receiver, and when.
///
/// "GPS quick start" was in the old app's README and in none of its code. The phone streamed
/// fixes, the dongle stored them as a *second position source*, and nothing was ever handed to
/// the u-blox receiver as a hint — so the phone made the trip's track better and did nothing at
/// all for the time to first fix. Decision D3 defines the feature as the two hints the firmware
/// already accepts from weaker sources: the phone's clock, and the phone's last position.
///
/// Pure, and driven entirely by values handed in, because the thing being measured is a
/// sequence of timings and a timing rule you cannot test is a timing rule you do not have.
public struct PrimingPolicy: Sendable, Equatable {
    // MARK: - Rules, as numbers

    /// `UTC_SYNC` at link-ready and once a minute after, the cadence `ble/v1/spec.md` names.
    public static let clockPeriod: TimeInterval = 60
    /// While the receiver has no 3D fix, every fix the phone has is worth sending.
    public static let liveCadence: TimeInterval = 1
    /// Once it has one, the phone is a second opinion rather than a lifeline. 0.2 Hz.
    public static let settledCadence: TimeInterval = 5
    /// A cached fix older than this is not worth hinting with. A phone and its owner arrive at
    /// the car together, so the last fix is almost always beside it whatever its age — but a
    /// phone that had location switched off for days should not steer a receiver to last week.
    /// The firmware floors the hint's accuracy at 300 m regardless, which is the real guard.
    public static let maxHintAge: TimeInterval = 24 * 3600

    // MARK: - State

    /// Where the receiver got to, in seconds since the link came up. Set beside the firmware's
    /// own TTFF line, this is what says whether the hint did anything.
    public private(set) var timeline = ReceiverTimeline()
    public private(set) var seq: UInt16 = 0
    /// Why the last hint was not sent, if it was not. Shown on the Dongle screen, because
    /// "no hint" with no reason is how the old app's quick start stayed unbuilt for a month.
    public private(set) var hintSkipped: HintSkip?

    private var capabilities = Capabilities(canSyncClock: false, canSendFix: false)
    private var lastClockAt: Date?
    private var lastFixAt: Date?
    private var lastQuality: GNSSQuality?
    private var isReady = false

    public init() {}

    public struct Capabilities: Equatable, Sendable {
        public let canSyncClock: Bool
        public let canSendFix: Bool

        public init(canSyncClock: Bool, canSendFix: Bool) {
            self.canSyncClock = canSyncClock
            self.canSendFix = canSendFix
        }

        /// What this firmware exposes, from the link the machine brought up. Both halves, as
        /// always: a capability bit alone has already cost this project a month.
        public init(_ ready: LinkReady) {
            self.init(canSyncClock: ready.has(.utcSync), canSendFix: ready.has(.gnssFix))
        }
    }

    /// Why no hint went.
    public enum HintSkip: Equatable, Sendable, CustomStringConvertible {
        case noCachedFix
        case tooOld(TimeInterval)
        case noPosition
        case receiverAlreadyHasAFix
        case firmwareHasNoGNSSFix

        public var description: String {
            switch self {
            case .noCachedFix: "the phone had no position to lend"
            case .tooOld(let age): "the phone's last position is \(Int(age / 3600)) h old"
            case .noPosition: "the phone's last fix had no usable position"
            case .receiverAlreadyHasAFix: "the receiver already had a fix"
            case .firmwareHasNoGNSSFix: "this firmware has no GNSS_FIX characteristic"
            }
        }
    }

    /// One thing to write.
    public enum Action: Equatable, Sendable {
        case clock(UTCSyncPayload)
        /// The one cached fix, flagged `HINT`.
        case positionHint(GNSSFixPayload)
        case liveFix(GNSSFixPayload)

        public var characteristic: CairnGATT.Characteristic {
            switch self {
            case .clock: .utcSync
            case .positionHint, .liveFix: .gnssFix
            }
        }

        public var data: Data {
            switch self {
            case .clock(let payload): payload.data
            case .positionHint(let payload), .liveFix(let payload): payload.data
            }
        }
    }

    // MARK: - Events

    /// The link came up. Everything restarts: a new link may be a new dongle, and is certainly
    /// a new receiver start.
    public mutating func linkBecameReady(at now: Date, capabilities: Capabilities) {
        self.capabilities = capabilities
        isReady = true
        lastClockAt = nil
        lastFixAt = nil
        lastQuality = nil
        hintSkipped = capabilities.canSendFix ? nil : .firmwareHasNoGNSSFix
        timeline = ReceiverTimeline(linkReadyAt: now)
    }

    public mutating func linkEnded() {
        isReady = false
        lastClockAt = nil
        lastFixAt = nil
    }

    /// A `GNSS_QUALITY` notify. This is the only thing that says whether the receiver found the
    /// sky, because the Freematics co-processor returns no UBX replies and a hint can never be
    /// acknowledged — so the timing is the measurement.
    public mutating func receiverReported(_ quality: GNSSQuality, at now: Date) {
        lastQuality = quality
        timeline.observe(fixType: quality.fixType, at: now)
    }

    // MARK: - What to send

    /// What to write right now, marking each as sent. Call it on every location update and on
    /// the one-second heartbeat; it decides, not the caller.
    public mutating func next(now: Date, location: PhoneGNSSFix?, isCharging: Bool) -> [Action] {
        guard isReady else { return [] }
        var actions: [Action] = []

        if capabilities.canSyncClock, due(lastClockAt, every: Self.clockPeriod, now: now) {
            lastClockAt = now
            actions.append(.clock(UTCSyncPayload(date: now)))
            if timeline.clockHintAt == nil { timeline.clockHintAt = now }
        }

        guard capabilities.canSendFix else { return actions }

        // The position hint goes once per link, as early as there is anything to send it from.
        if timeline.positionHintAt == nil, hintSkipped == nil || hintSkipped == .noCachedFix {
            if let hint = planHint(now: now, location: location, isCharging: isCharging) {
                timeline.positionHintAt = now
                actions.append(.positionHint(hint))
                // A hint and a live fix in the same breath would be the same position twice,
                // with the second one claiming to be a measurement. Send the hint and stop.
                lastFixAt = now
                return actions
            }
        }

        // The cadence is a slot schedule, not a "last success" timer: the slot is spent whether
        // or not there was a fresh fix to put in it. A timer that only moves on success never
        // moves when the phone stops reporting, and whatever is waiting on it spins.
        if due(lastFixAt, every: cadence, now: now) {
            lastFixAt = now
            if let location,
               let payload = PayloadEncoder.encode(location, now: now, seq: seq, isCharging: isCharging) {
                seq &+= 1
                actions.append(.liveFix(payload))
            }
        }
        return actions
    }

    /// Un-spend an action the radio would not take.
    ///
    /// `next` marks what it returns as sent, which is right for a live fix — flow control
    /// refusing one is a fix worth dropping, and the firmware would reject it at 3 s anyway.
    /// It is wrong for the two that happen once. The clock is what stops a trip decoding to
    /// 1970 and the position hint is the whole of this phase, and both are issued at
    /// link-ready, which is precisely when the radio is busiest with discovery and
    /// subscription traffic. Losing either to a moment of backpressure and not noticing would
    /// cost a minute in one case and a whole receiver start in the other.
    public mutating func rollback(_ action: Action) {
        switch action {
        case .clock:
            lastClockAt = nil
            if timeline.clockHintAt != nil, sent == 0 { timeline.clockHintAt = nil }
        case .positionHint:
            timeline.positionHintAt = nil
        case .liveFix:
            // Deliberately nothing. A position sent late is worse than none.
            break
        }
    }

    /// How many of each have actually gone, so a rollback can tell the first attempt from a
    /// later one.
    private var sent = 0

    /// Confirm an action reached the radio.
    public mutating func confirm(_ action: Action) {
        if case .clock = action { sent += 1 }
    }

    /// When `next` would next have something to do, so the caller can sleep until then rather
    /// than spin. Nil when the link is down.
    public func nextDue(now: Date) -> Date? {
        guard isReady else { return nil }
        var candidates: [Date] = []
        if capabilities.canSyncClock {
            candidates.append(lastClockAt?.addingTimeInterval(Self.clockPeriod) ?? now)
        }
        if capabilities.canSendFix {
            candidates.append(lastFixAt?.addingTimeInterval(cadence) ?? now)
        }
        return candidates.min()
    }

    /// 1 Hz until the receiver reports a 3D fix, then 0.2 Hz.
    public var cadence: TimeInterval {
        (lastQuality?.fixType ?? 0) >= 2 ? Self.settledCadence : Self.liveCadence
    }

    public var receiverHasFix: Bool { (lastQuality?.fixType ?? 0) >= 1 }

    private mutating func planHint(
        now: Date, location: PhoneGNSSFix?, isCharging: Bool
    ) -> GNSSFixPayload? {
        guard let location else {
            hintSkipped = .noCachedFix
            return nil
        }
        // A receiver that already has a fix needs no help, and the firmware ignores a hint
        // after its first accepted fix anyway.
        guard !receiverHasFix else {
            hintSkipped = .receiverAlreadyHasAFix
            return nil
        }
        let age = now.timeIntervalSince(location.timestamp)
        guard age <= Self.maxHintAge else {
            hintSkipped = .tooOld(age)
            return nil
        }
        guard let payload = PayloadEncoder.hint(location, now: now, seq: seq, isCharging: isCharging) else {
            hintSkipped = .noPosition
            return nil
        }
        seq &+= 1
        hintSkipped = nil
        return payload
    }

    private func due(_ last: Date?, every period: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= period
    }
}

/// How long the receiver took, measured from the moment the link came up.
///
/// The Freematics co-processor returns no UBX replies, so a hint cannot be acknowledged and
/// there is nothing to assert. What there is, is a clock: the firmware logs a time-to-first-fix
/// line per receiver start, and this is the phone's own version of the same line. Set side by
/// side, with and without the phone, they are the whole of R2's evidence.
public struct ReceiverTimeline: Equatable, Sendable {
    public var linkReadyAt: Date?
    public var clockHintAt: Date?
    public var positionHintAt: Date?
    public var first2DAt: Date?
    public var first3DAt: Date?

    public init(
        linkReadyAt: Date? = nil, clockHintAt: Date? = nil, positionHintAt: Date? = nil,
        first2DAt: Date? = nil, first3DAt: Date? = nil
    ) {
        self.linkReadyAt = linkReadyAt
        self.clockHintAt = clockHintAt
        self.positionHintAt = positionHintAt
        self.first2DAt = first2DAt
        self.first3DAt = first3DAt
    }

    public mutating func observe(fixType: UInt8, at now: Date) {
        if fixType >= 1, first2DAt == nil { first2DAt = now }
        if fixType >= 2, first3DAt == nil { first3DAt = now }
    }

    /// Seconds since link-ready, or nil if it has not happened.
    public func seconds(_ moment: Date?) -> TimeInterval? {
        guard let linkReadyAt, let moment else { return nil }
        return moment.timeIntervalSince(linkReadyAt)
    }

    /// Time to first fix, from the link coming up — the number R2 is measured by.
    public var ttff2D: TimeInterval? { seconds(first2DAt) }
    public var ttff3D: TimeInterval? { seconds(first3DAt) }

    public var sentPositionHint: Bool { positionHintAt != nil }

    /// `link 0.0 · clock +0.1 · hint +0.3 · 2D +18.4 · 3D +24.9` — one line, the same shape as
    /// the firmware's, so a bench record can carry both and a reader can compare them.
    public var line: String {
        guard linkReadyAt != nil else { return "no link" }
        var parts = ["link 0.0"]
        func add(_ name: String, _ moment: Date?) {
            if let seconds = seconds(moment) {
                parts.append(String(format: "%@ %+.1f", name, seconds))
            } else {
                parts.append("\(name) —")
            }
        }
        add("clock", clockHintAt)
        add("hint", positionHintAt)
        add("2D", first2DAt)
        add("3D", first3DAt)
        return parts.joined(separator: " · ")
    }
}
