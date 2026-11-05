import CairnKit
import CairnProtocol
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let car = "303132333435363738393a3b3c3d3e3f"

/// A server that answers a script, in order, and remembers what it was asked.
private final class ScriptedServer: HTTPTransport, @unchecked Sendable {
    struct Answer {
        let status: Int
        let body: Data
        init(status: Int = 200, json: [String: Any]) {
            self.status = status
            self.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
    }

    private let lock = NSLock()
    private var answers: [String: [Answer]]
    private(set) var targets: [String] = []

    init(_ answers: [String: [Answer]]) { self.answers = answers }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock {
            targets.append(request.target)
            let route = request.target.split(separator: "?").first.map(String.init) ?? request.target
            guard var queued = answers[route], !queued.isEmpty else {
                return HTTPResponse(status: 500, headers: [:], body: Data())
            }
            let next = queued.removeFirst()
            answers[route] = queued
            return HTTPResponse(status: next.status, headers: ["Content-Type": "application/json"], body: next.body)
        }
    }

    func asked(_ route: String) -> Int {
        lock.withLock { targets.filter { $0.hasPrefix(route) }.count }
    }
}

private actor MemorySyncStore: SyncStore {
    private(set) var cursor: SyncCursor?
    private(set) var book: TripBook?
    private(set) var saves = 0
    var failNextSave = false

    func loadCursor() -> SyncCursor? { cursor }
    func loadBook() -> TripBook? { book }

    func save(book: TripBook, cursor: SyncCursor) throws {
        if failNextSave {
            failNextSave = false
            throw CairnServerError.malformedResponse
        }
        self.book = book
        self.cursor = cursor
        saves += 1
    }

    func setFailNextSave(_ value: Bool) { failNextSave = value }
}

private func tripEntity(_ sequence: Int64, startedMs: Int64, durationMs: Int64, distance: Int64) -> [String: Any] {
    [
        "server_sequence": sequence,
        "at": startedMs,
        "type": "entity",
        "entity_type": "trip_summary",
        "entity_id": "\(car):\(startedMs)",
        "vehicle_id": car,
        "data": [
            "started_ms": startedMs,
            "ended_ms": startedMs + durationMs,
            "duration_ms": durationMs,
            "driving_ms": durationMs,
            "distance_m": distance,
            "leg_count": 1,
        ],
    ]
}

private func page(cursor: String, epoch: String = "e1", hasMore: Bool, changes: [[String: Any]]) -> [String: Any] {
    ["cursor": cursor, "epoch": epoch, "has_more": hasMore, "changes": changes]
}

@MainActor
private func makeEngine(_ server: ScriptedServer, store: MemorySyncStore) async -> SyncEngine {
    let identityStore = InMemoryIdentityStore()
    let keys = SoftwareKeyProvider()
    try? await identityStore.save(state: .enrolled, identity: EnrolledIdentity(
        clientID: "0190c0de000070008000000000000a02", role: "user", scope: ["*"],
        instanceID: "inst1", spkiSHA256: String(repeating: "ab", count: 32),
        localBaseURL: "https://cairn.example.lan", tailnetBaseURL: "",
        publicKeyHex: keys.publicKeyHex
    ))
    let session = ServerSession(
        enrolment: EnrolmentService(keyProvider: keys, identityStore: identityStore),
        tokenStore: InMemoryBearerTokenStore(),
        transportFor: { _ in server }
    )
    await session.load()
    await session.chooseRoute(force: true)
    return SyncEngine(session: session, store: store, now: { t0 })
}

@MainActor
@Suite("SyncEngine")
struct SyncEngineTests {
    private let health: [String: Any] = [
        "status": "ok", "protocol_version": 1, "instance_id": "inst1",
        "server_time": "2026-09-21T13:33:20Z",
    ]

    @Test("it pulls every page, not just the first")
    func pullsEveryPage() async {
        // "Loop until has_more is false" (sync/v1 §5). A page is not a sync, and a client
        // that stops at one silently holds a partial history that looks complete.
        let server = ScriptedServer([
            "/v1/health": [.init(json: health)],
            "/v1/sync/pull": [
                .init(json: page(cursor: "c1", hasMore: true, changes: [
                    tripEntity(1, startedMs: 1_790_000_000_000, durationMs: 600_000, distance: 5000),
                ])),
                .init(json: page(cursor: "c2", hasMore: true, changes: [
                    tripEntity(2, startedMs: 1_790_010_000_000, durationMs: 600_000, distance: 6000),
                ])),
                .init(json: page(cursor: "c3", hasMore: false, changes: [])),
            ],
            "/v1/sync/ack": [.init(json: ["acknowledged": 1]), .init(json: ["acknowledged": 2]),
                             .init(json: ["acknowledged": 3])],
        ])
        let store = MemorySyncStore()
        let engine = await makeEngine(server, store: store)

        #expect(await engine.sync())
        #expect(engine.trips.count == 2)
        #expect(engine.cursor?.value == "c3")
        #expect(server.asked("/v1/sync/pull") == 3)
        #expect(server.asked("/v1/sync/ack") == 3, "each page is acknowledged after it is saved")
    }

    @Test("the cursor is saved with the page it came from, not before it")
    func cursorAndPageTogether() async {
        // A cursor saved without its page is a trip nobody will ever pull again.
        let server = ScriptedServer([
            "/v1/health": [.init(json: health)],
            "/v1/sync/pull": [.init(json: page(cursor: "c1", hasMore: false, changes: [
                tripEntity(1, startedMs: 1_790_000_000_000, durationMs: 600_000, distance: 5000),
            ]))],
            "/v1/sync/ack": [.init(json: ["acknowledged": 1])],
        ])
        let store = MemorySyncStore()
        let engine = await makeEngine(server, store: store)
        await store.setFailNextSave(true)

        #expect(await engine.sync() == false, "a save that fails is a sync that failed")
        #expect(engine.cursor == nil, "and the cursor did not move")
        #expect(server.asked("/v1/sync/ack") == 0, "nor was the server told it had")
    }

    @Test("410 throws away what the server gave and pulls again from nothing")
    func cursorReset() async {
        // The one that would quietly lose a history if it were read as "up to date".
        let server = ScriptedServer([
            "/v1/health": [.init(json: health)],
            "/v1/sync/pull": [
                .init(status: 410, json: ["error": "cursor_reset", "epoch": "e2"]),
                .init(json: page(cursor: "c9", epoch: "e2", hasMore: false, changes: [
                    tripEntity(1, startedMs: 1_790_020_000_000, durationMs: 300_000, distance: 2000),
                ])),
            ],
            "/v1/sync/ack": [.init(json: ["acknowledged": 1])],
        ])
        let store = MemorySyncStore()
        let engine = await makeEngine(server, store: store)
        engine.apply(decode(page(cursor: "old", hasMore: false, changes: [
            tripEntity(1, startedMs: 1_790_000_000_000, durationMs: 600_000, distance: 5000),
        ])))
        #expect(engine.trips.count == 1, "something derived from the old epoch")

        #expect(await engine.sync())
        #expect(engine.resets == 1)
        #expect(engine.cursor?.epoch == "e2")
        #expect(engine.trips.count == 1)
        #expect(engine.trips.first?.distanceMetres == 2000)
    }

    @Test("a tombstone takes a trip away")
    func tombstone() {
        let engine = SyncEngine(
            session: ServerSession(
                enrolment: EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: InMemoryIdentityStore()),
                tokenStore: InMemoryBearerTokenStore(),
                transportFor: { _ in nil }
            ),
            store: MemorySyncStore()
        )
        let id = "\(car):1790000000000"
        engine.apply(decode(page(cursor: "c", hasMore: false, changes: [
            tripEntity(1, startedMs: 1_790_000_000_000, durationMs: 600_000, distance: 5000),
        ])))
        #expect(engine.trips.count == 1)

        engine.apply(decode(page(cursor: "c", hasMore: false, changes: [[
            "server_sequence": 2, "at": 1, "type": "tombstone",
            "entity_type": "trip_summary", "entity_id": id, "vehicle_id": car, "deleted": true,
        ]])))
        #expect(engine.trips.isEmpty)
    }

    @Test("an entity type this build does not know is skipped, not fatal")
    func unknownEntity() {
        // The log is shared with a dashboard that knows more kinds than a phone needs.
        let engine = SyncEngine(
            session: ServerSession(
                enrolment: EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: InMemoryIdentityStore()),
                tokenStore: InMemoryBearerTokenStore(),
                transportFor: { _ in nil }
            ),
            store: MemorySyncStore()
        )
        engine.apply(decode(page(cursor: "c", hasMore: false, changes: [
            ["server_sequence": 1, "at": 1, "type": "entity", "entity_type": "place",
             "entity_id": "p1", "vehicle_id": car, "data": ["name": "home"]],
            tripEntity(2, startedMs: 1_790_000_000_000, durationMs: 600_000, distance: 5000),
        ])))
        #expect(engine.trips.count == 1, "the trip beside it still landed")
    }

    @Test("an operation coming back down the log is not a trip")
    func operationsAreNotTrips() {
        let engine = SyncEngine(
            session: ServerSession(
                enrolment: EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: InMemoryIdentityStore()),
                tokenStore: InMemoryBearerTokenStore(),
                transportFor: { _ in nil }
            ),
            store: MemorySyncStore()
        )
        engine.apply(decode(page(cursor: "c", hasMore: false, changes: [[
            "server_sequence": 1, "at": 1, "type": "operation",
            "operation": ["operation_id": "x", "kind": "maintenance_event"],
        ]])))
        #expect(engine.trips.isEmpty)
    }

    @Test("a push that comes back duplicate is a success, because the operations are idempotent")
    func duplicateIsSuccess() {
        #expect(PushStatus.duplicate.isAccepted)
        #expect(PushStatus.accepted.isAccepted)
        #expect(!PushStatus.rejected.isAccepted)
        #expect(!PushStatus.conflict.isAccepted)
        #expect(PushStatus.unknown("something_new").wireValue == "something_new")
    }

    @Test("a server that cannot be reached is a failure in words, not a crash")
    func unreachable() async {
        let server = ScriptedServer(["/v1/health": [.init(status: 503, json: [:])]])
        let engine = await makeEngine(server, store: MemorySyncStore())
        #expect(await engine.sync() == false)
        #expect(engine.lastFailure != nil)
    }

    private func decode(_ json: [String: Any]) -> PullPage {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(PullPage.self, from: data)
    }
}
