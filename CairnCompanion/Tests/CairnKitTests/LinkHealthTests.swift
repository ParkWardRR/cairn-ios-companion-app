import Foundation
import Testing
@testable import CairnKit
@testable import CairnProtocol

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct LinkHealthTests {
    @Test func neverHeardIsNever() {
        #expect(LinkHealth.freshness(lastHeard: nil, now: t0) == .never)
    }

    @Test func freshnessBoundaries() {
        func f(_ age: TimeInterval) -> Freshness {
            LinkHealth.freshness(lastHeard: t0, now: t0.addingTimeInterval(age))
        }
        #expect(f(0) == .live)
        #expect(f(2.99) == .live)
        #expect(f(3) == .stale)
        #expect(f(9.99) == .stale)
        #expect(f(10) == .silent)
        #expect(f(600) == .silent)
    }

    @Test func clockSkewIntoTheFutureIsLive() {
        #expect(LinkHealth.freshness(lastHeard: t0.addingTimeInterval(5), now: t0) == .live)
    }

    @Test func unackedCountsOnlyUnreportedWrites() {
        let status = CompanionStatus(lastAcceptedSeq: 0, acceptedCount: 8, rejectedCount: 1, queueDropCount: 0)
        #expect(LinkHealth.unacked(sent: 12, status: status) == 3)
        #expect(LinkHealth.unacked(sent: 5, status: status) == 0) // never negative
        #expect(LinkHealth.unacked(sent: 4, status: nil) == 4)
    }

    @Test func ageLabels() {
        #expect(LinkHealth.ageLabel(-3) == "0 s")
        #expect(LinkHealth.ageLabel(4.9) == "4 s")
        #expect(LinkHealth.ageLabel(65) == "1 m 05 s")
        #expect(LinkHealth.ageLabel(7380) == "2 h 03 m")
    }
}

@Suite struct LinkEventLogTests {
    @Test func countsDropsAndFindsTheLast() {
        var log = LinkEventLog()
        log.append(.init(at: t0, kind: .ready))
        log.append(.init(at: t0.addingTimeInterval(10), kind: .dropped))
        log.append(.init(at: t0.addingTimeInterval(20), kind: .ready))
        log.append(.init(at: t0.addingTimeInterval(30), kind: .dropped))
        #expect(log.dropCount == 2)
        #expect(log.lastDrop == t0.addingTimeInterval(30))
    }

    @Test func capsAtCapacityKeepingTheNewest() {
        var log = LinkEventLog()
        for i in 0..<(LinkEventLog.capacity + 25) {
            log.append(.init(at: t0.addingTimeInterval(Double(i)), kind: .streamingResumed))
        }
        #expect(log.events.count == LinkEventLog.capacity)
        #expect(log.events.last?.at == t0.addingTimeInterval(Double(LinkEventLog.capacity + 24)))
        #expect(log.events.first?.at == t0.addingTimeInterval(25))
    }

    @Test func removeAllResetsDrops() {
        var log = LinkEventLog()
        log.append(.init(at: t0, kind: .dropped))
        log.removeAll()
        #expect(log.dropCount == 0)
        #expect(log.lastDrop == nil)
    }
}
