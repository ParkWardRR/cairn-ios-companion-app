import CairnKit
import CairnProtocol
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(
    age: TimeInterval, hacc: Double = 5, vacc: Double = 8,
    speed: Double = -1, course: Double = -1, from: Date = t0
) -> PhoneGNSSFix {
    PhoneGNSSFix(
        latitude: 37.7749, longitude: -122.4194, ellipsoidalAltitude: 12.34,
        horizontalAccuracy: hacc, verticalAccuracy: vacc,
        speed: speed, course: course, timestamp: from.addingTimeInterval(-age)
    )
}

private func quality(fixType: UInt8) -> GNSSQuality {
    GNSSQuality(fixType: fixType, satsUsed: 7, hdopE2: 120, fixAgeMs: 0)
}

private let everything = PrimingPolicy.Capabilities(canSyncClock: true, canSendFix: true)

@Suite("PrimingPolicy")
struct PrimingPolicyTests {
    @Test("nothing is sent before the link is ready")
    func silentWithoutALink() {
        var policy = PrimingPolicy()
        #expect(policy.next(now: t0, location: fix(age: 0), isCharging: false).isEmpty)
        #expect(policy.nextDue(now: t0) == nil)
    }

    @Test("the clock goes at link-ready and once a minute after")
    func clockCadence() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)

        let first = policy.next(now: t0, location: nil, isCharging: false)
        #expect(first.count == 1)
        guard case .clock(let payload) = first[0] else { Issue.record("not a clock"); return }
        #expect(payload.unixMs == UInt64(t0.timeIntervalSince1970 * 1000))

        // Not again until the minute is up.
        #expect(policy.next(now: t0.addingTimeInterval(59), location: nil, isCharging: false).isEmpty)
        let second = policy.next(now: t0.addingTimeInterval(60), location: nil, isCharging: false)
        #expect(second.count == 1)
        if case .clock = second[0] {} else { Issue.record("expected a clock at 60 s") }
    }

    @Test("the position hint goes once, from a fix minutes old, flagged HINT")
    func hintGoesOnce() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        _ = policy.next(now: t0, location: nil, isCharging: false) // clock only; no location yet

        let cached = fix(age: 420)
        let actions = policy.next(now: t0.addingTimeInterval(0.2), location: cached, isCharging: false)
        guard case .positionHint(let payload)? = actions.first else {
            Issue.record("no hint: \(actions)"); return
        }
        #expect(payload.isHint)
        #expect(payload.validity.contains(.position))
        // Saturated, which is all a seven-minute-old fix can honestly say about itself.
        #expect(payload.sampleAgeMs == 0xFFFF)
        #expect(policy.timeline.sentPositionHint)

        // And never a second time on the same link.
        let later = policy.next(now: t0.addingTimeInterval(5), location: cached, isCharging: false)
        #expect(!later.contains { if case .positionHint = $0 { true } else { false } })
    }

    @Test("the hint and a live fix never go in the same breath")
    func hintDoesNotDoubleAsAFix() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        let actions = policy.next(now: t0, location: fix(age: 300), isCharging: false)
        // Clock and hint, and no live fix: the same position twice, the second claiming to be a
        // measurement, is exactly what the staleness rules exist to prevent.
        #expect(actions.filter { if case .liveFix = $0 { true } else { false } }.isEmpty)
        #expect(actions.contains { if case .positionHint = $0 { true } else { false } })
    }

    @Test("no hint once the receiver already has a fix, and it says why")
    func noHintWhenTheReceiverIsAlreadyFixed() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        policy.receiverReported(quality(fixType: 2), at: t0)
        _ = policy.next(now: t0, location: fix(age: 300), isCharging: false)
        #expect(!policy.timeline.sentPositionHint)
        #expect(policy.hintSkipped == .receiverAlreadyHasAFix)
    }

    @Test("a fix from days ago is not worth hinting with, and it says so")
    func hintTooOld() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        _ = policy.next(now: t0, location: fix(age: 3 * 24 * 3600), isCharging: false)
        #expect(!policy.timeline.sentPositionHint)
        if case .tooOld = policy.hintSkipped {} else { Issue.record("got \(String(describing: policy.hintSkipped))") }
    }

    @Test("a cached fix with no usable position is not a hint")
    func hintNeedsAPosition() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        _ = policy.next(now: t0, location: fix(age: 60, hacc: -1), isCharging: false)
        #expect(policy.hintSkipped == .noPosition)
    }

    @Test("a firmware with no GNSS_FIX gets the clock and nothing else")
    func clockOnlyFirmware() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: .init(canSyncClock: true, canSendFix: false))
        let actions = policy.next(now: t0, location: fix(age: 0), isCharging: false)
        #expect(actions.count == 1)
        if case .clock = actions[0] {} else { Issue.record("expected only a clock") }
        #expect(policy.hintSkipped == .firmwareHasNoGNSSFix)
    }

    @Test("live fixes go at 1 Hz, then at 0.2 Hz once the receiver has 3D")
    func cadenceDropsOnceSettled() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        _ = policy.next(now: t0, location: fix(age: 0), isCharging: false) // clock + hint

        #expect(policy.cadence == PrimingPolicy.liveCadence)
        var now = t0.addingTimeInterval(1)
        var live = 0
        for _ in 0..<5 {
            live += policy.next(now: now, location: fix(age: 0, from: now), isCharging: false)
                .filter { if case .liveFix = $0 { true } else { false } }.count
            now = now.addingTimeInterval(1)
        }
        #expect(live == 5, "one a second while the receiver is still looking")

        policy.receiverReported(quality(fixType: 2), at: now)
        #expect(policy.cadence == PrimingPolicy.settledCadence)
        live = 0
        for _ in 0..<5 {
            live += policy.next(now: now, location: fix(age: 0, from: now), isCharging: false)
                .filter { if case .liveFix = $0 { true } else { false } }.count
            now = now.addingTimeInterval(1)
        }
        #expect(live == 1, "one in five seconds once it has found the sky, got \(live)")
    }

    @Test("a stale live fix is skipped rather than sent late")
    func staleLiveFixIsSkipped() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        _ = policy.next(now: t0, location: fix(age: 0), isCharging: false)
        // Three seconds old: past the two-second rule, and the firmware would reject it anyway.
        let actions = policy.next(now: t0.addingTimeInterval(2), location: fix(age: 3, from: t0.addingTimeInterval(2)), isCharging: false)
        #expect(actions.filter { if case .liveFix = $0 { true } else { false } }.isEmpty)
    }

    @Test("the charging bit rides along on everything")
    func chargingBit() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        let actions = policy.next(now: t0, location: fix(age: 300), isCharging: true)
        guard case .positionHint(let payload)? = actions.last else { Issue.record("no hint"); return }
        #expect(payload.flags.contains(.charging))
        #expect(payload.flags.contains(.hint))
        #expect(payload.companionFlags == 0x03)
    }

    @Test("the sequence number rises across hints and fixes and wraps rather than trapping")
    func seqRises() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        var now = t0
        var seqs: [UInt16] = []
        for _ in 0..<4 {
            for action in policy.next(now: now, location: fix(age: 0, from: now), isCharging: false) {
                if case .liveFix(let payload) = action { seqs.append(payload.seq) }
                if case .positionHint(let payload) = action { seqs.append(payload.seq) }
            }
            now = now.addingTimeInterval(1)
        }
        #expect(seqs == Array(0..<UInt16(seqs.count)))
    }

    @Test("a new link starts the whole thing over")
    func relinkResets() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        _ = policy.next(now: t0, location: fix(age: 300), isCharging: false)
        #expect(policy.timeline.sentPositionHint)

        policy.linkEnded()
        let later = t0.addingTimeInterval(600)
        policy.linkBecameReady(at: later, capabilities: everything)
        #expect(!policy.timeline.sentPositionHint, "a new link is a new receiver start")
        #expect(policy.timeline.linkReadyAt == later)
        let actions = policy.next(now: later, location: fix(age: 300, from: later), isCharging: false)
        #expect(actions.contains { if case .positionHint = $0 { true } else { false } })
    }

    @Test("it says when it next has something to do, so nothing polls")
    func nextDue() {
        var policy = PrimingPolicy()
        policy.linkBecameReady(at: t0, capabilities: everything)
        #expect(policy.nextDue(now: t0) == t0)
        _ = policy.next(now: t0, location: fix(age: 0), isCharging: false)
        #expect(policy.nextDue(now: t0) == t0.addingTimeInterval(PrimingPolicy.liveCadence))
    }
}

@Suite("ReceiverTimeline")
struct ReceiverTimelineTests {
    @Test("it measures from link-ready, which is the moment the firmware's own line starts")
    func measuresFromLinkReady() {
        var timeline = ReceiverTimeline(linkReadyAt: t0)
        timeline.clockHintAt = t0.addingTimeInterval(0.1)
        timeline.positionHintAt = t0.addingTimeInterval(0.3)
        timeline.observe(fixType: 1, at: t0.addingTimeInterval(18.4))
        timeline.observe(fixType: 2, at: t0.addingTimeInterval(24.9))

        #expect(abs((timeline.ttff2D ?? 0) - 18.4) < 0.001)
        #expect(abs((timeline.ttff3D ?? 0) - 24.9) < 0.001)
        #expect(timeline.line == "link 0.0 · clock +0.1 · hint +0.3 · 2D +18.4 · 3D +24.9")
    }

    @Test("the first of each is the one that counts")
    func firstOnly() {
        var timeline = ReceiverTimeline(linkReadyAt: t0)
        timeline.observe(fixType: 2, at: t0.addingTimeInterval(10))
        timeline.observe(fixType: 2, at: t0.addingTimeInterval(11))
        #expect(timeline.ttff3D == 10)
        // A 3D fix is a 2D fix too: the first quality report that has one answers both.
        #expect(timeline.ttff2D == 10)
    }

    @Test("what has not happened reads as a dash, not as zero")
    func unknownIsADash() {
        var timeline = ReceiverTimeline(linkReadyAt: t0)
        timeline.clockHintAt = t0
        #expect(timeline.line == "link 0.0 · clock +0.0 · hint — · 2D — · 3D —")
        #expect(timeline.ttff3D == nil)
    }

    @Test("with no link there is nothing to measure against")
    func noLink() {
        #expect(ReceiverTimeline().line == "no link")
        #expect(ReceiverTimeline().seconds(t0) == nil)
    }
}
