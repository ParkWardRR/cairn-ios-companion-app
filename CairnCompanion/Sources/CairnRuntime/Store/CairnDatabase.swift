import CairnKit
import Foundation
import GRDB

/// The one database. GRDB is the only dependency the rewrite keeps (D7), and it keeps it for
/// exactly two things: the offload rows, and later the sync cursor.
///
/// It sits in Application Support rather than Documents because the Files app should not show
/// it — a person deleting "cairn.sqlite" to tidy up would be deleting a receipt a dongle is
/// still waiting for. File protection is `completeUntilFirstUserAuthentication` so a background
/// upload after a reboot can still read it, and it is excluded from backup because a restored
/// copy of these rows would describe a dongle that has moved on.
public final class CairnDatabase: Sendable {
    public let writer: any DatabaseWriter

    public static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Cairn", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cairn.sqlite")
    }

    public init(url: URL? = nil) throws {
        let url = try url ?? Self.defaultURL()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        writer = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(writer)
        try Self.protect(url)
    }

    /// In memory, for tests.
    public init(inMemory: Bool) throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var directory = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("bundles") { db in
            try db.create(table: "bundle") { t in
                t.primaryKey("bundleID", .text)
                t.column("stage", .text).notNull()
                t.column("chunksDone", .integer).notNull().defaults(to: 0)
                t.column("chunksTotal", .integer).notNull().defaults(to: 0)
                t.column("bytesUploaded", .integer).notNull().defaults(to: 0)
                // The server's signed receipt, written before PUT_RECEIPT is attempted. This
                // column is the whole reason the database exists.
                t.column("receipt", .blob)
                t.column("receiptOutcome", .integer)
                t.column("stopCode", .text)
                t.column("lastErrorAt", .datetime)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "bundle_stage", on: "bundle", columns: ["stage"])
        }
        migrator.registerMigration("sync") { db in
            // One row. The book and the cursor are written together, in one statement, because
            // sync/v1 §5 says a page and its cursor land in the same transaction: a cursor
            // saved without its page is a trip nobody will ever pull again.
            try db.create(table: "syncState") { t in
                t.primaryKey("id", .integer)
                t.column("book", .blob).notNull()
                t.column("cursor", .blob).notNull()
            }
        }
        return migrator
    }
}

extension BundleRow: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bundle"
}

/// `SyncStore` over GRDB: the reconciled trips and the cursor, in one row written at once.
public struct GRDBSyncStore: SyncStore {
    private let database: CairnDatabase

    public init(database: CairnDatabase) {
        self.database = database
    }

    private struct Row: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "syncState"
        var id: Int64 = 1
        var book: Data
        var cursor: Data
    }

    public func loadCursor() async -> SyncCursor? { await load()?.1 }
    public func loadBook() async -> TripBook? { await load()?.0 }

    public func save(book: TripBook, cursor: SyncCursor) async throws {
        let payload = Row(
            book: try JSONEncoder().encode(StoredBook(book)),
            cursor: try JSONEncoder().encode(cursor)
        )
        try await database.writer.write { db in try payload.save(db) }
    }

    private func load() async -> (TripBook, SyncCursor)? {
        guard let row = try? await database.writer.read({ db in try Row.fetchOne(db, key: 1) }),
              let stored = try? JSONDecoder().decode(StoredBook.self, from: row.book),
              let cursor = try? JSONDecoder().decode(SyncCursor.self, from: row.cursor)
        else { return nil }
        return (stored.book, cursor)
    }
}

/// `TripBook` keeps its records private so nothing outside it can key on a published id by
/// accident; this is the one thing that is allowed to, because persistence has to.
private struct StoredBook: Codable {
    var trips: [TripSummary]
    var vehicles: [Vehicle]
    var assignments: [Assignment]

    init(_ book: TripBook) {
        trips = book.allRecords
        vehicles = Array(book.vehicles.values)
        assignments = Array(book.assignments.values)
    }

    var book: TripBook {
        var book = TripBook()
        for trip in trips { book.apply(trip) }
        for vehicle in vehicles { book.apply(vehicle) }
        for assignment in assignments { book.apply(assignment) }
        return book
    }
}

/// `BundleStore` over GRDB.
public struct GRDBBundleStore: BundleStore {
    private let database: CairnDatabase

    public init(database: CairnDatabase) {
        self.database = database
    }

    public func row(_ bundleID: String) async throws -> BundleRow? {
        try await database.writer.read { db in try BundleRow.fetchOne(db, key: bundleID) }
    }

    public func allRows() async throws -> [BundleRow] {
        try await database.writer.read { db in
            try BundleRow.order(Column("firstSeenAt").asc).fetchAll(db)
        }
    }

    public func save(_ row: BundleRow) async throws {
        try await database.writer.write { db in try row.save(db) }
    }

    public func delete(_ bundleID: String) async throws {
        _ = try await database.writer.write { db in try BundleRow.deleteOne(db, key: bundleID) }
    }

    public func deleteFinished(before cutoff: Date) async throws {
        _ = try await database.writer.write { db in
            try BundleRow
                .filter(Column("stage") == BundleStage.delivered.rawValue && Column("updatedAt") < cutoff)
                .deleteAll(db)
        }
    }
}
