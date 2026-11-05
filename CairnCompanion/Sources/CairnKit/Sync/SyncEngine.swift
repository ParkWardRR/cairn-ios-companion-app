import CairnProtocol
import Foundation

/// Where the cursor and the reconciled trips live between launches.
public protocol SyncStore: Sendable {
    func loadCursor() async -> SyncCursor?
    /// The page and the cursor must land together: a cursor saved without its page means a
    /// trip nobody will ever pull again, and `sync/v1` §5 says to persist them in the same
    /// transaction for exactly that reason.
    func save(book: TripBook, cursor: SyncCursor) async throws
    func loadBook() async -> TripBook?
}

/// Where the phone is in the server's log.
public struct SyncCursor: Sendable, Equatable, Codable {
    /// Opaque. Never built, never parsed — the spec is explicit, and a cursor this app
    /// invented would silently skip changes.
    public let value: String
    /// Which run of the server's data it belongs to. A cursor from another epoch is a `410`.
    public let epoch: String
    public let at: Date

    public init(value: String, epoch: String, at: Date) {
        self.value = value
        self.epoch = epoch
        self.at = at
    }
}

/// Pull, apply, acknowledge; and push what this phone has to say.
///
/// Every rule here is `sync/v1` §5 and §6, and the two that are easy to get wrong are the ones
/// with comments:
///
/// - **Loop until `has_more` is false.** A page is not a sync.
/// - **`410 cursor_reset` is not "up to date".** It means the server's data was reset or the
///   cursor is older than the retained log, and the answer is to throw away everything
///   server-derived and pull from scratch — keeping the unsent outbox, which is this phone's
///   own and was never the server's to reset.
@MainActor
@Observable
public final class SyncEngine {
    public private(set) var book = TripBook()
    public private(set) var cursor: SyncCursor?
    public private(set) var lastSyncAt: Date?
    public private(set) var lastFailure: String?
    public private(set) var isSyncing = false
    /// How many full resyncs a `410` has cost. Worth showing: it should be rare, and a server
    /// that resets every day is a server with a problem.
    public private(set) var resets = 0

    private let session: ServerSession
    private let store: any SyncStore
    private let now: @MainActor () -> Date
    /// The spec's limit is the server's business; asking for a page at a time keeps a bad
    /// answer small and the transaction short.
    private let pageSize = 200
    /// A sync that will not end is a sync that has gone wrong.
    private let maxPages = 500

    public init(
        session: ServerSession,
        store: any SyncStore,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.session = session
        self.store = store
        self.now = now
    }

    public func load() async {
        if let book = await store.loadBook() { self.book = book }
        cursor = await store.loadCursor()
    }

    public var trips: [TripSummary] { book.trips }
    public var days: [TripDay] { TripDay.group(book.trips) }

    /// One sync: pull every page there is, applying and acknowledging as it goes.
    @discardableResult
    public func sync() async -> Bool {
        guard !isSyncing else { return false }
        guard let client = await session.client() else {
            lastFailure = "the server can't be reached"
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        lastFailure = nil

        var pages = 0
        while pages < maxPages {
            pages += 1
            do {
                let outcome = try await client.pull(cursor: cursor?.value, limit: pageSize)
                switch outcome {
                case .cursorReset:
                    // Not "up to date". The server's data was reset, or this cursor is older
                    // than its retained log, and anything derived from it is now a claim about
                    // a world that no longer exists.
                    resets += 1
                    book.removeAll()
                    cursor = nil
                    continue

                case .page(let page):
                    apply(page)
                    let next = SyncCursor(value: page.cursor, epoch: page.epoch, at: now())
                    // The page and the cursor together, or neither.
                    do {
                        try await store.save(book: book, cursor: next)
                    } catch {
                        lastFailure = "this phone could not save what it pulled"
                        return false
                    }
                    cursor = next
                    // Acknowledged only after the save committed, which is what makes the
                    // server's idea of what this phone holds true rather than hopeful.
                    _ = try? await client.ack(cursor: next.value)
                    if !page.hasMore {
                        lastSyncAt = now()
                        return true
                    }
                }
            } catch let error as CairnServerError {
                lastFailure = Self.describe(error)
                if case .transport = error { session.routeFailed() }
                return false
            } catch {
                lastFailure = "the sync did not finish"
                return false
            }
        }
        lastFailure = "the server kept sending pages"
        return false
    }

    /// Apply one page. Entities supersede by id, tombstones remove, operations are this
    /// phone's own coming back and need nothing done to them.
    ///
    /// Public so a test can hand it a page without a server behind it: the applying is where
    /// the decisions are, and the pulling is URLSession's.
    public func apply(_ page: PullPage) {
        for change in page.changes {
            switch change.type {
            case "entity":
                guard let type = change.entityType, let id = change.entityID, let data = change.data else { continue }
                switch type {
                case "trip_summary":
                    guard let trip = TripSummary(
                        entity: id, vehicleID: change.vehicleID ?? "", data: data,
                        sequence: change.serverSequence
                    ) else { continue }
                    book.apply(trip)
                case "vehicle":
                    guard let vehicle = Vehicle(entity: id, data: data) else { continue }
                    book.apply(vehicle)
                case "assignment":
                    guard let assignment = Assignment(
                        entity: id, vehicleID: change.vehicleID ?? "", data: data
                    ) else { continue }
                    book.apply(assignment)
                default:
                    // An entity type this build does not know. Skipped, not fatal: the log is
                    // shared with a dashboard that knows more kinds than a phone needs.
                    continue
                }

            case "tombstone":
                guard let type = change.entityType, let id = change.entityID else { continue }
                switch type {
                case "trip_summary": book.removeTrip(id)
                case "vehicle": book.removeVehicle(id)
                case "assignment": book.removeAssignment(id)
                default: continue
                }

            case "operation":
                // An append-only operation coming back down the log. This phone pushed it, or
                // another client did; either way there is nothing for a trip list to do with
                // one. The outbox tracks its own by `operation_id`.
                continue

            default:
                continue
            }
        }
    }

    // MARK: - Push

    /// Send one operation and report whether the server took it.
    ///
    /// `trip_annotation` and `odometer_correction` are the two the phone has: a note on a drive
    /// and a correction to the odometer. Both are append-only and idempotent by
    /// `operation_id` — the server's `duplicate` is a success, not a failure, which is what
    /// makes a retry after a lost answer safe.
    @discardableResult
    public func push(_ operation: SyncOperation) async -> PushStatus? {
        guard let client = await session.client() else {
            lastFailure = "the server can't be reached"
            return nil
        }
        do {
            let response = try await client.push([operation])
            return response.results.first { $0.operationID == operation.operationID }?.status
        } catch let error as CairnServerError {
            lastFailure = Self.describe(error)
            if case .transport = error { session.routeFailed() }
            return nil
        } catch {
            lastFailure = "the push did not finish"
            return nil
        }
    }

    private static func describe(_ error: CairnServerError) -> String {
        switch error {
        case .transport(.offline): "no route to the server"
        case .transport(.timedOut): "the server did not answer"
        case .transport(.tls): "this phone does not trust the server's certificate"
        case .unauthenticated, .signatureRequired: "the server did not accept this phone's sign-in"
        case .clockSkew(let ahead): "this phone's clock is \(abs(ahead)) s off the server's"
        case .rateLimited: "the server asked us to slow down"
        default: "the server answered \(error.httpStatus.map(String.init) ?? "with an error")"
        }
    }
}
