import CairnProtocol
import CryptoKit
import Foundation

/// What happened to one bundle in an offload run.
public enum BundleOffloadOutcome: Equatable, Sendable {
    /// The server receipted it, the dongle verified the receipt and pruned (or will at boot).
    case done(PutReceiptOutcome)
    /// The dongle already held a verified receipt for it (prune pending); nothing to do.
    case alreadyReceipted
    /// The server already held a receipt before this phone offered anything, for example because
    /// the dongle uploaded it over Wi-Fi or LTE. The phone only carried the receipt back.
    case receiptCarriedBack(PutReceiptOutcome)
    /// The dongle refused the receipt as forged or for the wrong bundle. The server's key and the
    /// firmware's pinned key disagree, or the bundle is not the one receipted. Never retry blindly.
    case dongleRejectedReceipt(PutReceiptOutcome)
    /// This firmware has no receipt key pinned: the bundle is safe, but the dongle will not free space.
    case dongleHasNoReceiptKey
    /// The server would not take this bundle (bad manifest signature, quarantined, out of scope,
    /// unknown assignment). Retrying the same bundle will not help.
    case serverRefused(code: String)
    /// The bytes the dongle gave us did not match the offer's digest, even after re-reading.
    case corruptOnDongle(chunk: Int)
    case failed(String)
}

public struct BundleOffloadResult: Equatable, Sendable {
    public var bundleID: String
    public var outcome: BundleOffloadOutcome
    public var chunksUploaded: Int
    public var bytes: Int64

    public init(bundleID: String, outcome: BundleOffloadOutcome, chunksUploaded: Int, bytes: Int64) {
        self.bundleID = bundleID
        self.outcome = outcome
        self.chunksUploaded = chunksUploaded
        self.bytes = bytes
    }
}

public enum OffloadStop: Equatable, Sendable {
    /// A trip is in progress, so the dongle serves nothing. Try again after the drive.
    case tripActive
    /// Nothing sealed is waiting.
    case nothingToOffload
    /// The server could not be reached (or the phone is not signed in): the dongle keeps everything.
    case serverUnavailable(String)
    /// The link dropped or timed out.
    case linkLost(String)
    case dongleBusy
}

public struct OffloadReport: Equatable, Sendable {
    public var results: [BundleOffloadResult]
    public var stopped: OffloadStop?

    public init(results: [BundleOffloadResult] = [], stopped: OffloadStop? = nil) {
        self.results = results
        self.stopped = stopped
    }

    public var completed: Int {
        results.filter {
            switch $0.outcome {
            case .done, .alreadyReceipted, .receiptCarriedBack: true
            default: false
            }
        }.count
    }
    public var bytesUploaded: Int64 { results.reduce(0) { $0 + $1.bytes } }
    public var problems: [BundleOffloadResult] {
        results.filter {
            switch $0.outcome {
            case .done, .alreadyReceipted, .receiptCarriedBack: false
            default: true
            }
        }
    }
}

extension OffloadReport {
    /// One plain sentence for the screen, and whether it needs the person's attention.
    public var summary: (text: String, needsAttention: Bool) {
        func trips(_ n: Int) -> String { n == 1 ? "1 trip" : "\(n) trips" }
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

        if results.contains(where: { Self.isRejection($0.outcome) }) {
            return ("The dongle refused the server's receipt, so it kept the trip. The server's key and the dongle's pinned key disagree: reflash the dongle with the server's receipt key.", true)
        }
        if results.contains(where: { $0.outcome == .dongleHasNoReceiptKey }) {
            return ("This dongle has no receipt key built in, so it can't free space after an upload. Your trips are safe on the server; flash a build that pins the server's key.", true)
        }
        switch stopped {
        case .tripActive?:
            return ("The dongle is recording a trip. Trips are carried over after the drive.", false)
        case .dongleBusy?:
            return ("The dongle was busy. Trying again shortly.", false)
        case .serverUnavailable(let why)?:
            return ("Nothing was lost, but \(why). The dongle keeps everything until the server confirms it.", true)
        case .linkLost(let why)?:
            return ("The connection to the dongle ended (\(why)). Nothing was lost; it carries on next time.", false)
        case .nothingToOffload? where completed == 0 && problems.isEmpty:
            return ("The dongle has no finished trips waiting.", false)
        default:
            break
        }
        var parts: [String] = []
        if completed > 0 { parts.append("Carried \(trips(completed))\(bytesUploaded > 0 ? " (\(size(bytesUploaded)))" : "") to the server.") }
        let refused = problems.count
        if refused > 0 { parts.append("\(trips(refused)) could not be carried: it stays on the dongle.") }
        return (parts.isEmpty ? "Done." : parts.joined(separator: " "), refused > 0)
    }

    fileprivate static func isRejection(_ outcome: BundleOffloadOutcome) -> Bool {
        if case .dongleRejectedReceipt = outcome { return true }
        return false
    }
}

public struct OffloadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case listing
        case fetchingManifest
        case uploading(chunk: Int, of: Int)
        case returningReceipt
    }
    public var phase: Phase
    /// 1-based position among the bundles this run will carry.
    public var bundle: Int
    public var bundles: Int
}

/// The phone's loop from offload.md section 4, uplink-agnostic by construction.
///
/// The phone is one way a bundle reaches the server, not the only one: a dongle with Wi-Fi or LTE
/// uploads on its own. The loop does not care. For every sealed bundle it offers the manifest to
/// the server, which answers with what it is missing; a bundle the server already holds comes back
/// as "receipt available, nothing missing", the phone reads no chunk from the dongle, and only
/// carries the receipt back so the dongle can prune. Every step is idempotent, so two uplinks racing
/// on one bundle cannot lose or duplicate data.
public actor BundleOffloader {
    private let dongle: OffloadClient
    private let relay: BundleRelayService
    private let readSize: UInt32

    public init(dongle: OffloadClient, relay: BundleRelayService, readSize: UInt32 = OffloadRequest.maximumReadLength) {
        self.dongle = dongle
        self.relay = relay
        self.readSize = min(readSize, OffloadRequest.maximumReadLength)
    }

    public func run(onProgress: @escaping @Sendable (OffloadProgress) -> Void = { _ in }) async -> OffloadReport {
        var report = OffloadReport()
        onProgress(.init(phase: .listing, bundle: 0, bundles: 0))

        let entries: [OffloadListEntry]
        do {
            entries = try await dongle.list()
        } catch {
            report.stopped = Self.stop(for: error)
            return report
        }
        let waiting = entries.filter { $0.state == .sealed }
        // Entries already holding a verified receipt are the dongle's to finish at boot.
        for entry in entries where entry.state == .receiptVerified {
            report.results.append(.init(bundleID: entry.bundleID.hex, outcome: .alreadyReceipted, chunksUploaded: 0, bytes: 0))
        }
        if waiting.isEmpty {
            report.stopped = .nothingToOffload
            return report
        }

        for (position, entry) in waiting.enumerated() {
            let number = position + 1
            do {
                let result = try await offload(entry, number: number, of: waiting.count, onProgress: onProgress)
                report.results.append(result)
                if result.outcome == .dongleHasNoReceiptKey || Self.isRejection(result.outcome) { break }
            } catch let error as OffloadClientError {
                report.stopped = Self.stop(for: error)
                return report
            } catch let error as CairnServerError {
                if let result = Self.bundleLevel(error, entry) {
                    report.results.append(result)
                    continue
                }
                report.stopped = .serverUnavailable(Self.describe(error))
                return report
            } catch let mismatch as BundleRelayService.ChunkDigestMismatch {
                report.results.append(.init(bundleID: entry.bundleID.hex, outcome: .corruptOnDongle(chunk: mismatch.index), chunksUploaded: 0, bytes: 0))
            } catch {
                report.results.append(.init(bundleID: entry.bundleID.hex, outcome: .failed("\(error)"), chunksUploaded: 0, bytes: 0))
            }
        }
        return report
    }

    // MARK: - One bundle

    private func offload(
        _ entry: OffloadListEntry, number: Int, of count: Int,
        onProgress: @escaping @Sendable (OffloadProgress) -> Void
    ) async throws -> BundleOffloadResult {
        onProgress(.init(phase: .fetchingManifest, bundle: number, bundles: count))
        let blob = try await dongle.manifest(entry.bundleID)
        let manifestLength = Int(entry.manifestLength)
        guard blob.count == manifestLength + 64 else {
            return .init(bundleID: entry.bundleID.hex,
                         outcome: .failed("manifest is \(blob.count) bytes, the dongle listed \(manifestLength) + 64"),
                         chunksUploaded: 0, bytes: 0)
        }
        let manifest = Data(blob.prefix(manifestLength))
        let signature = blob.suffix(64).map { String(format: "%02x", $0) }.joined()

        let provider = DongleChunkProvider(dongle: dongle, bundleID: entry.bundleID, readSize: readSize)
        let counter = ByteCounter()
        let result = try await relay.relay(
            manifest: manifest, signature: signature, chunkProvider: provider, verifyChunkDigests: true,
            onChunk: { done, total, bytes in
                counter.add(bytes)
                onProgress(.init(phase: .uploading(chunk: done, of: total), bundle: number, bundles: count))
            })
        let uploadedBytes = counter.value
        guard let receipt = result.receipt else {
            return .init(bundleID: entry.bundleID.hex, outcome: .failed("the server returned no receipt"),
                         chunksUploaded: result.chunksUploaded, bytes: uploadedBytes)
        }

        onProgress(.init(phase: .returningReceipt, bundle: number, bundles: count))
        let outcome = try await dongle.putReceipt(entry.bundleID, receipt: receipt.bytes)
        let mapped: BundleOffloadOutcome
        switch outcome {
        case .verifiedAndPruned, .verifiedPruneIncomplete:
            mapped = result.chunksUploaded == 0 && result.alreadyCommitted ? .receiptCarriedBack(outcome) : .done(outcome)
        case .noPinnedKey:
            mapped = .dongleHasNoReceiptKey
        case .rejectedSignature, .rejectedContentRoot, .unknown:
            mapped = .dongleRejectedReceipt(outcome)
        }
        return .init(bundleID: entry.bundleID.hex, outcome: mapped, chunksUploaded: result.chunksUploaded, bytes: uploadedBytes)
    }

    // MARK: - Classifying failures

    private static func isRejection(_ outcome: BundleOffloadOutcome) -> Bool {
        if case .dongleRejectedReceipt = outcome { return true }
        return false
    }

    private static func stop(for error: Error) -> OffloadStop {
        switch error {
        case OffloadClientError.refused(_, .tripActive): .tripActive
        case OffloadClientError.refused(_, .busy): .dongleBusy
        case OffloadClientError.disconnected: .linkLost("the dongle disconnected")
        case OffloadClientError.timedOut(let op): .linkLost("the dongle stopped answering \(op)")
        case OffloadClientError.mtuTooSmall(let mtu): .linkLost("the link's MTU of \(mtu) is too small for offload")
        default: .linkLost("\(error)")
        }
    }

    /// Server errors that are about one bundle; anything else is about the server or this phone and
    /// ends the run (the dongle keeps everything it was not receipted for).
    private static func bundleLevel(_ error: CairnServerError, _ entry: OffloadListEntry) -> BundleOffloadResult? {
        let code: String
        switch error {
        case .badManifestSignature: code = "bad_manifest_signature"
        case .quarantined: code = "quarantined"
        case .forbidden(let reason): code = reason.code
        case .conflict(let c), .notFound(let c), .badRequest(let c): code = c
        default: return nil
        }
        return .init(bundleID: entry.bundleID.hex, outcome: .serverRefused(code: code), chunksUploaded: 0, bytes: 0)
    }

    private static func describe(_ error: CairnServerError) -> String {
        switch error {
        case .transport(.offline), .transport(.timedOut): "the server can't be reached"
        case .transport(.tls): "this phone doesn't trust the server's certificate"
        case .unauthenticated, .clockSkew, .signatureRequired: "the server did not accept this phone's sign-in"
        case .rateLimited: "the server asked us to slow down"
        default: "the server answered \(error.httpStatus.map(String.init) ?? "with an error")"
        }
    }
}

/// Reads ranges of one bundle's byte stream from the dongle, up to 64 KiB per READ.
struct DongleChunkProvider: ChunkProvider {
    let dongle: OffloadClient
    let bundleID: OffloadBundleID
    let readSize: UInt32

    func readChunk(offset: Int64, length: Int64) async throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(length))
        var position = UInt64(offset)
        var remaining = UInt64(length)
        while remaining > 0 {
            let want = UInt32(min(UInt64(readSize), remaining))
            let part = try await dongle.read(bundleID, offset: position, length: want)
            guard part.count == Int(want) else { throw OffloadClientError.protocolViolation("short READ") }
            out.append(part)
            position += UInt64(want)
            remaining -= UInt64(want)
        }
        return out
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ n: Int64) { lock.withLock { total += n } }
    var value: Int64 { lock.withLock { total } }
}
