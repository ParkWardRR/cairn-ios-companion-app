import CairnKit
import CairnProtocol
import Foundation

/// A phone, a dongle and a clock, wired the way the app wires them.
///
/// Every row of the plan's bench matrix runs through this before any of it runs on hardware, and
/// the hardware run is then a comparison rather than a discovery. Time is a `TestLinkClock`, so a
/// 15-second deadline is tested exactly and a 20-second scan window costs no wall clock.
@MainActor
final class Bench {
    let clock = TestLinkClock()
    let central: FakeCentral
    let supervisor: LinkSupervisor
    private let startedAt: Date

    init(dongle: FakeCentral.Dongle = FakeCentral.Dongle(), stored: String? = nil) {
        central = FakeCentral(dongle: dongle)
        supervisor = LinkSupervisor(
            machine: LinkMachine(storedIdentifier: stored),
            central: central,
            clock: clock
        )
        startedAt = clock.now
    }

    /// The radio comes up and the owner wants a link. Both, because the machine refuses to do
    /// anything without a radio and refuses to do anything nobody asked for.
    func powerOnAndStart() {
        deliver(.centralStateChanged(.poweredOn))
        supervisor.start()
        settle()
    }

    func deliver(_ event: LinkEvent) {
        supervisor.deliver(event)
        settle()
    }

    func settle() { central.settle() }

    /// Move time forward in slices, settling between them, so a wake-up that provokes radio
    /// traffic is answered before the next wake-up is due.
    func advance(_ seconds: TimeInterval, step: TimeInterval = 0.25) {
        var left = seconds
        while left > 0 {
            let slice = min(step, left)
            clock.advance(by: slice)
            settle()
            left -= slice
        }
    }

    /// Let time run until the link is ready, or until `budget` is spent.
    @discardableResult
    func runUntilReady(within budget: TimeInterval) -> TimeInterval? {
        let from = clock.now
        var left = budget
        while left > 0 {
            if supervisor.state.isReady { return clock.now.timeIntervalSince(from) }
            let slice = min(0.25, left)
            clock.advance(by: slice)
            settle()
            left -= slice
        }
        return supervisor.state.isReady ? clock.now.timeIntervalSince(from) : nil
    }

    var state: LinkState { supervisor.state }
    var elapsed: TimeInterval { clock.now.timeIntervalSince(startedAt) }

    /// Nothing in the app ever puts a pairing dialog on screen: iOS does, and only when the
    /// dongle's IO capability demands it (decision D2). So "no dialog" means the app asked the
    /// owner for nothing — no `askToForgetInSettings`, and no `needsForget`.
    var askedTheOwnerForSomething: Bool {
        central.didAskToForget || supervisor.state.name == "needsForget"
    }

    /// The log, for a failure message that is evidence rather than a guess.
    var transcript: String { supervisor.exportLog() }
}

extension LinkFailure {
    /// The reason the firmware disconnects with when the peer no longer holds the keys. On this
    /// reason — and only on this one — it drops its own half of the bond, so the next attempt is
    /// a clean pairing (`src/ble_companion.cpp`, `onDisconnect`).
    static let peerLostKeys = LinkFailure(
        domain: LinkFailure.cbDomain,
        code: LinkFailure.CB.peerRemovedPairingInformation.rawValue,
        message: "The specified device has no pairing information."
    )

    static let insufficientAuthentication = LinkFailure(
        domain: LinkFailure.attDomain,
        code: LinkFailure.ATT.insufficientAuthentication.rawValue,
        message: "Authentication is insufficient."
    )
}
