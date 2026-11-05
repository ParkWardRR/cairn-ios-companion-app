import CairnKit
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let mine = "inst_7f3a91"

private func lan(_ instance: String?, rtt: TimeInterval? = 0.004, failure: String? = nil) -> RoutePicker.Probe {
    RoutePicker.Probe(route: .lan, url: "https://cairn.example.lan:8443",
                      instanceID: instance, roundTrip: rtt, failure: failure)
}

private func tailnet(_ instance: String?, rtt: TimeInterval? = 0.035, failure: String? = nil) -> RoutePicker.Probe {
    RoutePicker.Probe(route: .tailnet, url: "https://cairn.example.ts.net",
                      instanceID: instance, roundTrip: rtt, failure: failure)
}

@Suite("RoutePicker")
struct RoutePickerTests {
    @Test("the LAN wins when both answer: faster, and it does not leave the house")
    func lanFirst() {
        var picker = RoutePicker()
        let chosen = picker.choose(from: [tailnet(mine), lan(mine)], expecting: mine, now: t0)
        #expect(chosen?.route == .lan)
        #expect(chosen?.url.contains("example.lan") == true)
    }

    @Test("the Tailnet is taken when the LAN is not there")
    func tailnetFallback() {
        var picker = RoutePicker()
        let chosen = picker.choose(
            from: [lan(nil, rtt: nil, failure: "no route to host"), tailnet(mine)],
            expecting: mine, now: t0
        )
        #expect(chosen?.route == .tailnet)
    }

    @Test("a server that answers and is not yours is refused, by name")
    func wrongInstance() {
        // A health endpoint that answers is not proof it is your server. A captive portal
        // answers everything, and so does the wrong Cairn on a shared network.
        var picker = RoutePicker()
        let chosen = picker.choose(from: [lan("inst_someoneelse")], expecting: mine, now: t0)
        #expect(chosen == nil)
        guard case .wrongInstance(let route, _, let got)? = picker.lastRefusal else {
            Issue.record("got \(String(describing: picker.lastRefusal))"); return
        }
        #expect(route == .lan)
        #expect(got == "inst_someoneelse")
        #expect(picker.lastRefusal?.sentence.contains("not the Cairn server") == true)
    }

    @Test("the wrong server on one route does not stop the right one on the other")
    func wrongOnOneRightOnTheOther() {
        var picker = RoutePicker()
        let chosen = picker.choose(from: [lan("inst_cafe_wifi"), tailnet(mine)], expecting: mine, now: t0)
        #expect(chosen?.route == .tailnet)
        #expect(picker.lastRefusal == nil, "a route was found, so there is nothing to refuse")
    }

    @Test("nothing answering says so, with what each address did")
    func noneAnswered() {
        var picker = RoutePicker()
        let chosen = picker.choose(
            from: [lan(nil, rtt: nil, failure: "timed out"), tailnet(nil, rtt: nil, failure: "offline")],
            expecting: mine, now: t0
        )
        #expect(chosen == nil)
        #expect(picker.lastRefusal == .noneAnswered(["timed out", "offline"]))
        #expect(picker.lastRefusal?.sentence.contains("timed out") == true)
    }

    @Test("a chosen route is cached for ten minutes and then is not")
    func cacheWindow() {
        var picker = RoutePicker()
        _ = picker.choose(from: [lan(mine)], expecting: mine, now: t0)
        #expect(picker.cachedRoute(now: t0.addingTimeInterval(599))?.route == .lan)
        #expect(picker.cachedRoute(now: t0.addingTimeInterval(601)) == nil,
                "probing twice a second during a drive is a waste of radio; so is trusting an hour-old answer")
    }

    @Test("a failed request can throw the cache away")
    func invalidate() {
        var picker = RoutePicker()
        _ = picker.choose(from: [lan(mine)], expecting: mine, now: t0)
        picker.invalidate()
        #expect(picker.cachedRoute(now: t0) == nil)
    }

    @Test("a refusal clears the cache rather than leaving a stale route behind")
    func refusalClearsTheCache() {
        var picker = RoutePicker()
        _ = picker.choose(from: [lan(mine)], expecting: mine, now: t0)
        _ = picker.choose(from: [lan(nil, failure: "gone")], expecting: mine, now: t0.addingTimeInterval(1))
        #expect(picker.cachedRoute(now: t0.addingTimeInterval(1)) == nil)
    }

    @Test("the pin is enforced on the LAN and not on the Tailnet, as sync/v1 §9 says")
    func pinning() {
        // A self-signed CA is what the LAN has. A ts.net name has a real certificate, and
        // pinning it would break at renewal.
        #expect(RoutePicker.Route.lan.pinsCertificate)
        #expect(!RoutePicker.Route.tailnet.pinsCertificate)
    }

    @Test("the probes are kept, so the screen can show what each address did")
    func probesAreKept() {
        var picker = RoutePicker()
        _ = picker.choose(from: [lan(mine), tailnet(nil, rtt: nil, failure: "offline")], expecting: mine, now: t0)
        #expect(picker.lastProbes.count == 2)
        #expect(picker.lastProbes.first { $0.route == .tailnet }?.failure == "offline")
    }
}
