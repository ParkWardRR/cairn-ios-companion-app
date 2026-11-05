import CairnKit
@testable import CairnRuntime
import Foundation
import Testing

/// The durable store, against a real SQLite database rather than the in-memory stand-in the
/// machine's tests use. What this checks is the part the protocol cannot: that a row written as
/// one process sees it comes back the same to the next, including the receipt bytes, which are
/// the only thing standing between a trip and a dongle that keeps it forever.
@Suite("GRDBBundleStore")
struct GRDBBundleStoreTests {
    private func store() throws -> GRDBBundleStore {
        GRDBBundleStore(database: try CairnDatabase(inMemory: true))
    }

    @Test("a row round-trips with its receipt intact")
    func roundTrip() async throws {
        let store = try store()
        let receipt = Data((0..<300).map { UInt8($0 % 251) })
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.save(BundleRow(
            bundleID: "426b17997550788e79a0db2193101846", stage: .receiptHeld,
            chunksDone: 4, chunksTotal: 4, bytesUploaded: 123_456,
            receipt: receipt, firstSeenAt: t, updatedAt: t
        ))

        let back = try await store.row("426b17997550788e79a0db2193101846")
        #expect(back?.stage == .receiptHeld)
        #expect(back?.receipt == receipt, "the receipt has to survive exactly; it is a signature")
        #expect(back?.chunksDone == 4)
        #expect(back?.bytesUploaded == 123_456)
    }

    @Test("saving the same bundle twice updates it rather than failing")
    func upsert() async throws {
        let store = try store()
        let t = Date()
        var row = BundleRow(bundleID: "aa", stage: .listed, firstSeenAt: t, updatedAt: t)
        try await store.save(row)
        row.stage = .delivered
        try await store.save(row)
        #expect(try await store.allRows().count == 1)
        #expect(try await store.row("aa")?.stage == .delivered)
    }

    @Test("rows come back oldest first, which is the order to carry them in")
    func ordering() async throws {
        let store = try store()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.save(BundleRow(bundleID: "second", firstSeenAt: t.addingTimeInterval(60), updatedAt: t))
        try await store.save(BundleRow(bundleID: "first", firstSeenAt: t, updatedAt: t))
        #expect(try await store.allRows().map(\.bundleID) == ["first", "second"])
    }

    @Test("the sweep takes finished rows and leaves anything still owed")
    func sweep() async throws {
        let store = try store()
        let old = Date(timeIntervalSince1970: 1_000_000)
        try await store.save(BundleRow(bundleID: "done", stage: .delivered, firstSeenAt: old, updatedAt: old))
        try await store.save(BundleRow(bundleID: "owed", stage: .chunking, firstSeenAt: old, updatedAt: old))
        try await store.save(BundleRow(bundleID: "held", stage: .receiptHeld, receipt: Data([1]),
                                       firstSeenAt: old, updatedAt: old))
        try await store.deleteFinished(before: Date())
        #expect(try await store.allRows().map(\.bundleID).sorted() == ["held", "owed"],
                "a receipt not yet handed over is never housekeeping")
    }

    @Test("deleting a row that is not there is not an error")
    func deleteMissing() async throws {
        let store = try store()
        try await store.delete("nothing")
    }

    @Test("every stage survives the round trip")
    func allStages() async throws {
        let store = try store()
        let t = Date()
        for stage in BundleStage.allCases {
            try await store.save(BundleRow(bundleID: stage.rawValue, stage: stage, firstSeenAt: t, updatedAt: t))
        }
        for stage in BundleStage.allCases {
            #expect(try await store.row(stage.rawValue)?.stage == stage, "\(stage)")
        }
    }
}
