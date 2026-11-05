import CairnKit
import CairnProtocol
import Foundation
import Testing

/// The eight rows of the plan's R1 bench matrix, run against `FakeCentral`.
///
/// These are not a substitute for the hardware run — a fake dongle cannot be weak, cannot take
/// its radio away for a real Wi-Fi slot, and has no `bluetoothd` to be at fault. What they do is
/// make the hardware run a comparison: each row below states the rule it is checking, and the
/// bench record under `docs/bench/` states the number the dongle gave for the same row. A row
/// that passes here and fails there is a radio problem, which is exactly the distinction
/// firmware #44 has been missing since 2026-10-10.
@MainActor
@Suite("Bench matrix: R1")
struct BenchMatrixTests {
    // MARK: 1 — Fresh pair

    @Test("fresh pair: no stored dongle, no bond, ready without asking the owner anything")
    func freshPair() {
        let bench = Bench()
        bench.powerOnAndStart()

        #expect(bench.state.isReady, "did not reach ready\n\(bench.transcript)")
        #expect(bench.elapsed < 10, "took \(bench.elapsed) s")
        #expect(!bench.askedTheOwnerForSomething)
        // The scan came first, then one connect. No stored identifier to shortcut with.
        #expect(bench.central.effects.contains(.scan(service: CairnGATT.serviceUUID)))
        #expect(bench.central.persistedIdentifier == bench.central.dongle.ref.id)
    }

    // MARK: 2 — Dongle reboot

    @Test("dongle reboot while ready: ready again, quickly, with no dialog")
    func dongleReboot() {
        let bench = Bench()
        bench.powerOnAndStart()
        #expect(bench.state.isReady)
        let effectsBefore = bench.central.effects.count

        bench.central.reboot()
        bench.settle()

        let took = bench.runUntilReady(within: 5)
        #expect(took != nil, "did not come back inside 5 s\n\(bench.transcript)")
        #expect(!bench.askedTheOwnerForSomething)
        // It reconnected to the dongle it knows rather than starting a scan: the identifier was
        // persisted on the first ready, which is the only time it is written.
        let after = bench.central.effects.dropFirst(effectsBefore)
        #expect(!after.contains(.scan(service: CairnGATT.serviceUUID)))
        #expect(after.contains(.connect(bench.central.dongle.ref)))
    }

    // MARK: 3 — App killed

    @Test("app killed: iOS relaunches it for the dongle and the link comes back")
    func appKilled() {
        // A fresh process with the identifier it saved last time, relaunched by the system.
        let dongle = FakeCentral.Dongle()
        let bench = Bench(dongle: dongle, stored: dongle.ref.id)
        bench.deliver(.centralStateChanged(.poweredOn))

        // `willRestoreState` with a peripheral that is still connected: there is nothing to
        // connect, so discovery starts at once.
        bench.central.perform(.connect(dongle.ref))
        bench.central.settle()
        bench.deliver(.restored(dongle.ref, connected: true))

        #expect(bench.state.isReady, "a restored, connected peripheral should go straight to discovery\n\(bench.transcript)")
        #expect(bench.elapsed < 10)
        #expect(!bench.askedTheOwnerForSomething)
        // Restoration arms the app: iOS only relaunches for a connection it was holding.
        #expect(bench.supervisor.machine.isWanted)
    }

    @Test("app killed with the dongle not connected: it connects rather than scanning")
    func appKilledNotConnected() {
        let dongle = FakeCentral.Dongle()
        let bench = Bench(dongle: dongle, stored: dongle.ref.id)
        bench.deliver(.centralStateChanged(.poweredOn))
        bench.deliver(.restored(dongle.ref, connected: false))

        #expect(bench.state.isReady, "\(bench.transcript)")
        #expect(!bench.central.effects.contains(.scan(service: CairnGATT.serviceUUID)))
    }

    // MARK: 4 — Phone stale

    @Test("phone forgot the dongle: the firmware drops its bond and the next try pairs")
    func phoneStale() {
        // The phone was told to forget the device, so it arrives wanting to pair afresh while
        // the dongle still holds an LTK for its address. The link fails before any dialog — and
        // then the firmware, seeing PINKEY_MISSING, drops its half so the retry is clean.
        let dongle = FakeCentral.Dongle(
            pairing: .dropsLinkWhilePairing(times: 1, reason: .peerLostKeys)
        )
        let bench = Bench(dongle: dongle)
        bench.powerOnAndStart()

        #expect(!bench.state.isReady, "the first attempt should fail")
        #expect(bench.state.name == "backoff", "got \(bench.state.name)\n\(bench.transcript)")
        #expect(bench.supervisor.machine.pairingFailures == 1)

        let took = bench.runUntilReady(within: 10)
        #expect(took != nil, "one retry should be enough\n\(bench.transcript)")
        #expect(!bench.askedTheOwnerForSomething, "the owner should never hear about this one")
    }

    @Test("two pairing failures in a row are still only a retry, not a question")
    func twoPairingFailures() {
        let dongle = FakeCentral.Dongle(
            pairing: .dropsLinkWhilePairing(times: 2, reason: .peerLostKeys)
        )
        let bench = Bench(dongle: dongle)
        bench.powerOnAndStart()
        let took = bench.runUntilReady(within: 15)
        #expect(took != nil, "\(bench.transcript)")
        #expect(!bench.askedTheOwnerForSomething)
    }

    // MARK: 5 — Dongle stale

    @Test("dongle cleared its bonds: needsForget inside three attempts, naming the fix")
    func dongleStale() {
        // `CLEAR bonds` on the provisioning console, or a reflash whose security fingerprint
        // changed. The dongle now refuses the key this phone offers, every time, and no amount
        // of retrying changes that: only the owner can delete an iOS pairing.
        let bench = Bench(dongle: FakeCentral.Dongle(pairing: .refusesRead(.insufficientAuthentication)))
        bench.powerOnAndStart()
        bench.advance(30)

        #expect(bench.state.name == "needsForget", "got \(bench.state.name)\n\(bench.transcript)")
        #expect(bench.central.askedToForget.count >= 1)

        // The message has to name the fix, and carry the number the radio gave.
        let advice = bench.supervisor.advice
        #expect(advice?.contains("Forget This Device") == true, "advice was \(advice ?? "nil")")
        #expect(advice?.contains("ATT 5") == true, "the advice must carry the code: \(advice ?? "nil")")

        // And it is not terminal. This is the one that mattered most: the old app's equivalent
        // cleared the connection wish and left the session armed, so Start did nothing
        // afterwards. Retry here starts a whole fresh attempt — it scans, it connects, it reads
        // the version again — and arrives back at needsForget only because this dongle really
        // does keep refusing.
        let effectsBefore = bench.central.effects.count
        bench.supervisor.retry()
        bench.settle()
        #expect(bench.supervisor.machine.isWanted, "Retry must leave the app wanting a link")
        let afterRetry = Array(bench.central.effects.dropFirst(effectsBefore))
        #expect(afterRetry.contains(.read(.protocolVersion)),
                "Retry has to get as far as the version read again: \(afterRetry)")
    }

    @Test("after the owner forgets it and the dongle pairs again, the link comes up")
    func dongleStaleThenForgotten() {
        let bench = Bench(dongle: FakeCentral.Dongle(pairing: .refusesRead(.insufficientAuthentication)))
        bench.powerOnAndStart()
        bench.advance(30)
        #expect(bench.state.name == "needsForget")

        // The owner forgets Cairn in iOS Settings; the dongle pairs Just Works from then on.
        bench.central.dongle.pairing = .justWorks
        bench.supervisor.retry()
        bench.settle()

        #expect(bench.runUntilReady(within: 10) != nil, "\(bench.transcript)")
    }

    // MARK: 6 — Wi-Fi slot

    @Test("the dongle takes its radio for a Wi-Fi slot: backoff, then ready, with no user action")
    func wifiSlot() {
        let bench = Bench()
        bench.powerOnAndStart()
        #expect(bench.state.isReady)

        bench.central.stopAdvertising()
        bench.settle()
        // The connect it tries first never answers (15 s), then a scan window goes by (20 s),
        // then it backs off and scans again. It cycles between those two for as long as the
        // dongle is away, and it never once stops or asks for help.
        bench.advance(90)
        #expect(!bench.state.isReady)
        #expect(["scanning", "backoff", "connecting"].contains(bench.state.name),
                "got \(bench.state.name)\n\(bench.transcript)")
        #expect(!bench.askedTheOwnerForSomething, "a Wi-Fi slot is not the owner's problem")
        // It has stopped trusting the stored identifier by now and is looking for the dongle
        // wherever it is: two failed direct connects and it falls back to scanning.
        #expect(bench.central.effects.contains(.scan(service: CairnGATT.serviceUUID)))

        bench.central.startAdvertising()
        #expect(bench.runUntilReady(within: 30) != nil, "\(bench.transcript)")
        #expect(!bench.askedTheOwnerForSomething)
    }

    // MARK: 7 — Locked phone

    @Test("a locked phone changes nothing: the rules do not know what a screen is")
    func lockedPhone() {
        // There is no screen state in the machine, by design. What broke streaming in the old
        // app was gating the background location session on notifications from characteristics
        // the firmware does not expose — not the lock itself. This row is the regression test
        // for the rules; the hardware row is the one that proves the background session.
        let bench = Bench()
        bench.powerOnAndStart()
        #expect(bench.state.isReady)

        bench.central.reboot()
        bench.settle()
        #expect(bench.runUntilReady(within: 5) != nil, "\(bench.transcript)")
        #expect(!bench.askedTheOwnerForSomething)
    }

    // MARK: 8 — Weak link

    @Test("weak link: the scan finds nothing, so backoff with the signal shown, never needsForget")
    func weakLink() {
        let bench = Bench(dongle: FakeCentral.Dongle(rssi: -88, isAdvertising: false))
        bench.powerOnAndStart()

        #expect(bench.state.name == "scanning")
        bench.advance(LinkMachine.scanWindow + 0.25)

        #expect(bench.state.name == "backoff", "got \(bench.state.name)\n\(bench.transcript)")
        #expect(bench.state.failure == .notFound)
        #expect(!bench.askedTheOwnerForSomething, "being out of range is not a pairing problem")

        // And it keeps trying, for as long as anyone wants a link.
        bench.advance(120)
        #expect(["scanning", "backoff"].contains(bench.state.name))
        #expect(!bench.askedTheOwnerForSomething)
        #expect(bench.supervisor.attempt > 1, "the attempt count has to rise; the old app's never did")
    }

    @Test("a dongle that is heard but far away shows its signal in the advice")
    func weakLinkShowsSignal() {
        let dongle = FakeCentral.Dongle(rssi: -84)
        let bench = Bench(dongle: dongle)
        bench.powerOnAndStart()
        #expect(bench.supervisor.lastRSSI == -84)

        // It answered once and then went quiet, the way a dongle at the edge does.
        bench.central.stopAdvertising()
        bench.settle()
        bench.advance(60)
        #expect(["scanning", "backoff"].contains(bench.state.name))
        // Whatever it is doing, it can say how loud the dongle was the last time it heard it.
        #expect(bench.supervisor.lastRSSI == -84)
        bench.advance(LinkMachine.scanWindow)
        while bench.state.name != "backoff" { bench.advance(0.25) }
        #expect(bench.supervisor.advice?.contains("-84 dBm") == true,
                "advice was \(bench.supervisor.advice ?? "nil")")
    }
}
