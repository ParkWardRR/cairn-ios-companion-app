import CairnProtocol
import Foundation

/// How far one bundle has got, and the order it gets there in.
///
/// The stages are the plan's R3:
/// `listed → manifest → offered → chunking(n of m) → committed → receiptHeld → delivered`.
///
/// The one that earns its place is `receiptHeld`. The server's receipt is written to the row
/// **before** `PUT_RECEIPT` is attempted, so a phone that dies between the commit and the
/// handback resumes at the handback rather than re-uploading a bundle the server already has
/// and the dongle is still holding space for.
public enum BundleStage: String, Codable, Sendable, CaseIterable, Comparable {
    /// The dongle listed it as sealed and waiting.
    case listed
    /// Its manifest and signature have been read off the dongle.
    case manifest
    /// The server has been offered the manifest and said what it is missing.
    case offered
    /// Chunks are going up.
    case chunking
    /// The server has every chunk and has committed.
    case committed
    /// The receipt is on this phone, in the row, and the dongle has not had it yet.
    case receiptHeld
    /// The dongle has the receipt and has said what it made of it. Done.
    case delivered

    private var order: Int { BundleStage.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: BundleStage, b: BundleStage) -> Bool { a.order < b.order }

    public var title: String {
        switch self {
        case .listed: "waiting"
        case .manifest: "reading"
        case .offered: "offered"
        case .chunking: "uploading"
        case .committed: "committed"
        case .receiptHeld: "returning the receipt"
        case .delivered: "done"
        }
    }
}

/// One bundle's durable row.
///
/// Durable because the phone is a car-mounted device that gets unplugged, and because the only
/// thing standing between a trip and oblivion is the dongle refusing to free space until it has
/// a receipt. A row that is lost means an upload redone; a receipt that is lost means a trip the
/// dongle keeps forever.
public struct BundleRow: Codable, Equatable, Sendable, Identifiable {
    public var bundleID: String
    public var stage: BundleStage
    public var chunksDone: Int
    public var chunksTotal: Int
    public var bytesUploaded: Int64
    /// The server's signed receipt, written before `PUT_RECEIPT` is attempted.
    public var receipt: Data?
    /// What the dongle made of the receipt, once it has had it.
    public var receiptOutcome: Int?
    /// Why this bundle stopped, when it did. A stop is shown and not retried.
    public var stopCode: String?
    public var lastErrorAt: Date?
    public var firstSeenAt: Date
    public var updatedAt: Date

    public var id: String { bundleID }

    public init(
        bundleID: String, stage: BundleStage = .listed,
        chunksDone: Int = 0, chunksTotal: Int = 0, bytesUploaded: Int64 = 0,
        receipt: Data? = nil, receiptOutcome: Int? = nil,
        stopCode: String? = nil, lastErrorAt: Date? = nil,
        firstSeenAt: Date, updatedAt: Date
    ) {
        self.bundleID = bundleID
        self.stage = stage
        self.chunksDone = chunksDone
        self.chunksTotal = chunksTotal
        self.bytesUploaded = bytesUploaded
        self.receipt = receipt
        self.receiptOutcome = receiptOutcome
        self.stopCode = stopCode
        self.lastErrorAt = lastErrorAt
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }

    public var isFinished: Bool { stage == .delivered }
    public var isStopped: Bool { stopCode != nil }
    /// Work is owed on this bundle: it is neither done nor refused.
    public var isPending: Bool { !isFinished && !isStopped }
}

/// Where the rows live. A protocol so `OffloadMachine` is tested against memory and the app runs
/// it against GRDB, which is the only dependency the rewrite keeps (D7).
public protocol BundleStore: Sendable {
    func row(_ bundleID: String) async throws -> BundleRow?
    func allRows() async throws -> [BundleRow]
    func save(_ row: BundleRow) async throws
    func delete(_ bundleID: String) async throws
    /// Rows for bundles the dongle no longer lists: delivered, pruned, gone. Keeping them
    /// forever would turn a diagnostics screen into an archive.
    func deleteFinished(before: Date) async throws
}

/// Why a run stopped, in words that can go on a screen.
///
/// Every one of these is named in the plan, and the distinction between them is the point: a
/// `TRIP_ACTIVE` is not a problem, a `429 too_many_offers` is a sequencing instruction, and a
/// refused receipt is a thing to stop and tell somebody about.
public enum OffloadStopReason: Equatable, Sendable {
    /// The dongle is recording. It serves nothing during a drive, and that is correct.
    case tripActive
    /// The dongle said BUSY. Try again shortly.
    case dongleBusy
    /// Nothing sealed is waiting.
    case nothingWaiting
    /// The link went away mid-run.
    case linkLost(String)
    /// The server could not be reached, or would not take this phone's sign-in.
    case serverUnavailable(String)
    /// `429 too_many_offers`: commit what is outstanding, then offer again.
    case tooManyOffers
    /// `507 quota_exceeded`: the device is out of allowance on the server.
    case quotaExceeded
    /// A `403` or `422` about this client or this bundle. Stop and show it.
    case refused(String)
    /// The dongle would not accept the server's receipt. Never retried blindly: the server's key
    /// and the dongle's pinned key disagree, or the bundle is not the one receipted.
    case receiptRejected(Int)
    /// This firmware pins no receipt key, so the dongle cannot free space whatever happens.
    case dongleHasNoReceiptKey
    /// Fourteen minutes gone of the dongle's fifteen-minute standby cap. Leave politely.
    case sessionCapReached

    /// What the Dongle screen says.
    public var sentence: String {
        switch self {
        case .tripActive:
            "The dongle is recording. Trips are carried over after the drive."
        case .dongleBusy:
            "The dongle was busy. Trying again shortly."
        case .nothingWaiting:
            "The dongle has no finished trips waiting."
        case .linkLost(let why):
            "The link ended (\(why)). Nothing was lost; it carries on next time."
        case .serverUnavailable(let why):
            "Nothing was lost, but \(why). The dongle keeps everything until the server confirms it."
        case .tooManyOffers:
            "The server is already holding as many part-uploaded trips as it allows for this "
                + "phone. Finishing those first, then carrying on."
        case .quotaExceeded:
            "The server is out of storage allowance for this dongle. Nothing more can be carried "
                + "until space is freed there."
        case .refused(let code):
            "The server refused a trip (\(code)). It stays on the dongle."
        case .receiptRejected:
            "The dongle refused the server's receipt, so it kept the trip. The server's key and "
                + "the dongle's pinned key disagree: reflash the dongle with the server's receipt key."
        case .dongleHasNoReceiptKey:
            "This dongle has no receipt key built in, so it cannot free space after an upload. "
                + "Your trips are safe on the server; flash a build that pins the server's key."
        case .sessionCapReached:
            "The dongle holds standby for fifteen minutes at a time while a phone is working. "
                + "Leaving politely and carrying on at the next connection."
        }
    }

    /// Whether the person has to do something. A `tripActive` does not; a refused receipt does.
    public var needsAttention: Bool {
        switch self {
        case .tripActive, .dongleBusy, .nothingWaiting, .linkLost, .tooManyOffers, .sessionCapReached:
            false
        case .serverUnavailable, .quotaExceeded, .refused, .receiptRejected, .dongleHasNoReceiptKey:
            true
        }
    }

    /// Whether another run, soon, is worth trying. Everything that is not a refusal is.
    public var isRetryable: Bool {
        switch self {
        case .quotaExceeded, .refused, .receiptRejected, .dongleHasNoReceiptKey: false
        default: true
        }
    }

    public var code: String {
        switch self {
        case .tripActive: "trip_active"
        case .dongleBusy: "busy"
        case .nothingWaiting: "nothing_waiting"
        case .linkLost: "link_lost"
        case .serverUnavailable: "server_unavailable"
        case .tooManyOffers: "too_many_offers"
        case .quotaExceeded: "quota_exceeded"
        case .refused(let code): code
        case .receiptRejected(let outcome): "receipt_rejected_\(outcome)"
        case .dongleHasNoReceiptKey: "no_receipt_key"
        case .sessionCapReached: "session_cap"
        }
    }
}

/// The decisions a run makes, with no I/O anywhere in them.
///
/// `OffloadRunner` does the talking. Everything that could be got wrong — what to do next with a
/// row, what a named error means, when to leave the dongle alone — is here, where a test can ask
/// it directly.
public struct OffloadMachine: Sendable {
    /// The dongle holds standby for at most fifteen minutes while a phone is working
    /// (`offload.md` §4). Leaving at fourteen is the difference between going politely and
    /// being cut off mid-chunk.
    public static let sessionCap: TimeInterval = 15 * 60
    public static let leaveAt: TimeInterval = 14 * 60
    /// `BUSY` means "not now", so ask again shortly rather than giving up on the run.
    public static let busyRetry: TimeInterval = 2
    /// The dongle lists at most sixteen entries per `LIST` (`offload.md` §3.1), so a `LIST`
    /// that comes back full is a `LIST` that may have more behind it.
    public static let listPageSize = 16

    public init() {}

    /// What to do with a row that already exists, given what the dongle now says about it.
    ///
    /// This is where a crash is recovered from. A row at `receiptHeld` has the server's receipt
    /// on this phone and the dongle still waiting for it: the only correct next step is to hand
    /// it over, and re-uploading would be wasted radio on a trip the server already holds.
    public enum Next: Equatable, Sendable {
        case readManifest
        case offerToServer
        case uploadChunks
        case commit
        /// Resume: the receipt is in the row.
        case deliverReceipt(Data)
        /// Nothing to do.
        case done
        /// Stopped earlier, and not by something another attempt would fix.
        case stopped(String)
    }

    public func next(for row: BundleRow) -> Next {
        if let stopCode = row.stopCode { return .stopped(stopCode) }
        switch row.stage {
        case .listed: return .readManifest
        case .manifest: return .offerToServer
        case .offered: return .uploadChunks
        case .chunking: return row.chunksDone >= row.chunksTotal ? .commit : .uploadChunks
        case .committed, .receiptHeld:
            // Both resume at the handback. A row at `committed` with no receipt bytes has to
            // fetch them again, which the runner does; one at `receiptHeld` has them.
            guard let receipt = row.receipt else { return .commit }
            return .deliverReceipt(receipt)
        case .delivered: return .done
        }
    }

    /// Whether to start a run at all.
    public func shouldRun(linkReady: Bool, tripActive: Bool, enrolled: Bool) -> Bool {
        linkReady && !tripActive && enrolled
    }

    /// Whether to leave the dongle alone now, given how long this connection has been working.
    public func shouldLeave(connectedFor elapsed: TimeInterval) -> Bool {
        elapsed >= Self.leaveAt
    }

    /// What a server error means for the run. The names are the plan's, one for one.
    public func interpret(_ error: CairnServerError) -> ServerVerdict {
        switch error {
        case .tooManyOffers:
            // Not a failure: a sequencing instruction. The bundles already offered have to be
            // finished before any more are offered, and backing off as though the server were
            // overloaded would make a full queue take a drive longer to clear.
            return .commitOutstandingFirst
        case .quotaExceeded:
            return .stopRun(.quotaExceeded)
        case .quarantined:
            return .stopBundle("quarantined")
        case .forbidden(let reason):
            // `scope`, `assignment_refused` and `no_storage_key` are the three the plan names,
            // and every other 403 behaves the same way: stop, show the code, change nothing.
            // Retrying a refusal is how a phone comes to spend a drive asking the same
            // question.
            return .stopRun(.refused(reason.code))
        case .badManifestSignature:
            return .stopBundle("bad_manifest_signature")
        case .conflict(let code), .badRequest(let code), .notFound(let code):
            return .stopBundle(code)
        case .rateLimited(let after):
            return .backOff(after ?? 30)
        case .serverFailure, .transport, .malformedResponse:
            return .stopRun(.serverUnavailable("the server can't be reached"))
        case .unauthenticated, .signatureRequired, .clockSkew, .signingFailed:
            return .stopRun(.serverUnavailable("the server did not accept this phone's sign-in"))
        case .cursorReset, .invalidArgument, .unexpected:
            return .stopRun(.serverUnavailable("the server answered in a way this build does not know"))
        }
    }

    public enum ServerVerdict: Equatable, Sendable {
        /// This bundle is refused; the others may still go.
        case stopBundle(String)
        /// The whole run stops.
        case stopRun(OffloadStopReason)
        /// Finish what is outstanding, then offer again.
        case commitOutstandingFirst
        case backOff(TimeInterval)
    }

    /// What the dongle made of the receipt (`offload.md` §3.4 `PUT_RECEIPT` outcomes).
    public func interpret(receipt outcome: PutReceiptOutcome) -> ReceiptVerdict {
        switch outcome {
        case .verifiedAndPruned, .verifiedPruneIncomplete:
            return .delivered
        case .noPinnedKey:
            return .stopRun(.dongleHasNoReceiptKey)
        case .rejectedSignature, .rejectedContentRoot, .unknown:
            // Never retried blindly. Either the two sides disagree about the server's key, or
            // the receipt is for a different bundle — and sending it again changes neither.
            return .stopRun(.receiptRejected(Int(outcome.rawValue)))
        }
    }

    public enum ReceiptVerdict: Equatable, Sendable {
        case delivered
        case stopRun(OffloadStopReason)
    }

    /// Whether another `LIST` is worth asking for. The dongle answers at most sixteen entries,
    /// so a full page means there may be more sealed bundles behind it — which is exactly the
    /// case a drive that was never offloaded produces.
    public func needsAnotherList(received: Int, newSealedSeen: Bool) -> Bool {
        received >= Self.listPageSize && newSealedSeen
    }
}

/// What a run did, for the screen and for a bench record.
public struct OffloadSummary: Equatable, Sendable {
    public var delivered: Int = 0
    public var waiting: Int = 0
    public var uploading: (done: Int, total: Int)?
    public var bytesUploaded: Int64 = 0
    public var stopped: OffloadStopReason?
    public var lastReceiptAt: Date?

    public init() {}

    public static func == (a: OffloadSummary, b: OffloadSummary) -> Bool {
        a.delivered == b.delivered && a.waiting == b.waiting
            && a.uploading?.done == b.uploading?.done && a.uploading?.total == b.uploading?.total
            && a.bytesUploaded == b.bytesUploaded && a.stopped == b.stopped
            && a.lastReceiptAt == b.lastReceiptAt
    }

    /// "3 trips waiting on the dongle", "uploading 2 of 5", "all synced" — the sentence the plan
    /// asks the Dongle screen for.
    public var headline: String {
        if let uploading { return "Uploading \(uploading.done) of \(uploading.total)" }
        if waiting > 0 { return waiting == 1 ? "1 trip waiting on the dongle" : "\(waiting) trips waiting on the dongle" }
        if delivered > 0 { return "All synced" }
        return "Nothing waiting"
    }
}
