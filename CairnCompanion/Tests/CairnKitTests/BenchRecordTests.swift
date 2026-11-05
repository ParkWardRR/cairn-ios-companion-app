import CairnKit
import CairnProtocol
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Builds a log the way the machine would, so the reader is tested against the writer's own
/// shape rather than against a convenient fiction.
@MainActor
private func log(_ build: (inout LinkMachine, inout Date) -> Void) -> LinkLog {
    var machine = LinkMachine()
    var now = t0
    build(&machine, &now)
    return machine.log
}

private let dongle = PeripheralRef(id: "D0000001-0000-0000-0000-000000000001", name: "Cairn")

@MainActor
private func reachReady(_ machine: inout LinkMachine, _ now: inout Date, after delay: TimeInterval = 2) {
    machine.handle(.centralStateChanged(.poweredOn), now: now)
    machine.handle(.startRequested, now: now)
    machine.handle(.discovered(dongle, rssi: -55), now: now)
    now = now.addingTimeInterval(delay)
    machine.handle(.connected(dongle), now: now)
    machine.handle(.servicesDiscovered([CairnGATT.serviceUUID], nil), now: now)
    machine.handle(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil), now: now)
    machine.handle(.valueRead(.protocolVersion, ProtocolVersion(version: 1, capabilities: []).data, nil), now: now)
    machine.handle(.writeLengthMeasured(244), now: now)
}

@MainActor
@Suite("BenchObservations: reading the log back")
struct BenchObservationsTests {
    @Test("time to ready is measured from the attempt, not from launch")
    func timeToReady() {
        // The matrix says "ready in under 10 s". That is the attempt, not the time since the
        // app started and not the time since the last packet.
        let recorded = log { machine, now in
            now = now.addingTimeInterval(600) // the app has been up a while
            reachReady(&machine, &now, after: 3)
        }
        let seen = BenchObservations(from: recorded)
        #expect(seen.arrivals.count == 1)
        #expect(abs((seen.fastest ?? 0) - 3) < 0.01, "got \(String(describing: seen.fastest))")
    }

    @Test("a marker attributes the attempts that follow it to a row")
    func markers() {
        let recorded = log { machine, now in
            machine.note(BenchMatrix.marker(BenchMatrix.r1[0]), at: now)
            reachReady(&machine, &now, after: 4)

            now = now.addingTimeInterval(10)
            machine.handle(.stopRequested, now: now)
            machine.note(BenchMatrix.marker(BenchMatrix.r1[1]), at: now)
            reachReady(&machine, &now, after: 2)
        }
        let seen = BenchObservations(from: recorded)
        #expect(seen.arrivals.count == 2)
        #expect(seen.arrivals[0].row == "Fresh pair")
        #expect(seen.arrivals[1].row == "Dongle reboot")
        #expect(abs(seen.arrivals[1].seconds - 2) < 0.01)
    }

    @Test("an attempt before any marker belongs to no row")
    func noMarker() {
        let recorded = log { machine, now in reachReady(&machine, &now) }
        #expect(BenchObservations(from: recorded).arrivals.first?.row == nil)
    }

    @Test("pairing failures, backoffs and needsForget are counted from the transitions")
    func counts() {
        let failure = LinkFailure(domain: LinkFailure.attDomain, code: 5,
                                  message: "Authentication is insufficient.")
        let recorded = log { machine, now in
            machine.handle(.centralStateChanged(.poweredOn), now: now)
            machine.handle(.startRequested, now: now)
            machine.handle(.discovered(dongle, rssi: -55), now: now)
            machine.handle(.connected(dongle), now: now)
            machine.handle(.servicesDiscovered([CairnGATT.serviceUUID], nil), now: now)
            machine.handle(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil), now: now)
            // Two refused reads: retried once, then it asks for help.
            machine.handle(.valueRead(.protocolVersion, nil, failure), now: now)
            machine.handle(.valueRead(.protocolVersion, nil, failure), now: now)
        }
        let seen = BenchObservations(from: recorded)
        #expect(seen.needsForget == 1)
        #expect(seen.failures.contains { $0.contains("CBATTErrorDomain#5") })
        #expect(seen.arrivals.isEmpty)
    }

    @Test("a disconnect while securing is counted as a pairing failure")
    func pairingFailures() {
        let recorded = log { machine, now in
            machine.handle(.centralStateChanged(.poweredOn), now: now)
            machine.handle(.startRequested, now: now)
            machine.handle(.discovered(dongle, rssi: -55), now: now)
            machine.handle(.connected(dongle), now: now)
            machine.handle(.servicesDiscovered([CairnGATT.serviceUUID], nil), now: now)
            machine.handle(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil), now: now)
            now = now.addingTimeInterval(0.4)
            machine.handle(.disconnected(dongle, nil, isReconnecting: false), now: now)
        }
        let seen = BenchObservations(from: recorded)
        #expect(seen.pairingFailures == 1)
        #expect(seen.backoffs == 1)
    }

    @Test("a connect that times out is counted as one")
    func timeouts() {
        let recorded = log { machine, now in
            var m = LinkMachine(storedIdentifier: dongle.id)
            m.handle(.centralStateChanged(.poweredOn), now: now)
            m.handle(.startRequested, now: now)
            now = now.addingTimeInterval(LinkMachine.connectDeadline + 1)
            m.handle(.tick, now: now)
            machine = m
        }
        #expect(BenchObservations(from: recorded).connectTimeouts == 1)
    }

    @Test("an empty log reads as nothing happening, not as a crash")
    func empty() {
        let seen = BenchObservations(from: LinkLog())
        #expect(seen.arrivals.isEmpty)
        #expect(seen.fastest == nil)
        #expect(seen.failures.isEmpty)
    }
}

@MainActor
@Suite("BenchRecord: the file that closes a phase")
struct BenchRecordTests {
    private var build: BuildIdentity {
        BuildIdentity(version: "0.2.0", build: "86", channel: .beta, commit: "9548f79")
    }

    private func markdown(_ recorded: LinkLog, ready: LinkReady? = nil,
                          timeline: ReceiverTimeline = ReceiverTimeline()) -> String {
        BenchRecord.markdown(
            at: Date(timeIntervalSince1970: 1_793_000_000),
            build: build, state: .idle, ready: ready, lastRSSI: -58,
            timeline: timeline, offload: nil, log: recorded
        )
    }

    @Test("it carries everything the plan requires a bench record to carry")
    func required() {
        // date, firmware commit, app build number, and the numbers.
        let text = markdown(log { machine, now in reachReady(&machine, &now, after: 4) })
        #expect(text.contains("2026-10-26"), "the date goes in, and it is the local one")
        #expect(text.contains("0.2.0 (86) · beta · 9548f79"))
        #expect(text.contains("Firmware commit"), "the one thing only a person knows")
        #expect(text.contains("**[ fill in"), "and it is marked as a blank, not left looking filled")
        #expect(text.contains("## The link log"))
    }

    @Test("all eight rows are in it, with the plan's own wording")
    func eightRows() {
        let text = markdown(LinkLog())
        #expect(BenchMatrix.r1.count == 8)
        for row in BenchMatrix.r1 {
            #expect(text.contains(row.name), "missing row \(row.name)")
            #expect(text.contains(row.expectation), "missing expectation for \(row.name)")
        }
        // Each runs twice, and an unrun row is visibly unrun.
        #expect(text.contains("| Run 1 | Run 2 |"))
        #expect(text.contains("[ ]"))
    }

    @Test("a row run under its marker has its measured seconds in the table")
    func measuredRows() {
        let recorded = log { machine, now in
            machine.note(BenchMatrix.marker(BenchMatrix.r1[0]), at: now)
            reachReady(&machine, &now, after: 4.2)
            now = now.addingTimeInterval(5)
            machine.handle(.stopRequested, now: now)
            machine.note(BenchMatrix.marker(BenchMatrix.r1[0]), at: now)
            reachReady(&machine, &now, after: 3.1)
        }
        let text = markdown(recorded)
        #expect(text.contains("4.2 s"))
        #expect(text.contains("3.1 s"))
    }

    @Test("the receiver timeline is only there when there was one")
    func receiverSection() {
        #expect(!markdown(LinkLog()).contains("## Receiver"))

        var timeline = ReceiverTimeline(linkReadyAt: t0)
        timeline.positionHintAt = t0.addingTimeInterval(0.3)
        timeline.observe(fixType: 2, at: t0.addingTimeInterval(22))
        let text = markdown(LinkLog(), timeline: timeline)
        #expect(text.contains("## Receiver"))
        #expect(text.contains("Position hint sent | yes"))
        #expect(text.contains("22.0 s"))
        #expect(text.contains("paste from the serial log"), "the dongle's own line is the comparison")
    }

    @Test("the file is named the way the plan names it")
    func filename() {
        #expect(BenchRecord.filename(subject: "ble-pairing", at: Date(timeIntervalSince1970: 1_793_000_000))
                == "ble-pairing-2026-10-26.md")
    }

    @Test("a marker round-trips through the log")
    func markerRoundTrip() {
        let row = BenchMatrix.r1[4]
        let marker = BenchMatrix.marker(row)
        #expect(BenchMatrix.isMarker(marker))
        #expect(BenchMatrix.rowName(fromMarker: marker) == "Dongle stale")
        #expect(!BenchMatrix.isMarker("→ ready"))
        #expect(BenchMatrix.rowName(fromMarker: "→ ready") == nil)
    }
}
