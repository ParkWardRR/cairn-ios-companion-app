import Foundation

public enum OffloadTransferKind: Equatable, Sendable {
    case manifest
    case read
}

/// What an indication meant, once matched to the request it answers.
public enum OffloadEvent: Equatable, Sendable {
    case listPage(requestID: UInt8, OffloadListPage)
    /// A `GET_MANIFEST` or `READ` was accepted; `length` bytes will arrive as notifications.
    case transferStarted(requestID: UInt8, kind: OffloadTransferKind, length: UInt32)
    /// The transfer finished and passed the sequence, length and CRC checks.
    case transferComplete(requestID: UInt8, kind: OffloadTransferKind, data: Data)
    /// The transfer must be re-issued.
    case transferFailed(requestID: UInt8, kind: OffloadTransferKind, OffloadTransferFailure)
    /// `PUT_RECEIPT` accepted the announced length: write the frames from `receiptFrames`.
    case receiptReady(requestID: UInt8)
    case receiptOutcome(requestID: UInt8, PutReceiptOutcome)
    /// The receipt upload ended without an outcome (frame out of sequence, stall, trip started).
    /// Nothing was stored or deleted; start again.
    case receiptUploadFailed(requestID: UInt8, OffloadStatus)
    case aborted(requestID: UInt8)
    /// The dongle refused the request itself: `BUSY`, `TRIP_ACTIVE`, `UNKNOWN_BUNDLE`, ...
    case refused(requestID: UInt8, OffloadOpcode, OffloadStatus)
}

public enum OffloadSessionError: Error, Equatable, Sendable {
    /// An indication or notification for which no request is waiting.
    case unexpectedResponse(requestID: UInt8)
    case unexpectedData
    /// An indication whose shape does not fit the request it answers (e.g. `LIST` OK without a page).
    case malformedResponse(requestID: UInt8)
    case noRoomForReceiptFrames(attMTU: Int)
    case receiptNotReady(requestID: UInt8)
    case receiptLengthMismatch(requestID: UInt8, announced: Int, given: Int)
}

/// Client-side state for one offload link: matches indications to the requests that caused them,
/// reassembles data transfers and sequences a receipt upload. Value type, no I/O: the caller
/// writes the bytes `send` returns and feeds back what the characteristics deliver.
///
/// The dongle serves one operation at a time. The session does not forbid a second request while
/// one is outstanding, because provoking `BUSY` is part of the conformance vectors; whether to
/// send one is the caller's policy.
public struct OffloadSession: Sendable {
    private enum Pending: Sendable {
        case list
        case manifest
        case read(length: UInt32)
        case putReceipt(announced: Int, stage: ReceiptStage)
        case abort
    }
    private enum ReceiptStage: Sendable { case awaitingReady, ready, uploading }

    public private(set) var attMTU: Int = 23
    private var pending: [UInt8: Pending] = [:]
    private var transfers: [UInt8: OffloadTransferAssembler] = [:]
    private var nextID: UInt8 = 1

    public init() {}

    /// The dongle answers every request `IO_ERROR` below this MTU: negotiate before the first request.
    public var canOffload: Bool { attMTU >= OffloadReceiptFramer.minimumATTMTU }

    public mutating func updateMTU(_ mtu: Int) { attMTU = mtu }

    /// A request id not in use by an outstanding request.
    public mutating func makeRequestID() -> UInt8 {
        while pending[nextID] != nil { nextID &+= 1 }
        defer { nextID &+= 1 }
        return nextID
    }

    /// Registers the request and returns the bytes to write to OFFLOAD_CONTROL (with response).
    public mutating func send(_ request: OffloadRequest) -> Data {
        switch request {
        case .list: pending[request.requestID] = .list
        case .getManifest: pending[request.requestID] = .manifest
        case .read(_, _, _, let length): pending[request.requestID] = .read(length: length)
        case .putReceipt(_, _, let length):
            pending[request.requestID] = .putReceipt(announced: Int(length), stage: .awaitingReady)
        case .abort: pending[request.requestID] = .abort
        }
        return request.encode()
    }

    /// The frames to write (without response) to OFFLOAD_DATA, once `receiptReady` arrived.
    public mutating func receiptFrames(requestID: UInt8, receipt: Data) throws -> [Data] {
        guard case .putReceipt(let announced, .ready)? = pending[requestID] else {
            throw OffloadSessionError.receiptNotReady(requestID: requestID)
        }
        guard receipt.count == announced else {
            throw OffloadSessionError.receiptLengthMismatch(requestID: requestID, announced: announced, given: receipt.count)
        }
        guard let frames = OffloadReceiptFramer.frames(for: receipt, attMTU: attMTU) else {
            throw OffloadSessionError.noRoomForReceiptFrames(attMTU: attMTU)
        }
        pending[requestID] = .putReceipt(announced: announced, stage: .uploading)
        return frames
    }

    /// A notification on OFFLOAD_DATA: bundle bytes for the transfer in progress.
    public mutating func receiveNotification(_ data: Data) throws {
        let frame = try OffloadDataFrame(decoding: data)
        guard let id = transfers.keys.first else { throw OffloadSessionError.unexpectedData }
        transfers[id]?.accept(frame)
    }

    /// An indication on OFFLOAD_CONTROL.
    public mutating func receiveIndication(_ data: Data) throws -> OffloadEvent {
        let indication = try OffloadIndication.decode(data)
        let id = indication.requestID
        guard let waiting = pending[id] else { throw OffloadSessionError.unexpectedResponse(requestID: id) }

        switch (indication, waiting) {
        case (.list(_, let status, let page), .list):
            pending[id] = nil
            if status != .ok { return .refused(requestID: id, .list, status) }
            guard let page else { throw OffloadSessionError.malformedResponse(requestID: id) }
            return .listPage(requestID: id, page)

        case (.getManifest(_, let status, let total), .manifest):
            guard status == .ok else { pending[id] = nil; return .refused(requestID: id, .getManifest, status) }
            guard let total else { throw OffloadSessionError.malformedResponse(requestID: id) }
            transfers[id] = OffloadTransferAssembler(expectedLength: total)
            return .transferStarted(requestID: id, kind: .manifest, length: total)

        case (.read(_, let status, let length), .read(let requested)):
            guard status == .ok else { pending[id] = nil; return .refused(requestID: id, .read, status) }
            guard let length else { throw OffloadSessionError.malformedResponse(requestID: id) }
            guard length == requested else {
                pending[id] = nil
                return .transferFailed(
                    requestID: id, kind: .read,
                    .lengthMismatch(requested: requested, reportedSent: length, received: 0))
            }
            transfers[id] = OffloadTransferAssembler(expectedLength: length)
            return .transferStarted(requestID: id, kind: .read, length: length)

        case (.transferDone(_, let status, let sent, let crc), .manifest), (.transferDone(_, let status, let sent, let crc), .read):
            let kind: OffloadTransferKind = { if case .manifest = waiting { return .manifest } else { return .read } }()
            guard let assembler = transfers[id] else { throw OffloadSessionError.unexpectedResponse(requestID: id) }
            pending[id] = nil
            transfers[id] = nil
            guard status == .ok else { return .transferFailed(requestID: id, kind: kind, .device(status)) }
            switch assembler.finish(bytesSent: sent, crc32: crc) {
            case .success(let bytes): return .transferComplete(requestID: id, kind: kind, data: bytes)
            case .failure(let failure): return .transferFailed(requestID: id, kind: kind, failure)
            }

        case (.putReceipt(_, let status, let outcome), .putReceipt(let announced, let stage)):
            switch stage {
            case .awaitingReady:
                guard outcome == nil else { throw OffloadSessionError.malformedResponse(requestID: id) }
                if status == .ok {
                    pending[id] = .putReceipt(announced: announced, stage: .ready)
                    return .receiptReady(requestID: id)
                }
                pending[id] = nil
                return .refused(requestID: id, .putReceipt, status)
            case .ready, .uploading:
                pending[id] = nil
                if let outcome { return .receiptOutcome(requestID: id, outcome) }
                guard status != .ok else { throw OffloadSessionError.malformedResponse(requestID: id) }
                return .receiptUploadFailed(requestID: id, status)
            }

        case (.abort(_, let status), .abort):
            pending[id] = nil
            if status != .ok { return .refused(requestID: id, .abort, status) }
            // ABORT ends whatever transfer was running; its done indication never comes.
            for transferID in transfers.keys { pending[transferID] = nil }
            transfers.removeAll()
            return .aborted(requestID: id)

        default:
            throw OffloadSessionError.unexpectedResponse(requestID: id)
        }
    }
}
