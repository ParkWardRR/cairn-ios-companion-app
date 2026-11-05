import CairnProtocol
import Foundation

/// A BLE central, reduced to what the link machine actually asks of one.
///
/// `CoreBluetoothCentral` in `CairnRuntime` is one implementation; `FakeCentral` here is the
/// other. Both obey the same `LinkEffect` list, so every row of the plan's bench matrix runs in
/// CI against the fake before a dongle sees it — and when a row then fails on hardware, the
/// difference is the radio and not the rules.
@MainActor
public protocol Central: AnyObject {
    /// Where delegate calls go. The supervisor sets this; one call in, one event out.
    var onEvent: (@MainActor (LinkEvent) -> Void)? { get set }

    func perform(_ effect: LinkEffect)

    /// Write a `GNSS_FIX`, a `UTC_SYNC` or a `BARO_ALT` to the connected dongle.
    ///
    /// Separate from `perform` because a write is not a link decision: `PrimingPolicy` decides
    /// what to send, and the link only has to be ready.
    @discardableResult
    func write(_ data: Data, to characteristic: CairnGATT.Characteristic) -> WriteOutcome
}

/// What happened to one write.
public enum WriteOutcome: Equatable, Sendable {
    case sent
    /// The link is not ready, or this firmware does not expose the characteristic.
    case notAvailable
    /// Flow control says the radio is backed up. A fix is worth dropping, not queueing: a
    /// position sent late is worse than none, and the firmware rejects it at 3 s anyway.
    case backpressure
}

/// The only clock the link is allowed to read.
///
/// Every deadline in `LinkMachine` and every cadence in `PrimingPolicy` is a `Date` comparison
/// against a value handed in, and the one object that knows what time it is lives behind this.
/// `TestLinkClock` is what lets the bench matrix run in milliseconds and lets a 15-second
/// deadline be tested exactly.
///
/// Wake-ups are named, because more than one thing waits on this clock — the link for its
/// deadlines, the priming policy for its cadence — and each replaces only its own.
@MainActor
public protocol LinkClock: AnyObject {
    var now: Date { get }
    /// Wake `action` at `date`, replacing any pending wake-up under the same name. `nil`
    /// cancels that name.
    func wake(_ name: String, at date: Date?, _ action: @escaping @MainActor () -> Void)
}

/// The real clock: `Date()` and one cancellable sleeping task per name.
@MainActor
public final class SystemLinkClock: LinkClock {
    private var tasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public var now: Date { Date() }

    public func wake(_ name: String, at date: Date?, _ action: @escaping @MainActor () -> Void) {
        tasks[name]?.cancel()
        guard let date else { tasks[name] = nil; return }
        let delay = max(0, date.timeIntervalSinceNow)
        tasks[name] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

/// A clock a test moves by hand.
///
/// `advance(by:)` fires every wake-up it passes, oldest first, so a test can say "fifteen
/// seconds go by" and get exactly the deadline behaviour the phone would get — without waiting
/// fifteen seconds, and without a flaky margin.
@MainActor
public final class TestLinkClock: LinkClock {
    public private(set) var now: Date
    private var pending: [String: (date: Date, action: @MainActor () -> Void)] = [:]

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = start
    }

    public func wake(_ name: String, at date: Date?, _ action: @escaping @MainActor () -> Void) {
        if let date {
            pending[name] = (date, action)
        } else {
            pending[name] = nil
        }
    }

    /// Move time forward, firing each wake-up at the moment it is due and in due order.
    public func advance(by interval: TimeInterval) {
        let target = now.addingTimeInterval(interval)
        var guardRail = 0
        while let next = pending.filter({ $0.value.date <= target })
            .min(by: { $0.value.date < $1.value.date }) {
            guardRail += 1
            precondition(guardRail < 10_000, "a wake-up kept rescheduling itself inside one advance")
            pending[next.key] = nil
            now = next.value.date
            next.value.action()
        }
        now = target
    }

    public var pendingNames: Set<String> { Set(pending.keys) }
    public func pendingWake(_ name: String) -> Date? { pending[name]?.date }
}
