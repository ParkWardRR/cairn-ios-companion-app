import CairnKit
import CairnProtocol
import CryptoKit
import Foundation
import Testing

// The fakes this suite runs against are in OffloadFakes.swift.


@Suite struct BundleOffloaderTests {
    @Test func aDongleThatNeverAnswersTimesOutInsteadOfHanging() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 100)])
        dongle.silent = true
        let client = OffloadClient(link: dongle, timeout: .milliseconds(150))
        try await client.start()
        let relay = BundleRelayService(client: CairnServerClient(transport: FakeServer(), signer: KeyProviderSigner(provider: SoftwareKeyProvider(), clientID: "00ff")))
        let report = await BundleOffloader(dongle: client, relay: relay).run()
        await client.stop()
        guard case .linkLost(let why)? = report.stopped else { Issue.record("stopped: \(String(describing: report.stopped))"); return }
        #expect(why.contains("stopped answering"))
    }

    @Test func theSummaryIsPlainAndSaysWhenToWorry() {
        let ok = BundleOffloadResult(bundleID: "a", outcome: .done(.verifiedAndPruned), chunksUploaded: 2, bytes: 2_000_000)
        var report = OffloadReport(results: [ok, ok])
        #expect(report.summary.text.hasPrefix("Carried 2 trips"))
        #expect(!report.summary.needsAttention)

        report.stopped = .tripActive
        #expect(report.summary.text.contains("recording a trip"))
        #expect(!report.summary.needsAttention)

        let rejected = OffloadReport(results: [.init(bundleID: "a", outcome: .dongleRejectedReceipt(.rejectedSignature), chunksUploaded: 1, bytes: 1)])
        #expect(rejected.summary.needsAttention)
        #expect(rejected.summary.text.contains("reflash"))

        let down = OffloadReport(stopped: .serverUnavailable("the server can't be reached"))
        #expect(down.summary.needsAttention)
        #expect(down.summary.text.contains("Nothing was lost"))

        #expect(OffloadReport(stopped: .nothingToOffload).summary.text.contains("no finished trips"))
    }

    @Test func carriesEveryBundleToTheServerAndTheReceiptsBack() async throws {
        let a = FakeBundle(seed: 1, size: 5000), b = FakeBundle(seed: 2, size: 70_000, chunkSize: 66_000)
        let dongle = FakeDongle(bundles: [a, b]), server = FakeServer()

        let report = try await run(dongle, server)

        #expect(report.stopped == nil)
        #expect(report.results.map(\.outcome) == [.done(.verifiedAndPruned), .done(.verifiedAndPruned)])
        #expect(report.completed == 2)
        // The server holds exactly the bytes that were on the dongle, and the dongle pruned both.
        #expect(server.data(for: a.id) == a.stream)
        #expect(server.data(for: b.id) == b.stream)
        #expect(Set(dongle.pruned) == [a.id.hex, b.id.hex])
        // A 66,000-byte chunk is more than one READ (64 KiB cap): the phone stitched two.
        #expect(dongle.readCount(b.id) >= 2)
        #expect(report.bytesUploaded == Int64(a.stream.count + b.stream.count))
    }

    @Test func aBundleAnotherUplinkAlreadyDeliveredCostsNoRadioTime() async throws {
        // The dongle has Wi-Fi/LTE: it uploaded bundle A itself. The phone must read nothing from it
        // and only carry the server's receipt back so the dongle can prune.
        let a = FakeBundle(seed: 1, size: 5000), b = FakeBundle(seed: 2, size: 3000)
        let dongle = FakeDongle(bundles: [a, b]), server = FakeServer()
        server.alreadyHolds(a)

        let report = try await run(dongle, server)

        #expect(report.results.map(\.outcome) == [.receiptCarriedBack(.verifiedAndPruned), .done(.verifiedAndPruned)])
        #expect(dongle.readCount(a.id) == 0)
        #expect(server.puts(a.id) == 0)
        #expect(Set(dongle.pruned) == [a.id.hex, b.id.hex])
    }

    @Test func nothingHappensWhileATripIsInProgress() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 100)]), server = FakeServer()
        dongle.tripActive = true
        let report = try await run(dongle, server)
        #expect(report.stopped == .tripActive)
        #expect(report.results.isEmpty)
        #expect(dongle.pruned.isEmpty)
    }

    @Test func anEmptyDongleIsNotAnError() async throws {
        let report = try await run(FakeDongle(bundles: []), FakeServer())
        #expect(report.stopped == .nothingToOffload)
    }

    @Test func aBundleWithAVerifiedReceiptIsLeftForTheDongleToPrune() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 100, state: 1)])
        let report = try await run(dongle, FakeServer())
        #expect(report.results.map(\.outcome) == [.alreadyReceipted])
        #expect(report.stopped == .nothingToOffload)
    }

    @Test func aLostNotificationIsReReadNotUploaded() async throws {
        let a = FakeBundle(seed: 1, size: 3000, chunkSize: 3000)
        let dongle = FakeDongle(bundles: [a]), server = FakeServer()
        dongle.dropNextNotification = true   // the dongle's CRC and length will not match what arrived

        let report = try await run(dongle, server)

        #expect(report.results.map(\.outcome) == [.done(.verifiedAndPruned)])
        #expect(server.data(for: a.id) == a.stream)
    }

    @Test func bytesThatDoNotMatchTheOffersDigestAreNeverUploaded() async throws {
        // The CRC passes (the dongle computed it over what it sent) but the bytes are wrong.
        let bad = FakeBundle(seed: 1, size: 3000), good = FakeBundle(seed: 2, size: 1000)
        let dongle = FakeDongle(bundles: [bad, good]), server = FakeServer()
        dongle.corruptBundles = [bad.id.hex]

        let report = try await run(dongle, server)

        #expect(report.results[0].outcome == .corruptOnDongle(chunk: 0))
        #expect(server.puts(bad.id) == 0)
        #expect(!dongle.pruned.contains(bad.id.hex))
        // One bad bundle does not block the next.
        #expect(report.results[1].outcome == .done(.verifiedAndPruned))
    }

    @Test func aForgedOrMismatchedReceiptStopsTheRunAndIsSurfaced() async throws {
        let a = FakeBundle(seed: 1, size: 100), b = FakeBundle(seed: 2, size: 100)
        let dongle = FakeDongle(bundles: [a, b]), server = FakeServer()
        dongle.receiptPolicy = { _, _ in .rejectedContentRoot }

        let report = try await run(dongle, server)

        #expect(report.results.map(\.outcome) == [.dongleRejectedReceipt(.rejectedContentRoot)])
        #expect(dongle.pruned.isEmpty)
        #expect(server.puts(b.id) == 0, "the second bundle must not be touched after a rejection")
    }

    @Test func aFirmwareWithoutAPinnedKeyIsReportedAndNothingIsDeleted() async throws {
        let a = FakeBundle(seed: 1, size: 100)
        let dongle = FakeDongle(bundles: [a])
        dongle.receiptPolicy = { _, _ in .noPinnedKey }
        let report = try await run(dongle, FakeServer())
        #expect(report.results.map(\.outcome) == [.dongleHasNoReceiptKey])
        #expect(dongle.pruned.isEmpty)
    }

    @Test func anUnreachableServerStopsTheRunAndLosesNothing() async throws {
        let a = FakeBundle(seed: 1, size: 100)
        let dongle = FakeDongle(bundles: [a]), server = FakeServer()
        server.offline = true
        let report = try await run(dongle, server)
        guard case .serverUnavailable? = report.stopped else { Issue.record("stopped: \(String(describing: report.stopped))"); return }
        #expect(dongle.pruned.isEmpty)
    }

    @Test func aBundleTheServerRefusesDoesNotBlockTheNextOne() async throws {
        let a = FakeBundle(seed: 1, size: 100), b = FakeBundle(seed: 2, size: 100)
        let dongle = FakeDongle(bundles: [a, b]), server = FakeServer()
        server.refuse[a.id.hex] = (401, "{\"error\":\"bad_manifest_signature\"}")

        let report = try await run(dongle, server)

        #expect(report.results.map(\.outcome) == [.serverRefused(code: "bad_manifest_signature"), .done(.verifiedAndPruned)])
        #expect(dongle.pruned == [b.id.hex])
    }

    @Test func manyBundlesAreListedAcrossPages() async throws {
        let many = (0..<20).map { FakeBundle(seed: UInt8($0 + 1), size: 40) }
        let dongle = FakeDongle(bundles: many)
        let report = try await run(dongle, FakeServer())
        #expect(report.completed == 20)
        #expect(dongle.pruned.count == 20)
    }

    @Test func aLinkThatDropsMidTransferEndsTheRunWithoutDeletingAnything() async throws {
        let a = FakeBundle(seed: 1, size: 20_000, chunkSize: 20_000)
        let dongle = FakeDongle(bundles: [a])
        dongle.vanishAfterNotifications = 10
        let report = try await run(dongle, FakeServer())
        guard case .linkLost? = report.stopped else { Issue.record("stopped: \(String(describing: report.stopped))"); return }
        #expect(dongle.pruned.isEmpty)
    }

    @Test func aLinkBelowTheMinimumMTURefusesToStart() async throws {
        let client = OffloadClient(link: FakeDongle(bundles: [], mtu: 23))
        await #expect(throws: OffloadClientError.mtuTooSmall(23)) { try await client.start() }
    }

    @Test func progressNamesEachStepForTheScreen() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 3000, chunkSize: 1000)])
        let seen = ProgressLog()
        _ = try await run(dongle, FakeServer(), onProgress: { seen.add($0) })
        let phases = seen.all.map(\.phase)
        #expect(phases.first == .listing)
        #expect(phases.contains(.fetchingManifest))
        #expect(phases.contains(.uploading(chunk: 3, of: 3)))
        #expect(phases.last == .returningReceipt)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OffloadProgress] = []
    func add(_ p: OffloadProgress) { lock.withLock { items.append(p) } }
    var all: [OffloadProgress] { lock.withLock { items } }
}
