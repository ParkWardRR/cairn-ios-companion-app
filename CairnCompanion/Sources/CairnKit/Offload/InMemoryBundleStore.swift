import Foundation

/// A `BundleStore` in memory, for tests and for previews.
///
/// The real one is GRDB, in `CairnRuntime`. The point of the protocol is that every rule about
/// what a row means — including the one that matters, that a receipt is written before the
/// dongle is asked to take it — is tested here, where a crash can be simulated by simply not
/// calling the next method.
public actor InMemoryBundleStore: BundleStore {
    private var rows: [String: BundleRow] = [:]
    /// Every save, in order. A test can assert that the receipt was written before the handback
    /// was attempted, which is the whole reason the stage exists.
    public private(set) var saves: [BundleRow] = []

    public init(_ initial: [BundleRow] = []) {
        for row in initial { rows[row.bundleID] = row }
    }

    public func row(_ bundleID: String) async throws -> BundleRow? { rows[bundleID] }

    public func allRows() async throws -> [BundleRow] {
        rows.values.sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    public func save(_ row: BundleRow) async throws {
        rows[row.bundleID] = row
        saves.append(row)
    }

    public func delete(_ bundleID: String) async throws { rows[bundleID] = nil }

    public func deleteFinished(before cutoff: Date) async throws {
        for (id, row) in rows where row.isFinished && row.updatedAt < cutoff { rows[id] = nil }
    }

    /// The stages a bundle passed through, in the order they were written.
    public func history(_ bundleID: String) -> [BundleStage] {
        saves.filter { $0.bundleID == bundleID }.map(\.stage)
    }
}
