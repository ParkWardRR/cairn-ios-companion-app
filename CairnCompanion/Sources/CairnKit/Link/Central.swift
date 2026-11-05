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
/// Every deadline in `LinkMachine` is a `Date` comparison against a value handed in, and the one
/// object that knows what time it is lives behind this. `TestLinkClock` is what lets the bench
/// matrix run in milliseconds and lets a 15-second deadline be tested exactly.
@MainActor
public protocol LinkClock: AnyObject {
    var now: Date { get }
    /// Wake `action` at `date`, replacing any pending wake-up. `nil` cancels.
    func wake(at date: Date?, _ action: @escaping @MainActor () -> Void)
}

/// The real clock: `Date()` and a cancellable sleeping task.
@MainActor
public final class SystemLinkClock: LinkClock {
    private var task: Task<Void, Never>?

    public init() {}

    public var now: Date { Date() }

    public func wake(at date: Date?, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        guard let date else { task = nil; return }
        let delay = max(0, date.timeIntervalSinceNow)
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

/// A clock a test moves by hand.
///
/// `advance(by:)` fires every wake-up it passes, in order, so a test can say "fifteen seconds go
/// by" and get exactly the deadline behaviour the phone would get — without waiting fifteen
/// seconds, and without a flaky margin.
@MainActor
public final class TestLinkClock: LinkClock {
    public private(set) var now: Date
    private var pending: (date: Date, action: @MainActor () -> Void)?

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = start
    }

    public func wake(at date: Date?, _ action: @escaping @MainActor () -> Void) {
        pending = date.map { ($0, action) }
    }

    /// Move time forward, firing each wake-up at the moment it is due.
    public func advance(by interval: TimeInterval) {
        let target = now.addingTimeInterval(interval)
        // A wake-up may schedule the next one, so loop rather than fire once.
        var guardRail = 0
        while let next = pending, next.date <= target {
            guardRail += 1
            precondition(guardRail < 1000, "a wake-up kept rescheduling itself inside one advance")
            pending = nil
            now = next.date
            next.action()
        }
        now = target
    }

    public var hasPendingWake: Bool { pending != nil }
    public var pendingWakeAt: Date? { pending?.date }
}
