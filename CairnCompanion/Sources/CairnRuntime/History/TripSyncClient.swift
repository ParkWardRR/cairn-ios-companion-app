import CairnCore
import Foundation
import os

/// Downloads the snapshot archive from the Cairn server, decompresses and extracts it,
/// loads the Parquet files into an in-memory DuckDB, and provides trip data for the History tab.
///
/// Supports two server endpoints (LAN and Tailnet) with automatic route selection.
/// The LAN URL is probed first; if it doesn't respond within 2 s the Tailnet URL is tried.
/// Both routes must return the same `instance_id` from `/v1/health`.
///
/// The snapshot is replaced atomically. If the download fails, the previous cache stays valid.
@MainActor
public final class TripSyncClient {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "sync")
    private static let staleAfter: TimeInterval = 3600
    private static let lanURLKey = "cairn.tripSyncServerURL"
    private static let tailnetURLKey = "cairn.tailnetServerURL"
    private static let etagKey = "cairn.snapshotETag"
    private static let lastSyncKey = "cairn.lastSnapshotSync"
    private static let manifestKey = "cairn.snapshotManifest"
    private static let instanceIDKey = "cairn.enrolledInstanceID"
    private static let lanProbeTimeout: TimeInterval = 2

    public enum SyncState: Sendable, Equatable {
        case idle
        case syncing
        case failed(String)
    }

    public enum Route: String, Sendable {
        case lan = "LAN"
        case tailnet = "Tailnet"
        case unreachable = "Unreachable"
    }

    public struct ProbeResult: Sendable {
        public let route: Route
        public let latencyMs: Int
        public let instanceID: String?
        public let error: String?
        public let probedAt: Date
    }

    public private(set) var state: SyncState = .idle
    public private(set) var lastSyncAt: Date?
    public private(set) var manifest: SnapshotManifest?
    public private(set) var activeRoute: Route = .unreachable
    public private(set) var lastLANProbe: ProbeResult?
    public private(set) var lastTailnetProbe: ProbeResult?

    private let store = SnapshotStore()
    private var cachedSnapshots: [TripSnapshot] = []
    private let enrolmentService: EnrolmentService?

    private var snapshotDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("snapshot", isDirectory: true)
    }

    public init(enrolmentService: EnrolmentService? = nil) {
        self.enrolmentService = enrolmentService
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        if let data = UserDefaults.standard.data(forKey: Self.manifestKey) {
            manifest = try? JSONDecoder().decode(SnapshotManifest.self, from: data)
        }
        Self.protectSnapshotDir(snapshotDir)
    }

    private static func protectSnapshotDir(_ dir: URL) {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        #endif
    }

    // MARK: - URL Management

    public var serverURL: String {
        get { lanURL }
        set { lanURL = newValue }
    }

    public var lanURL: String {
        get { UserDefaults.standard.string(forKey: Self.lanURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.lanURLKey) }
    }

    public var tailnetURL: String {
        get { UserDefaults.standard.string(forKey: Self.tailnetURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.tailnetURLKey) }
    }

    public var hasServer: Bool {
        hasLAN || hasTailnet
    }

    public var hasLAN: Bool {
        !lanURL.isEmpty && URL(string: lanURL) != nil
    }

    public var hasTailnet: Bool {
        !tailnetURL.isEmpty && URL(string: tailnetURL) != nil
    }

    public var enrolledInstanceID: String? {
        get { UserDefaults.standard.string(forKey: Self.instanceIDKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.instanceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.instanceIDKey)
            }
        }
    }

    // MARK: - Health Probe

    public func probeEndpoints() async {
        async let lanResult = probe(urlString: lanURL, route: .lan, timeout: Self.lanProbeTimeout)
        async let tailnetResult = probe(urlString: tailnetURL, route: .tailnet, timeout: 10)

        lastLANProbe = await lanResult
        lastTailnetProbe = await tailnetResult

        if let lan = lastLANProbe, lan.error == nil, lan.instanceID != nil {
            activeRoute = .lan
        } else if let tailnet = lastTailnetProbe, tailnet.error == nil, tailnet.instanceID != nil {
            activeRoute = .tailnet
        } else {
            activeRoute = .unreachable
        }
    }

    private func probe(urlString: String, route: Route, timeout: TimeInterval) async -> ProbeResult? {
        guard !urlString.isEmpty, let base = URL(string: urlString) else { return nil }
        let healthURL = base.appendingPathComponent("v1/health")
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = timeout

        let start = Date()
        do {
            let (data, response) = try await CairnURLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ProbeResult(route: route, latencyMs: latency, instanceID: nil,
                                   error: "HTTP \(code)", probedAt: Date())
            }
            let instanceID = parseInstanceID(from: data)
            return ProbeResult(route: route, latencyMs: latency, instanceID: instanceID,
                               error: nil, probedAt: Date())
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return ProbeResult(route: route, latencyMs: latency, instanceID: nil,
                               error: ProbeFailure.message(
                                    for: (error as? URLError)?.code, tailnet: route == .tailnet,
                                    fallback: error.localizedDescription),
                               probedAt: Date())
        }
    }

    private func parseInstanceID(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["instance_id"] as? String
    }

    /// Resolve the best base URL: try LAN first, fall back to Tailnet.
    private func resolveBaseURL() async -> (URL, Route)? {
        if hasLAN, let lanBase = URL(string: lanURL) {
            let result = await probe(urlString: lanURL, route: .lan, timeout: Self.lanProbeTimeout)
            lastLANProbe = result
            if let r = result, r.error == nil {
                activeRoute = .lan
                return (lanBase, .lan)
            }
        }

        if hasTailnet, let tailnetBase = URL(string: tailnetURL) {
            let result = await probe(urlString: tailnetURL, route: .tailnet, timeout: 10)
            lastTailnetProbe = result
            if let r = result, r.error == nil {
                activeRoute = .tailnet
                return (tailnetBase, .tailnet)
            }
        }

        activeRoute = .unreachable
        return nil
    }

    /// A signed client for the enrolled phone on whichever route answers (LAN first, then Tailnet),
    /// or nil with the reason when there is none. Used by the bundle offload, which shares this
    /// phone's identity and routes with the History sync.
    public func makeServerClient() async -> (client: CairnServerClient, route: Route)? {
        guard let (baseURL, route) = await resolveBaseURL(), let signer = await enrolmentService?.makeSigner() else { return nil }
        return (CairnServerClient(transport: URLSessionTransport(baseURL: baseURL), signer: signer), route)
    }

    // MARK: - Snapshot Cache

    public func loadCachedSnapshot() async {
        let dir = snapshotDir.appendingPathComponent("parquet", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let tables = manifest?.tables ?? [
            "bundles", "position", "imu", "obd", "boost",
            "status", "transition", "gap", "drive_summary",
            "trip_summary",
        ]

        do {
            try await store.load(parquetDir: dir, tables: tables)
            cachedSnapshots = try await store.trips()
            Self.log.notice("loaded \(self.cachedSnapshots.count) cached trips")
        } catch {
            Self.log.error("failed to load cached snapshot: \(error)")
        }
    }

    public func cachedTrips() -> [TripSnapshot] {
        cachedSnapshots
    }

    #if DEBUG
    /// Screenshots in the simulator: stand-in server trips, as the snapshot would have produced them.
    public func injectDemoTrips(_ trips: [TripSnapshot]) {
        cachedSnapshots = trips
    }
    #endif

    // MARK: - Sync

    public func sync() {
        guard state != .syncing else { return }
        guard hasServer else {
            state = .failed("No server configured")
            return
        }
        state = .syncing
        Task { await performSync() }
    }

    private func performSync() async {
        guard let (baseURL, route) = await resolveBaseURL() else {
            state = .failed("Server unreachable on both LAN and Tailnet")
            return
        }

        let signer = await enrolmentService?.makeSigner()
        if signer == nil, let (enrolment, _) = await enrolmentService?.loadIdentity() {
            switch enrolment {
            case .needsReenrolment:
                state = .failed("This phone must be set up again: open Settings, or scan a new setup QR code from the dashboard.")
                return
            case .revoked:
                state = .failed("The server has revoked this phone. Reset the identity in Settings and scan a new setup QR code.")
                return
            default:
                break
            }
        }

        do {
            let path = signer != nil ? "v1/snapshot" : "api/snapshot"
            var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "format", value: "tar")]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30

            if let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            if let signer {
                let target = "/\(path)?format=tar"
                let auth = Self.signRequest(method: "GET", target: target, body: Data(), signer: signer)
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await CairnURLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed("Invalid response")
                return
            }

            if http.statusCode == 304 {
                lastSyncAt = Date()
                UserDefaults.standard.set(lastSyncAt, forKey: Self.lastSyncKey)
                state = .idle
                Self.log.notice("snapshot unchanged (304) via \(route.rawValue)")
                return
            }

            guard http.statusCode == 200 else {
                state = .failed(http.statusCode == 401 && signer != nil
                    ? "The server did not accept this phone's sign-in (401). Scan a new setup QR code from the dashboard."
                    : "Server returned \(http.statusCode)")
                return
            }

            let extracted = try SnapshotArchive.extract(archive: data, to: snapshotDir)

            try await store.load(parquetDir: extracted.parquetDir, tables: extracted.manifest.tables)
            cachedSnapshots = try await store.trips()

            if let etag = http.value(forHTTPHeaderField: "ETag") {
                UserDefaults.standard.set(etag, forKey: Self.etagKey)
            }
            manifest = extracted.manifest
            if let mData = try? JSONEncoder().encode(extracted.manifest) {
                UserDefaults.standard.set(mData, forKey: Self.manifestKey)
            }
            lastSyncAt = Date()
            UserDefaults.standard.set(lastSyncAt, forKey: Self.lastSyncKey)
            activeRoute = route
            state = .idle
            Self.log.notice("synced \(self.cachedSnapshots.count) trips via \(route.rawValue)")
        } catch {
            state = .failed(error.localizedDescription)
            Self.log.error("sync failed: \(error)")
        }
    }

    private static func signRequest(
        method: String, target: String, body: Data, signer: any RequestSigner
    ) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let nonce = SigningString.freshNonce()
        let bodyHash = SigningString.bodyHash(body)
        let signingData = SigningString.build(
            method: method, target: target, timestamp: ts,
            nonce: nonce, bodyHash: bodyHash, clientID: signer.clientID
        )
        guard let signatureDER = try? signer.sign(signingData) else { return "" }
        return SigningString.authorizationHeader(
            clientID: signer.clientID, timestamp: ts, nonce: nonce, signatureDER: signatureDER
        )
    }

    public var isStale: Bool {
        guard hasServer else { return false }
        guard let lastSync = lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSync) > Self.staleAfter
    }
}
