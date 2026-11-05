import CairnKit
import CairnProtocol
import Foundation
import Testing

/// The priming path end to end: a link comes up, a location session starts, hints go, the
/// receiver reports, the cadence drops. Everything a drive would do except the drive.
@MainActor
private final class PrimingBench {
    let bench: Bench
    let location: FakeLocationSource
    let priming: PrimingService

    init(dongle: FakeCentral.Dongle = FakeCentral.Dongle(), lastFix: PhoneGNSSFix? = nil) {
        bench = Bench(dongle: dongle)
        location = FakeLocationSource(lastFix: lastFix)
        priming = PrimingService(link: bench.supervisor, location: location, clock: bench.clock)
    }

    func powerOnAndStart() { bench.powerOnAndStart() }
    func advance(_ seconds: TimeInterval, step: TimeInterval = 0.25) { bench.advance(seconds, step: step) }
    var writes: [(CairnGATT.Characteristic, Data)] { bench.central.writes }

    var fixWrites: [GNSSFixPayload] {
        writes.filter { $0.0 == .gnssFix }.compactMap { GNSSFixPayload(data: $0.1) }
    }

    var clockWrites: [UTCSyncPayload] {
        writes.filter { $0.0 == .utcSync }.compactMap { UTCSyncPayload(data: $0.1) }
    }

    func receiverSays(fixType: UInt8) {
        bench.deliver(.notified(.gnssQuality, GNSSQuality(fixType: fixType, satsUsed: 8, hdopE2: 110, fixAgeMs: 0).data))
    }
}

private func fix(secondsAgo: TimeInterval, now: Date) -> PhoneGNSSFix {
    PhoneGNSSFix(
        latitude: 37.7749, longitude: -122.4194, ellipsoidalAltitude: 12.34,
        horizontalAccuracy: 8, verticalAccuracy: 14, speed: -1, course: -1,
        timestamp: now.addingTimeInterval(-secondsAgo)
    )
}

@MainActor
@Suite("Priming, end to end")
struct PrimingServiceTests {
    @Test("the location session starts when the link is ready, and at no other time")
    func sessionFollowsTheLink() {
        let bench = PrimingBench()
        #expect(!bench.location.isRunning, "nothing has asked for a link yet")

        bench.powerOnAndStart()
        #expect(bench.location.isRunning, "a ready link is the one thing that starts it")
        #expect(bench.location.starts == 1)

        // The old app waited for an OBD_LIVE or DEVICE_STATUS notification, and the shipping
        // firmware exposes neither — so the session was never created at all.
        #expect(!bench.bench.central.dongle.characteristics.contains(.obdLive))
        #expect(!bench.bench.central.dongle.characteristics.contains(.deviceStatus))

        bench.bench.central.stopAdvertising()
        bench.bench.settle()
        #expect(!bench.location.isRunning, "and it stops when the link goes")
        #expect(bench.location.stops == 1)
    }

    @Test("the clock goes at once, and the hint right behind it")
    func clockThenHint() {
        let bench = PrimingBench()
        bench.location.lastFix = fix(secondsAgo: 300, now: bench.bench.clock.now)
        bench.powerOnAndStart()

        #expect(bench.clockWrites.count == 1)
        let fixes = bench.fixWrites
        #expect(fixes.count == 1, "one write, and it is the hint")
        #expect(fixes.first?.isHint == true)
        #expect(fixes.first?.sampleAgeMs == 0xFFFF)
        #expect(bench.priming.timeline.sentPositionHint)
        #expect(bench.priming.sent.hints == 1)
    }

    @Test("with no cached fix it says so, and hints as soon as one arrives")
    func hintWaitsForAFix() {
        let bench = PrimingBench()
        bench.powerOnAndStart()
        #expect(bench.priming.hintSkipped == .noCachedFix)
        #expect(bench.priming.sent.hints == 0)

        bench.location.deliver(fix(secondsAgo: 0, now: bench.bench.clock.now))
        #expect(bench.priming.sent.hints == 1, "the first fix the phone gets is also the hint")
        #expect(bench.fixWrites.first?.isHint == true)
    }

    @Test("live fixes follow at 1 Hz and drop to 0.2 Hz when the receiver finds the sky")
    func cadence() {
        let bench = PrimingBench()
        bench.location.lastFix = fix(secondsAgo: 120, now: bench.bench.clock.now)
        bench.powerOnAndStart()

        // The phone keeps reporting, so the policy's heartbeat has something fresh to send.
        for _ in 0..<10 {
            bench.advance(1, step: 1)
            bench.location.deliver(fix(secondsAgo: 0, now: bench.bench.clock.now))
        }
        let liveBefore = bench.fixWrites.filter { !$0.isHint }.count
        #expect(liveBefore >= 8 && liveBefore <= 11, "about one a second, got \(liveBefore)")

        bench.receiverSays(fixType: 2)
        for _ in 0..<10 {
            bench.advance(1, step: 1)
            bench.location.deliver(fix(secondsAgo: 0, now: bench.bench.clock.now))
        }
        let liveAfter = bench.fixWrites.filter { !$0.isHint }.count - liveBefore
        #expect(liveAfter <= 3, "one in five seconds once it has a 3D fix, got \(liveAfter)")
    }

    @Test("the clock is resent about once a minute, with nothing else happening")
    func clockHeartbeat() {
        let bench = PrimingBench()
        bench.powerOnAndStart()
        #expect(bench.clockWrites.count == 1)
        bench.advance(185, step: 5)
        #expect(bench.clockWrites.count == 4, "one at ready and one a minute after, got \(bench.clockWrites.count)")
    }

    @Test("the receiver timeline is measured from link-ready and lands in the link log")
    func timelineAndLog() {
        let bench = PrimingBench()
        bench.location.lastFix = fix(secondsAgo: 200, now: bench.bench.clock.now)
        bench.powerOnAndStart()
        bench.advance(12, step: 1)
        bench.receiverSays(fixType: 1)
        bench.advance(7, step: 1)
        bench.receiverSays(fixType: 2)

        let timeline = bench.priming.timeline
        #expect(timeline.seconds(timeline.positionHintAt) == 0)
        #expect((timeline.ttff2D ?? 0) >= 12 && (timeline.ttff2D ?? 0) <= 13)
        #expect((timeline.ttff3D ?? 0) >= 19 && (timeline.ttff3D ?? 0) <= 20)

        // The exported log carries the phone's own TTFF line, so a bench record can set it
        // beside the firmware's and the two can be compared rather than argued about.
        let text = bench.bench.transcript
        #expect(text.contains("receiver link 0.0"))
        #expect(text.contains("3D +"))
    }

    @Test("a reconnect starts the measurement again")
    func reconnectRestartsTheTimeline() {
        let bench = PrimingBench()
        bench.location.lastFix = fix(secondsAgo: 60, now: bench.bench.clock.now)
        bench.powerOnAndStart()
        bench.receiverSays(fixType: 2)
        #expect(bench.priming.timeline.ttff3D != nil)

        bench.bench.central.reboot()
        bench.bench.settle()
        bench.bench.runUntilReady(within: 10)
        #expect(bench.priming.timeline.ttff3D == nil, "a new link is a new receiver start")
        #expect(bench.location.starts == 2)
    }

    @Test("COMPANION_STATUS is what 'streaming' means, not a successful write")
    func streamingMeansTheDongleSaidSo() {
        let bench = PrimingBench()
        bench.location.lastFix = fix(secondsAgo: 10, now: bench.bench.clock.now)
        bench.powerOnAndStart()
        #expect(bench.priming.sent.hints == 1, "a write went")
        #expect(bench.priming.freshness(now: bench.bench.clock.now) == .never,
                "but nothing has come back, so nothing is streaming")

        let status = CompanionStatus(lastAcceptedSeq: 0, acceptedCount: 1, rejectedCount: 0, queueDropCount: 0)
        bench.bench.deliver(.notified(.companionStatus, status.data))
        #expect(bench.priming.status?.acceptedCount == 1)
        #expect(bench.priming.freshness(now: bench.bench.clock.now) == .live)
    }

    @Test("a firmware with no UTC_SYNC gets fixes and no clock")
    func partialFirmware() {
        var dongle = FakeCentral.Dongle()
        dongle.characteristics = [.gnssFix, .protocolVersion, .gnssQuality]
        let bench = PrimingBench(dongle: dongle, lastFix: nil)
        bench.location.lastFix = fix(secondsAgo: 30, now: bench.bench.clock.now)
        bench.powerOnAndStart()

        #expect(bench.clockWrites.isEmpty)
        #expect(bench.priming.sent.hints == 1)
    }

    @Test("writes are refused while the link is down, and counted")
    func writesRefusedWithoutALink() {
        let bench = PrimingBench()
        bench.location.lastFix = fix(secondsAgo: 30, now: bench.bench.clock.now)
        bench.powerOnAndStart()
        let before = bench.writes.count

        bench.bench.central.stopAdvertising()
        bench.bench.settle()
        bench.location.deliver(fix(secondsAgo: 0, now: bench.bench.clock.now))
        #expect(bench.writes.count == before, "nothing is written to a link that is not there")
    }
}
