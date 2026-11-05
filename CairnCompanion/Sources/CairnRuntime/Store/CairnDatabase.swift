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
        return migrator
    }
}

extension BundleRow: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bundle"
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
