import CairnProtocol
import CryptoKit
import Foundation

/// Carries the dongle's finished trips to the server and the server's receipts back, keeping a
/// durable row for each one as it goes.
///
/// `BundleOffloader` already had the conversation right — offer, upload what is missing, commit,
/// hand the receipt back, and every step idempotent so two uplinks racing on one bundle cannot
/// lose or duplicate data. What it had no notion of was *surviving*. This is the same
/// conversation with a row per bundle, written at each stage, and the receipt written **before**
/// the dongle is asked to take it.
///
/// Why that one ordering matters more than the rest: between the server committing and the
/// dongle verifying, the trip exists in two places and is owned by neither. The server has the
/// bytes but will not say so again without being asked; the dongle still has them and will not
/// free the space. A phone that dies in that window and forgets the receipt makes the dongle
/// keep a trip forever and the next run re-upload the whole thing. With the receipt on disk, the
/// next run hands it over and stops.
public actor OffloadRunner {
    private let dongle: OffloadClient
    private let relay: BundleRelayService
    private let store: any BundleStore
    private let machine = OffloadMachine()
    private let now: @Sendable () -> Date
    private let readSize: UInt32

    /// Where the run has got to, for the Dongle screen.
    public private(set) var summary = OffloadSummary()

    public init(
        dongle: OffloadClient,
        relay: BundleRelayService,
        store: any BundleStore,
        readSize: UInt32 = OffloadRequest.maximumReadLength,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dongle = dongle
        self.relay = relay
        self.store = store
        self.readSize = min(readSize, OffloadRequest.maximumReadLength)
        self.now = now
    }

    /// One pass. Returns when there is nothing more to do, something says stop, or the dongle's
    /// standby cap is close enough that leaving politely beats being cut off.
    @discardableResult
    public func run(
        connectedSince: Date? = nil,
        onProgress: @escaping @Sendable (OffloadSummary) -> Void = { _ in }
    ) async -> OffloadSummary {
        let startedAt = connectedSince ?? now()
        summary = OffloadSummary()

        // Anything this phone already holds a receipt for is finished first, before a single new
        // byte goes up: it costs one write and it frees space on the dongle.
        await deliverHeldReceipts(onProgress: onProgress)
        if summary.stopped != nil { return summary }

        let entries: [OffloadListEntry]
        do {
            entries = try await listEverything()
        } catch {
            summary.stopped = Self.stop(for: error)
            onProgress(summary)
            return summary
        }

        let waiting = entries.filter { $0.state == .sealed }
        summary.waiting = waiting.count
        onProgress(summary)
        if waiting.isEmpty {
            summary.stopped = .nothingWaiting
            return summary
        }

        for (position, entry) in waiting.enumerated() {
            if machine.shouldLeave(connectedFor: now().timeIntervalSince(startedAt)) {
                summary.stopped = .sessionCapReached
                onProgress(summary)
                return summary
            }
            summary.uploading = (position + 1, waiting.count)
            onProgress(summary)
            if await carry(entry, onProgress: onProgress) == false { break }
        }
        summary.uploading = nil
        onProgress(summary)
        return summary
    }

    // MARK: - LIST, all of it

    /// The dongle answers at most sixteen entries per `LIST` (`offload.md` §3.1). A drive that
    /// was never offloaded leaves more than that, and a loop that asks once gets sixteen trips
    /// and silently forgets the rest — so ask until a page comes back that adds nothing new.
    private func listEverything() async throws -> [OffloadListEntry] {
        var seen: [String: OffloadListEntry] = [:]
        var rounds = 0
        while rounds < 64 {
            rounds += 1
            let page = try await dongle.list()
            var newSealed = false
            for entry in page {
                let id = entry.bundleID.hex
                if seen[id] == nil {
                    seen[id] = entry
                    if entry.state == .sealed { newSealed = true }
                }
            }
            guard machine.needsAnotherList(received: page.count, newSealedSeen: newSealed) else { break }
        }
        return Array(seen.values).sorted { $0.bundleID.hex < $1.bundleID.hex }
    }

    // MARK: - Resuming

    /// Rows that already hold a receipt: hand it over and stop. Nothing is re-uploaded.
    private func deliverHeldReceipts(onProgress: @escaping @Sendable (OffloadSummary) -> Void) async {
        let rows = (try? await store.allRows()) ?? []
        for row in rows where row.stage == .receiptHeld {
            guard let receipt = row.receipt, let id = OffloadBundleID(hex: row.bundleID) else { continue }
            if await deliver(receipt, to: id, row: row) == false { return }
            summary.delivered += 1
            summary.lastReceiptAt = now()
            onProgress(summary)
        }
    }

    // MARK: - One bundle

    /// Returns false when the run should stop.
    private func carry(
        _ entry: OffloadListEntry, onProgress: @escaping @Sendable (OffloadSummary) -> Void
    ) async -> Bool {
        let id = entry.bundleID.hex
        var row = (try? await store.row(id)) ?? BundleRow(bundleID: id, firstSeenAt: now(), updatedAt: now())
        if case .stopped = machine.next(for: row) { return true }   // refused earlier; leave it
        if row.isFinished { return true }

        // Resume straight at the handback when the receipt is already here.
        if case .deliverReceipt(let receipt) = machine.next(for: row) {
            guard await deliver(receipt, to: entry.bundleID, row: row) else { return false }
            summary.delivered += 1
            summary.lastReceiptAt = now()
            onProgress(summary)
            return true
        }

        do {
            let blob = try await dongle.manifest(entry.bundleID)
            let manifestLength = Int(entry.manifestLength)
            guard blob.count == manifestLength + 64 else {
                try await mark(&row, stop: "manifest_length")
                return true
            }
            let manifest = Data(blob.prefix(manifestLength))
            let signature = blob.suffix(64).hexString
            row.stage = .manifest
            try await write(&row)

            let provider = DongleChunkProvider(dongle: dongle, bundleID: entry.bundleID, readSize: readSize)
            let counter = ByteCounter()
            row.stage = .offered
            try await write(&row)

            let result = try await relay.relay(
                manifest: manifest, signature: signature, chunkProvider: provider,
                useBearer: true, verifyChunkDigests: true,
                onChunk: { done, total, bytes in counter.add(bytes, done: done, total: total) }
            )
            row.stage = .committed
            row.chunksDone = counter.done
            row.chunksTotal = counter.total
            row.bytesUploaded = counter.value
            summary.bytesUploaded += counter.value
            try await write(&row)

            guard let receipt = result.receipt else {
                try await mark(&row, stop: "no_receipt")
                return true
            }

            // Before `PUT_RECEIPT`, always. See the type comment: this one line is the
            // difference between a crash costing a write and a crash costing a whole upload.
            row.receipt = receipt.bytes
            row.stage = .receiptHeld
            try await write(&row)

            guard await deliver(receipt.bytes, to: entry.bundleID, row: row) else { return false }
            summary.delivered += 1
            summary.lastReceiptAt = now()
            onProgress(summary)
            return true

        } catch let error as CairnServerError {
            switch machine.interpret(error) {
            case .stopBundle(let code):
                try? await mark(&row, stop: code)
                return true
            case .stopRun(let reason):
                summary.stopped = reason
                return false
            case .commitOutstandingFirst:
                // Not a failure. The server is holding as many part-uploaded bundles for this
                // phone as it allows; the next run starts by finishing them, which is exactly
                // what `deliverHeldReceipts` and the resume path do.
                summary.stopped = .tooManyOffers
                return false
            case .backOff:
                summary.stopped = .serverUnavailable("the server asked us to slow down")
                return false
            }
        } catch let mismatch as BundleRelayService.ChunkDigestMismatch {
            // The bytes the dongle gave us are not the bytes its own manifest says they are.
            // That is the dongle's card, not the link, and re-reading will not change it.
            try? await mark(&row, stop: "corrupt_chunk_\(mismatch.index)")
            return true
        } catch {
            summary.stopped = Self.stop(for: error)
            return false
        }
    }

    /// Hand the receipt to the dongle and record what it made of it. Returns false to stop.
    private func deliver(_ receipt: Data, to id: OffloadBundleID, row: BundleRow) async -> Bool {
        var row = row
        do {
            let outcome = try await dongle.putReceipt(id, receipt: receipt)
            row.receiptOutcome = Int(outcome.rawValue)
            switch machine.interpret(receipt: outcome) {
            case .delivered:
                row.stage = .delivered
                try await write(&row)
                return true
            case .stopRun(let reason):
                row.stopCode = reason.code
                row.lastErrorAt = now()
                try await write(&row)
                summary.stopped = reason
                return false
            }
        } catch {
            summary.stopped = Self.stop(for: error)
            return false
        }
    }

    // MARK: - The row

    private func write(_ row: inout BundleRow) async throws {
        row.updatedAt = now()
        try await store.save(row)
    }

    private func mark(_ row: inout BundleRow, stop code: String) async throws {
        row.stopCode = code
        row.lastErrorAt = now()
        try await write(&row)
    }

    private static func stop(for error: Error) -> OffloadStopReason {
        switch error {
        case OffloadClientError.refused(_, .tripActive): .tripActive
        case OffloadClientError.refused(_, .busy): .dongleBusy
        case OffloadClientError.disconnected: .linkLost("the dongle disconnected")
        case OffloadClientError.timedOut(let op): .linkLost("the dongle stopped answering \(op)")
        case OffloadClientError.mtuTooSmall(let mtu): .linkLost("the link's MTU of \(mtu) is too small for offload")
        default: .linkLost("\(error)")
        }
    }
}

/// Chunk progress from the relay's callback, which runs off this actor.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var chunksDone = 0
    private var chunksTotal = 0

    func add(_ n: Int64, done: Int, total: Int) {
        lock.withLock {
            bytes += n
            chunksDone = done
            chunksTotal = total
        }
    }

    var value: Int64 { lock.withLock { bytes } }
    var done: Int { lock.withLock { chunksDone } }
    var total: Int { lock.withLock { chunksTotal } }
}
