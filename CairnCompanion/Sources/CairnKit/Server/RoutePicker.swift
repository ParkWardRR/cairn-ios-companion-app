import Foundation

/// Which way to reach the server, and the check that it is the right server.
///
/// Two addresses come out of enrolment: the LAN one and the Tailnet one (`sync/v1` §9). They are
/// the same server by two routes, and the phone has to pick one each time it has something to
/// say. The rules:
///
/// - **LAN first.** It is faster and it does not leave the house.
/// - **The pinned CA on the LAN URL, ordinary validation on the Tailnet one.** A self-signed CA
///   is what the LAN has; a `ts.net` name has a real certificate and pinning it would break on
///   renewal. That split is the contract's, not a convenience.
/// - **`instance_id` must match the enrolled one.** A health endpoint that answers is not proof
///   it is *your* server: a captive portal answers everything, and so does the wrong Cairn on a
///   shared network. This is the check that makes a route trustworthy rather than reachable.
/// - **Cached for ten minutes.** Probing twice a second during a drive is a waste of radio, and
///   a route that worked ten minutes ago almost always still works.
public struct RoutePicker: Sendable, Equatable {
    public static let cacheFor: TimeInterval = 10 * 60

    public enum Route: String, Sendable, Codable {
        case lan
        case tailnet

        public var title: String {
            switch self {
            case .lan: "LAN"
            case .tailnet: "Tailnet"
            }
        }

        /// Whether the SPKI pin is enforced on this route.
        public var pinsCertificate: Bool { self == .lan }
    }

    public struct Probe: Equatable, Sendable {
        public let route: Route
        public let url: String
        /// What `/v1/health` said its instance was, or nil when it did not answer.
        public let instanceID: String?
        public let roundTrip: TimeInterval?
        public let failure: String?

        public init(route: Route, url: String, instanceID: String? = nil,
                    roundTrip: TimeInterval? = nil, failure: String? = nil) {
            self.route = route
            self.url = url
            self.instanceID = instanceID
            self.roundTrip = roundTrip
            self.failure = failure
        }
    }

    public struct Chosen: Equatable, Sendable {
        public let route: Route
        public let url: String
        public let at: Date
        public let roundTrip: TimeInterval?
    }

    /// Why no route was taken. Each is a different thing to tell somebody.
    public enum Refusal: Equatable, Sendable {
        case noneAnswered([String])
        /// A server answered and is not the one this phone enrolled with.
        case wrongInstance(route: Route, expected: String, got: String)

        public var sentence: String {
            switch self {
            case .noneAnswered(let failures):
                "The server did not answer on either address" + (failures.isEmpty ? "." : ": \(failures.joined(separator: "; ")).")
            case .wrongInstance(let route, _, _):
                "Something answered on the \(route.title) address, but it is not the Cairn server "
                    + "this phone enrolled with. Nothing was sent to it."
            }
        }
    }

    public private(set) var cached: Chosen?
    /// The last probe of each route, for the screen.
    public private(set) var lastProbes: [Probe] = []
    public private(set) var lastRefusal: Refusal?

    public init() {}

    /// Whether the cached route is still worth using.
    public func cachedRoute(now: Date) -> Chosen? {
        guard let cached, now.timeIntervalSince(cached.at) < Self.cacheFor else { return nil }
        return cached
    }

    /// Decide from a set of probes. Pure: the probing itself is the adapter's job.
    public mutating func choose(from probes: [Probe], expecting instanceID: String, now: Date) -> Chosen? {
        lastProbes = probes
        lastRefusal = nil

        // LAN first, then Tailnet, whatever order the probes came back in.
        for route in [Route.lan, Route.tailnet] {
            guard let probe = probes.first(where: { $0.route == route }) else { continue }
            guard let answered = probe.instanceID else { continue }
            guard answered == instanceID else {
                // Keep looking — the other route may be the real one — but remember this, because
                // "something else answered" is a different problem from "nothing answered" and
                // the person should hear which.
                lastRefusal = .wrongInstance(route: route, expected: instanceID, got: answered)
                continue
            }
            // A route was found, so there is nothing to refuse — even if the other address
            // had something else answering on it. The screen can still see that from
            // `lastProbes`, which keeps each answer's `instanceID`; what it must not do is
            // show an alarming refusal beside a working link.
            lastRefusal = nil
            let chosen = Chosen(route: route, url: probe.url, at: now, roundTrip: probe.roundTrip)
            cached = chosen
            return chosen
        }

        if lastRefusal == nil {
            lastRefusal = .noneAnswered(probes.compactMap(\.failure))
        }
        cached = nil
        return nil
    }

    /// Forget the cached route: the network changed, or a request failed on it.
    public mutating func invalidate() { cached = nil }
}
