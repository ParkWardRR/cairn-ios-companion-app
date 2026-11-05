import CairnProtocol
import Foundation

/// The phone's standing with the server: who it is, and which way it is reaching it.
///
/// One object, because this is one account on one server (`sync/v1` §8): the same `client_id`,
/// the same cursor, the same outbox, whichever route carries them. Never state per route.
@MainActor
@Observable
public final class ServerSession {
    public private(set) var state: EnrolmentState = .notEnrolled
    public private(set) var identity: EnrolledIdentity?
    public private(set) var picker = RoutePicker()
    public private(set) var route: RoutePicker.Chosen?
    public private(set) var lastProbeAt: Date?
    public private(set) var isProbing = false

    private let enrolment: EnrolmentService
    /// Makes a transport for one base URL. Injected so `CairnKit` holds no URLSession.
    private let transportFor: @Sendable (String) -> (any HTTPTransport)?
    /// Makes the transport chunk uploads go over — a background session in the app, and
    /// whatever `transportFor` gives when nothing special is wanted.
    private let chunkTransportFor: @Sendable (String) -> (any HTTPTransport)?
    private let tokenStore: any BearerTokenStore
    private let now: @Sendable () -> Date

    public init(
        enrolment: EnrolmentService,
        tokenStore: any BearerTokenStore,
        transportFor: @escaping @Sendable (String) -> (any HTTPTransport)?,
        chunkTransportFor: (@Sendable (String) -> (any HTTPTransport)?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.enrolment = enrolment
        self.tokenStore = tokenStore
        self.transportFor = transportFor
        self.chunkTransportFor = chunkTransportFor ?? transportFor
        self.now = now
    }

    public var isEnrolled: Bool { state == .enrolled && identity != nil }

    /// What the screens say about the server, in one line.
    public var statusLine: String {
        switch state {
        case .notEnrolled: "Not set up"
        case .enrolling: "Setting up…"
        case .enrolled: route.map { "Connected over \($0.route.title)" } ?? "Enrolled, not reachable"
        case .revoked: "This phone's access was revoked"
        case .needsReenrolment: "This phone's key changed; set it up again"
        }
    }

    public func load() async {
        let (state, identity) = await enrolment.loadIdentity()
        self.state = state
        self.identity = identity
    }

    // MARK: - Enrolment

    /// Enrol against a scanned or pasted `cairn://configure` link.
    ///
    /// Nothing from the link is saved until this succeeds: the link arrives from outside the
    /// app — a camera, a message, anything — and is untrusted until the server it names has
    /// answered for itself.
    @discardableResult
    public func enrol(_ link: ConfigureLink, deviceName: String) async throws -> EnrolledIdentity {
        guard let transport = transportFor(link.serverURL) else {
            throw CairnServerError.invalidArgument("server URL")
        }
        state = .enrolling
        do {
            let identity = try await enrolment.enrol(
                code: link.invitationCode,
                deviceName: deviceName,
                using: CairnServerClient(transport: transport, signer: UnsignedEnrolmentSigner()),
                localBaseURL: link.serverURL,
                tailnetBaseURL: link.tailnetURL
            )
            self.identity = identity
            state = .enrolled
            return identity
        } catch {
            await load()
            throw error
        }
    }

    public func reset() async throws {
        try await enrolment.reset()
        await tokenStore.clear()
        picker.invalidate()
        route = nil
        await load()
    }

    // MARK: - Routing

    /// Probe both addresses and pick one, unless a recent choice still stands.
    ///
    /// The `instance_id` check is what makes this more than a reachability test: a health
    /// endpoint that answers is not proof it is *your* server. A captive portal answers
    /// everything, and so does the wrong Cairn on a shared network.
    @discardableResult
    public func chooseRoute(force: Bool = false) async -> RoutePicker.Chosen? {
        guard let identity else { return nil }
        if !force, let cached = picker.cachedRoute(now: now()) {
            route = cached
            return cached
        }
        isProbing = true
        defer { isProbing = false }

        var probes: [RoutePicker.Probe] = []
        for (kind, url) in [(RoutePicker.Route.lan, identity.localBaseURL),
                            (RoutePicker.Route.tailnet, identity.tailnetBaseURL)] where !url.isEmpty {
            probes.append(await probe(kind, url))
        }
        lastProbeAt = now()
        route = picker.choose(from: probes, expecting: identity.instanceID, now: now())
        return route
    }

    private func probe(_ kind: RoutePicker.Route, _ url: String) async -> RoutePicker.Probe {
        guard let transport = transportFor(url) else {
            return RoutePicker.Probe(route: kind, url: url, failure: "not a usable address")
        }
        let started = now()
        do {
            let health = try await CairnServerClient(transport: transport, signer: UnsignedEnrolmentSigner()).health()
            return RoutePicker.Probe(
                route: kind, url: url, instanceID: health.instanceID,
                roundTrip: now().timeIntervalSince(started)
            )
        } catch {
            return RoutePicker.Probe(route: kind, url: url, failure: Self.describe(error))
        }
    }

    /// A client bound to whichever route is current, signing with this phone's enrolled key.
    /// Nil when the phone is not enrolled or nothing answered.
    public func client() async -> CairnServerClient? {
        guard isEnrolled else { return nil }
        var current = route
        if current == nil { current = await chooseRoute() }
        guard let route = current else { return nil }
        guard let transport = transportFor(route.url), let signer = await enrolment.makeSigner() else { return nil }
        return CairnServerClient(
            transport: transport, signer: signer, tokenStore: tokenStore,
            chunkTransport: chunkTransportFor(route.url)
        )
    }

    /// A request failed on the chosen route: throw the choice away so the next one probes again.
    public func routeFailed() {
        picker.invalidate()
        route = nil
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? CairnServerError else { return "did not answer" }
        switch error {
        case .transport(.offline): return "no route to it"
        case .transport(.timedOut): return "timed out"
        case .transport(.tls): return "this phone does not trust its certificate"
        default: return "answered \(error.httpStatus.map(String.init) ?? "oddly")"
        }
    }
}

/// Signs nothing, for the two calls that happen before this phone has an identity: `/v1/health`
/// and the enrolment itself, which carries its own proof instead.
struct UnsignedEnrolmentSigner: RequestSigner {
    var clientID: String { "" }
    var publicKeyX963: Data { Data() }
    func sign(_ data: Data) throws -> Data { throw CairnServerError.signingFailed }
}
