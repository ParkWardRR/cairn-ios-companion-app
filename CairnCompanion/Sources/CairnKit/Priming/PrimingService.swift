import CairnProtocol
import Foundation

/// Joins `PrimingPolicy` to the link and the receiver, and does nothing else.
///
/// The one rule worth stating out loud, because the old app got it wrong and that is why the
/// live store holds zero phone positions: **the location session is tied to the link being
/// ready, and to nothing else.** Not to an `OBD_LIVE` notification, not to a `DEVICE_STATUS`
/// one — the shipping firmware exposes neither, so the session was never created and streaming
/// almost certainly stopped the moment the phone locked.
@MainActor
@Observable
public final class PrimingService {
    public private(set) var policy = PrimingPolicy()
    /// What was written, and what the radio did with it. The Dongle screen shows the counts and
    /// a bench record quotes them.
    public private(set) var sent = Counters()

    private let link: LinkSupervisor
    private let location: any LocationSource
    private let clock: any LinkClock

    public struct Counters: Equatable, Sendable {
        public var clocks = 0
        public var hints = 0
        public var fixes = 0
        /// Writes the radio would not take. A few are normal; a growing number is a link that
        /// cannot keep up with 1 Hz.
        public var droppedToBackpressure = 0
        public var refusedByLink = 0
    }

    public init(link: LinkSupervisor, location: any LocationSource, clock: any LinkClock) {
        self.link = link
        self.location = location
        self.clock = clock

        // The app may route these itself when more than one thing follows the link (offload
        // does too), so they are only claimed when nobody else has.
        if link.onTransition == nil {
            link.onTransition = { [weak self] from, to in self?.linkChanged(from: from, to: to) }
        }
        if link.onNotify == nil {
            link.onNotify = { [weak self] characteristic, data in self?.received(characteristic, data) }
        }
        location.onFix = { [weak self] _ in self?.pump() }

        // A link that is already ready when this is built — a relaunch by iOS for the dongle,
        // say — gets the same treatment as one that has just come up.
        if case .ready(let ready) = link.state { becameReady(ready) }
    }

    // MARK: - What the screen reads

    public var timeline: ReceiverTimeline { policy.timeline }
    public var authorisation: LocationAuthorisation { location.authorisation }
    public var lastFix: PhoneGNSSFix? { location.lastFix }
    public var hintSkipped: PrimingPolicy.HintSkip? { policy.hintSkipped }
    /// The last thing the receiver said about itself.
    public private(set) var quality: GNSSQuality?
    /// The dongle's own count of what it accepted and rejected. "Streaming" means this moved,
    /// not that a write succeeded.
    public private(set) var status: CompanionStatus?
    public private(set) var statusAt: Date?

    public func requestAuthorisation() { location.requestAuthorisation() }

    /// Whether the link is ready *and* its write length has settled above the 28 B a
    /// `GNSS_FIX` needs.
    public var canWrite: Bool {
        guard case .ready(let ready) = link.state else { return false }
        return ready.writeLength >= CairnGATT.requiredWriteLength
    }

    public func freshness(now: Date) -> Freshness {
        LinkHealth.freshness(lastHeard: statusAt, now: now)
    }

    // MARK: - Events

    /// The link moved. Public because more than one thing follows it and the app wires
    /// them in one place; `PrimingService` claims the hook only when nothing else has.
    public func linkChanged(from: LinkState, to: LinkState) {
        switch to {
        case .ready(let ready):
            // A link reports `ready` before `maximumWriteValueLength` has settled, so the
            // transition into it and the transition that brings a usable write length are two
            // different moments. The first sets the policy up; the second is the one that can
            // actually send anything.
            if case .ready = from {} else { becameReady(ready) }
            pump()
        default:
            guard case .ready = from else { return }
            ended()
        }
    }

    private func becameReady(_ ready: LinkReady) {
        policy.linkBecameReady(at: clock.now, capabilities: PrimingPolicy.Capabilities(ready))
        quality = nil
        status = nil
        statusAt = nil
        // Here, and only here.
        location.start()
    }

    private func ended() {
        policy.linkEnded()
        location.stop()
        clock.wake("priming", at: nil) {}
    }

    /// A notification arrived. Public for the same reason as `linkChanged`.
    public func received(_ characteristic: CairnGATT.Characteristic, _ data: Data) {
        switch characteristic {
        case .gnssQuality:
            guard let decoded = PayloadDecoder.gnssQuality(data) else { return }
            quality = decoded
            let before = policy.timeline
            policy.receiverReported(decoded, at: clock.now)
            if policy.timeline != before { noteTimeline() }
            pump()
        case .companionStatus:
            guard let decoded = PayloadDecoder.companionStatus(data) else { return }
            status = decoded
            statusAt = clock.now
        default:
            break
        }
    }

    /// Send whatever is due, then arrange to be woken when the next thing is.
    public func pump() {
        let now = clock.now
        // `policy.next` marks what it returns as sent, so it must not be called while the link
        // cannot carry it: a hint consumed into a refused write is a hint that never goes.
        guard canWrite else {
            clock.wake("priming", at: nil) {}
            return
        }
        for action in policy.next(now: now, location: location.lastFix, isCharging: location.isCharging) {
            switch link.write(action.data, to: action.characteristic) {
            case .sent:
                switch action {
                case .clock: sent.clocks += 1
                case .positionHint:
                    sent.hints += 1
                    noteTimeline()
                case .liveFix: sent.fixes += 1
                }
            case .backpressure:
                sent.droppedToBackpressure += 1
            case .notAvailable:
                sent.refusedByLink += 1
            }
        }
        clock.wake("priming", at: policy.nextDue(now: now)) { [weak self] in self?.pump() }
    }

    /// Put the receiver timeline in the link log, so an exported log carries the phone's own
    /// TTFF line beside everything else that happened on the link.
    private func noteTimeline() {
        link.note("receiver \(policy.timeline.line)")
    }
}
