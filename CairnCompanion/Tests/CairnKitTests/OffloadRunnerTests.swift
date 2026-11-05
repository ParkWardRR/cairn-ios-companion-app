import CairnKit
import CairnProtocol
import Foundation
import Testing

/// The durable half of R3: the row, the resume, and the paging.
///
/// `BundleOffloaderTests` already proves the conversation — offer, upload what is missing,
/// commit, hand the receipt back, every step idempotent. What this proves is that it survives
/// the phone being switched off at the worst possible moment.
@Suite("OffloadRunner: the row survives the phone")
struct OffloadRunnerTests {
    private func makeRunner(
        _ dongle: FakeDongle, _ server: FakeServer, store: InMemoryBundleStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> (OffloadRunner, OffloadClient) {
        let client = OffloadClient(link: dongle, timeout: .seconds(3))
        try await client.start()
        let signer = KeyProviderSigner(provider: SoftwareKeyProvider(), clientID: "00ff")
        let relay = BundleRelayService(client: CairnServerClient(transport: server, signer: signer))
        return (OffloadRunner(dongle: client, relay: relay, store: store, now: now), client)
    }

    @Test("a clean run leaves a delivered row per bundle, in order")
    func cleanRun() async throws {
        let bundles = [FakeBundle(seed: 1, size: 4000), FakeBundle(seed: 2, size: 2500)]
        let dongle = FakeDongle(bundles: bundles)
        let server = FakeServer()
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, server, store: store)

        let summary = await runner.run()
        await client.stop()

        #expect(summary.delivered == 2, "\(summary)")
        #expect(summary.stopped == nil)
        for bundle in bundles {
            let row = try await store.row(bundle.id.hex)
            #expect(row?.stage == .delivered, "\(bundle.id.hex)")
            #expect(row?.receipt == FakeBundle.receipt(for: bundle.id))
        }
        // And the stages were written as they happened, not all at the end.
        let history = await store.history(bundles[0].id.hex)
        #expect(history.contains(.manifest))
        #expect(history.contains(.offered))
        #expect(history.contains(.committed))
        #expect(history.contains(.receiptHeld))
        #expect(history.last == .delivered)
    }

    @Test("the receipt is written to the row before the dongle is ever asked to take it")
    func receiptIsWrittenFirst() async throws {
        // The whole reason `receiptHeld` is a stage. Between the server committing and the
        // dongle verifying, the trip exists in two places and is owned by neither.
        let bundle = FakeBundle(seed: 3, size: 1800)
        let dongle = FakeDongle(bundles: [bundle])
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, FakeServer(), store: store)
        await runner.run()
        await client.stop()

        let history = await store.history(bundle.id.hex)
        guard let held = history.firstIndex(of: .receiptHeld),
              let delivered = history.firstIndex(of: .delivered) else {
            Issue.record("expected both stages, got \(history)"); return
        }
        #expect(held < delivered)
        let saves = await store.saves
        let atHeld = saves.first { $0.bundleID == bundle.id.hex && $0.stage == .receiptHeld }
        #expect(atHeld?.receipt != nil, "the receipt has to be on disk at that moment, not after")
    }

    @Test("a phone that died holding a receipt hands it over and uploads nothing")
    func resumesAtTheHandback() async throws {
        let bundle = FakeBundle(seed: 4, size: 9000)
        let dongle = FakeDongle(bundles: [bundle])
        let server = FakeServer()
        // The state a crash between commit and handback leaves: the server has the bytes, the
        // dongle still has the trip, and the receipt is on this phone.
        let store = InMemoryBundleStore([
            BundleRow(bundleID: bundle.id.hex, stage: .receiptHeld,
                      receipt: FakeBundle.receipt(for: bundle.id),
                      firstSeenAt: Date(), updatedAt: Date())
        ])
        let (runner, client) = try await makeRunner(dongle, server, store: store)
        let summary = await runner.run()
        await client.stop()

        #expect(summary.delivered >= 1)
        #expect(server.puts(bundle.id) == 0, "not one chunk should go up again")
        #expect(dongle.readCount(bundle.id) == 0, "and the dongle should not be read either")
        let row = try await store.row(bundle.id.hex)
        #expect(row?.stage == .delivered)
        #expect(dongle.pruned.contains(bundle.id.hex))
    }

    @Test("a trip in progress stops the run without alarm and leaves the rows alone")
    func tripActive() async throws {
        let bundle = FakeBundle(seed: 5, size: 1200)
        let dongle = FakeDongle(bundles: [bundle])
        dongle.tripActive = true
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, FakeServer(), store: store)
        let summary = await runner.run()
        await client.stop()

        #expect(summary.stopped == .tripActive)
        #expect(summary.stopped?.needsAttention == false)
        #expect(try await store.allRows().isEmpty)
    }

    @Test("a dongle that refuses the receipt stops the run and the row says so")
    func receiptRejectedStopsTheRun() async throws {
        let bundles = [FakeBundle(seed: 6, size: 1000), FakeBundle(seed: 7, size: 1000)]
        let dongle = FakeDongle(bundles: bundles)
        dongle.receiptPolicy = { _, _ in .rejectedSignature }
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, FakeServer(), store: store)
        let summary = await runner.run()
        await client.stop()

        guard case .receiptRejected(let outcome)? = summary.stopped else {
            Issue.record("expected a rejected receipt, got \(String(describing: summary.stopped))"); return
        }
        #expect(outcome == 2)
        #expect(summary.stopped?.isRetryable == false)
        // The first bundle carries the stop; the second was never started, because carrying on
        // would mean uploading a second trip the dongle will also refuse to free.
        let rows = try await store.allRows()
        #expect(rows.count == 1)
        #expect(rows.first?.stopCode == "receipt_rejected_2")
        #expect(rows.first?.receipt != nil, "the receipt stays on the row: it is evidence")
    }

    @Test("a dongle with no pinned receipt key stops, because nothing will free space")
    func noReceiptKey() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 8, size: 900), FakeBundle(seed: 9, size: 900)])
        dongle.receiptPolicy = { _, _ in .noPinnedKey }
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, FakeServer(), store: store)
        let summary = await runner.run()
        await client.stop()
        #expect(summary.stopped == .dongleHasNoReceiptKey)
    }

    @Test("bundles the dongle gave us wrong are refused one at a time, and the rest still go")
    func corruptOneBundle() async throws {
        let good = FakeBundle(seed: 10, size: 1500)
        let bad = FakeBundle(seed: 11, size: 1500)
        let dongle = FakeDongle(bundles: [bad, good])
        dongle.corruptBundles = [bad.id.hex]
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, FakeServer(), store: store)
        let summary = await runner.run()
        await client.stop()

        #expect(summary.delivered == 1, "the good one still goes")
        let badRow = try await store.row(bad.id.hex)
        #expect(badRow?.stopCode?.hasPrefix("corrupt_chunk") == true, "\(String(describing: badRow))")
        #expect(try await store.row(good.id.hex)?.stage == .delivered)
    }

    @Test("a bundle that was refused earlier is not tried again")
    func refusedStaysRefused() async throws {
        let bundle = FakeBundle(seed: 12, size: 1100)
        let dongle = FakeDongle(bundles: [bundle])
        let server = FakeServer()
        let store = InMemoryBundleStore([
            BundleRow(bundleID: bundle.id.hex, stage: .offered, stopCode: "quarantined",
                      firstSeenAt: Date(), updatedAt: Date())
        ])
        let (runner, client) = try await makeRunner(dongle, server, store: store)
        await runner.run()
        await client.stop()
        #expect(server.puts(bundle.id) == 0)
        #expect(try await store.row(bundle.id.hex)?.stopCode == "quarantined")
    }

    @Test("more than one LIST page is read: a dongle answers at most sixteen entries")
    func listsEverything() async throws {
        // A drive that was never offloaded leaves more than sixteen sealed bundles, and a loop
        // that asks once carries sixteen trips and silently forgets the rest.
        let bundles = (0..<20).map { FakeBundle(seed: UInt8(40 + $0), size: 400) }
        let dongle = FakeDongle(bundles: bundles, mtu: 100) // a small MTU means a small page
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, FakeServer(), store: store)
        let summary = await runner.run()
        await client.stop()
        #expect(summary.waiting == 20, "all twenty should be seen, got \(summary.waiting)")
        #expect(summary.delivered == 20, "and all twenty carried")
    }

    @Test("the dongle is left alone once the standby cap is close")
    func leavesBeforeTheCap() async throws {
        let bundles = (0..<4).map { FakeBundle(seed: UInt8(60 + $0), size: 800) }
        let dongle = FakeDongle(bundles: bundles)
        let store = InMemoryBundleStore()
        // A clock that jumps fifteen minutes between bundles: the dongle holds standby for at
        // most fifteen minutes per connection, and being cut off mid-chunk is worse than
        // stopping on purpose.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        nonisolated(unsafe) var tick = 0
        let clock: @Sendable () -> Date = {
            tick += 1
            return start.addingTimeInterval(Double(tick) * 120)
        }
        let (runner, client) = try await makeRunner(dongle, FakeServer(), store: store, now: clock)
        let summary = await runner.run(connectedSince: start)
        await client.stop()

        #expect(summary.stopped == .sessionCapReached, "got \(String(describing: summary.stopped))")
        #expect(summary.stopped?.needsAttention == false)
        #expect(summary.stopped?.isRetryable == true)
    }

    @Test("a bundle the dongle already holds a verified receipt for is left to the dongle")
    func alreadyReceipted() async throws {
        // State 2 in the dongle's LIST: it has a verified receipt and will prune at boot.
        // Nothing for the phone to do, and nothing to upload.
        let bundle = FakeBundle(seed: 13, size: 700, state: 2)
        let dongle = FakeDongle(bundles: [bundle])
        let server = FakeServer()
        let store = InMemoryBundleStore()
        let (runner, client) = try await makeRunner(dongle, server, store: store)
        let summary = await runner.run()
        await client.stop()
        #expect(summary.stopped == .nothingWaiting)
        #expect(server.puts(bundle.id) == 0)
    }
}

@Suite("BundleStore")
struct BundleStoreTests {
    @Test("finished rows are swept and unfinished ones are not")
    func sweep() async throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryBundleStore([
            BundleRow(bundleID: "done", stage: .delivered, firstSeenAt: old, updatedAt: old),
            BundleRow(bundleID: "owed", stage: .offered, firstSeenAt: old, updatedAt: old),
        ])
        try await store.deleteFinished(before: Date())
        #expect(try await store.row("done") == nil)
        #expect(try await store.row("owed") != nil, "a trip still owed is not housekeeping")
    }

    @Test("rows come back oldest first, which is the order they should be carried in")
    func ordering() async throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InMemoryBundleStore([
            BundleRow(bundleID: "b", firstSeenAt: t.addingTimeInterval(10), updatedAt: t),
            BundleRow(bundleID: "a", firstSeenAt: t, updatedAt: t),
        ])
        #expect(try await store.allRows().map(\.bundleID) == ["a", "b"])
    }
}
