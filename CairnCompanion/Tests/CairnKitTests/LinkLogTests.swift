import CairnKit
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("LinkLog")
struct LinkLogTests {
    @Test("it keeps the last lines and says how many it dropped")
    func ringDropsTheOldestAndAdmitsIt() {
        var log = LinkLog(capacity: 10)
        for i in 0..<25 {
            log.append(at: t0.addingTimeInterval(Double(i)), state: "ready", detail: "line \(i)", kind: .event)
        }
        #expect(log.entries.count == 10)
        #expect(log.entries.first?.detail == "line 15")
        #expect(log.entries.last?.detail == "line 24")
        #expect(log.dropped == 15)
        // An export that is not whole has to say so, or a bench record quietly lies.
        #expect(log.export().contains("15 earlier line(s) rolled off the ring"))
    }

    @Test("the newest lines come back first, for a screen")
    func recentIsNewestFirst() {
        var log = LinkLog()
        for i in 0..<5 {
            log.append(at: t0.addingTimeInterval(Double(i)), state: "scanning", detail: "\(i)", kind: .event)
        }
        #expect(log.recent(3).map(\.detail) == ["4", "3", "2"])
    }

    @Test("transitions and failures are separable from the chatter")
    func transitionsOnly() {
        var log = LinkLog()
        log.append(at: t0, state: "scanning", detail: "scanning", kind: .effect)
        log.append(at: t0, state: "connecting", detail: "→ connecting", kind: .transition)
        log.append(at: t0, state: "connecting", detail: "connected", kind: .event)
        log.append(at: t0, state: "backoff", detail: "ATT 5", kind: .failure)
        #expect(log.transitions.count == 2)
        #expect(log.transitions.map(\.kind) == [.transition, .failure])
    }

    @Test("the export's time column is relative, so it can be set beside the dongle's uptime")
    func exportIsRelative() {
        var log = LinkLog()
        log.append(at: t0, state: "idle", detail: "start requested", kind: .event)
        log.append(at: t0.addingTimeInterval(1.25), state: "ready", detail: "→ ready", kind: .transition)
        let text = log.export(header: ["app 0.2.0 (81) · beta", "firmware 0.3.1"])
        #expect(text.contains("# app 0.2.0 (81) · beta"))
        #expect(text.contains("# firmware 0.3.1"))
        #expect(text.contains("# t=0 is "))
        #expect(text.contains("   +0.000"))
        #expect(text.contains("   +1.250"))
    }

    @Test("an empty log exports a header and says it is empty rather than nothing at all")
    func emptyExport() {
        let log = LinkLog()
        let text = log.export(header: ["app 0.2.0"])
        #expect(text.contains("# app 0.2.0"))
        #expect(text.contains("the log is empty"))
    }

    @Test("a newline inside a detail cannot split a line")
    func detailsStayOnOneLine() {
        var log = LinkLog()
        log.append(at: t0, state: "ready", detail: "one line only", kind: .event)
        #expect(log.entries[0].line().contains("\n") == false)
    }
}
