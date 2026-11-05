import Foundation

// BLE bundle offload messages (contracts ble/v1 offload.md, section 3). Pure byte codec:
// no CoreBluetooth, no timers, no I/O. The characteristics these travel on are OFFLOAD_CONTROL
// (0030) and OFFLOAD_DATA (0031); the wiring that writes and receives them is separate.
// All multi-byte fields are little-endian.

public enum OffloadCodecError: Error, Equatable, Sendable {
    case truncated(needed: Int, have: Int)
    case trailingBytes(Int)
    /// The first byte is not a response opcode (`op | 0x80`) this codec knows.
    case unexpectedOpcode(UInt8)
    case invalidBundleIDLength(Int)
}

/// Opcodes. A response carries `op | 0x80`; `transferDone` (0x06) exists only as a response.
public enum OffloadOpcode: UInt8, Sendable {
    case list = 0x01
    case getManifest = 0x02
    case read = 0x03
    case putReceipt = 0x04
    case abort = 0x05
    case transferDone = 0x06
}

public enum OffloadStatus: Equatable, Sendable {
    case ok
    case busy
    case unknownBundle
    case badArgument
    /// A trip is in progress; the phone tries again after the drive.
    case tripActive
    case ioError
    case badReceiptLength
    case noTransfer
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .ok
        case 1: self = .busy
        case 2: self = .unknownBundle
        case 3: self = .badArgument
        case 4: self = .tripActive
        case 5: self = .ioError
        case 6: self = .badReceiptLength
        case 7: self = .noTransfer
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .ok: 0
        case .busy: 1
        case .unknownBundle: 2
        case .badArgument: 3
        case .tripActive: 4
        case .ioError: 5
        case .badReceiptLength: 6
        case .noTransfer: 7
        case .unknown(let raw): raw
        }
    }
}

/// The `outcome` byte of the final `PUT_RECEIPT` indication (offload.md section 3.4).
public enum PutReceiptOutcome: Equatable, Sendable {
    /// Verified and pruned.
    case verifiedAndPruned
    /// Verified and stored, but the delete did not complete; the dongle finishes at boot.
    case verifiedPruneIncomplete
    /// Malformed, or the signature does not verify. Surface it; never retry blindly.
    case rejectedSignature
    /// The receipt names a different content root. Surface it; never retry blindly.
    case rejectedContentRoot
    /// No receipt key is pinned in this firmware; nothing was stored or deleted.
    case noPinnedKey
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .verifiedAndPruned
        case 1: self = .verifiedPruneIncomplete
        case 2: self = .rejectedSignature
        case 3: self = .rejectedContentRoot
        case 4: self = .noPinnedKey
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .verifiedAndPruned: 0
        case .verifiedPruneIncomplete: 1
        case .rejectedSignature: 2
        case .rejectedContentRoot: 3
        case .noPinnedKey: 4
        case .unknown(let raw): raw
        }
    }

    /// The phone may mark the bundle done.
    public var bundleIsDone: Bool {
        switch self {
        case .verifiedAndPruned, .verifiedPruneIncomplete: true
        default: false
        }
    }
}

/// A 16-byte bundle id.
public struct OffloadBundleID: Equatable, Hashable, Sendable {
    public static let size = 16
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.size else { return nil }
        self.bytes = Data(bytes)
    }

    /// 32 hex characters, as the contracts and the server write a bundle id.
    public init?(hex: String) {
        guard hex.count == Self.size * 2 else { return nil }
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self.bytes = out
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// One `LIST` entry (29 bytes).
public struct OffloadListEntry: Equatable, Sendable {
    public static let size = 29

    public enum State: Equatable, Sendable {
        /// Sealed, awaiting a receipt.
        case sealed
        /// Receipt verified, prune pending.
        case receiptVerified
        case unknown(UInt8)
    }

    public let bundleID: OffloadBundleID
    /// Length of the bundle byte stream that `READ` addresses.
    public let streamBytes: UInt64
    public let manifestLength: UInt16
    public let chunkCount: UInt16
    public let state: State
}

public struct OffloadListPage: Equatable, Sendable {
    /// All sealed bundles the dongle holds, not just this page.
    public let total: UInt16
    public let firstIndex: UInt16
    public let entries: [OffloadListEntry]
}

/// A request, phone to device on OFFLOAD_CONTROL: `u8 op || u8 request_id || payload`.
/// Encoding does not validate arguments: the conformance vectors include deliberately bad
/// ones (zero length, over the 64 KiB cap) whose bytes the phone must be able to produce.
public enum OffloadRequest: Equatable, Sendable {
    /// `READ` addresses at most this many bytes of the stream.
    public static let maximumReadLength: UInt32 = 65_536
    /// `PUT_RECEIPT` accepts a receipt of at most this many bytes.
    public static let maximumReceiptLength: UInt16 = 1024

    case list(requestID: UInt8, firstIndex: UInt16)
    case getManifest(requestID: UInt8, bundleID: OffloadBundleID)
    case read(requestID: UInt8, bundleID: OffloadBundleID, offset: UInt64, length: UInt32)
    case putReceipt(requestID: UInt8, bundleID: OffloadBundleID, receiptLength: UInt16)
    case abort(requestID: UInt8)

    public var requestID: UInt8 {
        switch self {
        case .list(let id, _), .getManifest(let id, _), .read(let id, _, _, _),
             .putReceipt(let id, _, _), .abort(let id):
            id
        }
    }

    public var opcode: OffloadOpcode {
        switch self {
        case .list: .list
        case .getManifest: .getManifest
        case .read: .read
        case .putReceipt: .putReceipt
        case .abort: .abort
        }
    }

    public func encode() -> Data {
        var out = Data([opcode.rawValue, requestID])
        switch self {
        case .list(_, let firstIndex):
            out.appendLE(firstIndex)
        case .getManifest(_, let bundleID):
            out.append(bundleID.bytes)
        case .read(_, let bundleID, let offset, let length):
            out.append(bundleID.bytes)
            out.appendLE(offset)
            out.appendLE(length)
        case .putReceipt(_, let bundleID, let receiptLength):
            out.append(bundleID.bytes)
            out.appendLE(receiptLength)
        case .abort:
            break
        }
        return out
    }
}

/// A response or indication, device to phone on OFFLOAD_CONTROL:
/// `u8 (op | 0x80) || u8 request_id || u8 status || payload`.
/// A payload is present only when `status` is `.ok`, and the frame must be exactly the
/// documented length: a longer or shorter frame is a decode error, not a guess.
public enum OffloadIndication: Equatable, Sendable {
    case list(requestID: UInt8, status: OffloadStatus, page: OffloadListPage?)
    /// `totalLength` is `manifest_len + 64` (manifest.cbor then the Ed25519 manifest.sig).
    case getManifest(requestID: UInt8, status: OffloadStatus, totalLength: UInt32?)
    case read(requestID: UInt8, status: OffloadStatus, length: UInt32?)
    /// Sent twice on success: first without an outcome (ready for the receipt frames), then with
    /// one. An upload that fails part way ends with a non-OK status and no outcome.
    case putReceipt(requestID: UInt8, status: OffloadStatus, outcome: PutReceiptOutcome?)
    case abort(requestID: UInt8, status: OffloadStatus)
    /// `0x86`: the end of a `GET_MANIFEST` or `READ` data transfer.
    case transferDone(requestID: UInt8, status: OffloadStatus, bytesSent: UInt32, crc32: UInt32)

    public var requestID: UInt8 {
        switch self {
        case .list(let id, _, _), .getManifest(let id, _, _), .read(let id, _, _),
             .putReceipt(let id, _, _), .abort(let id, _), .transferDone(let id, _, _, _):
            id
        }
    }

    public static func decode(_ data: Data) throws -> OffloadIndication {
        var reader = ByteReader(data)
        let first = try reader.u8()
        guard first & 0x80 != 0, let opcode = OffloadOpcode(rawValue: first & 0x7F) else {
            throw OffloadCodecError.unexpectedOpcode(first)
        }
        let requestID = try reader.u8()
        let status = OffloadStatus(rawValue: try reader.u8())
        let ok = status == .ok

        let result: OffloadIndication
        switch opcode {
        case .list:
            var page: OffloadListPage?
            if ok {
                let total = try reader.u16()
                let firstIndex = try reader.u16()
                let count = Int(try reader.u8())
                var entries: [OffloadListEntry] = []
                for _ in 0..<count { entries.append(try reader.listEntry()) }
                page = OffloadListPage(total: total, firstIndex: firstIndex, entries: entries)
            }
            result = .list(requestID: requestID, status: status, page: page)
        case .getManifest:
            var total: UInt32?
            if ok { total = try reader.u32() }
            result = .getManifest(requestID: requestID, status: status, totalLength: total)
        case .read:
            var length: UInt32?
            if ok { length = try reader.u32() }
            result = .read(requestID: requestID, status: status, length: length)
        case .putReceipt:
            var outcome: PutReceiptOutcome?
            if ok && reader.remaining > 0 { outcome = PutReceiptOutcome(rawValue: try reader.u8()) }
            result = .putReceipt(requestID: requestID, status: status, outcome: outcome)
        case .abort:
            result = .abort(requestID: requestID, status: status)
        case .transferDone:
            let sent = try reader.u32()
            let crc = try reader.u32()
            result = .transferDone(requestID: requestID, status: status, bytesSent: sent, crc32: crc)
        }
        guard reader.remaining == 0 else { throw OffloadCodecError.trailingBytes(reader.remaining) }
        return result
    }
}

/// A frame on OFFLOAD_DATA: `u16 seq || bytes`. Device to phone it carries bundle bytes
/// (notify); phone to device it carries receipt bytes (write without response).
public struct OffloadDataFrame: Equatable, Sendable {
    public let sequence: UInt16
    public let bytes: Data

    public init(sequence: UInt16, bytes: Data) {
        self.sequence = sequence
        self.bytes = Data(bytes)
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        sequence = try reader.u16()
        bytes = reader.rest()
    }

    public func encode() -> Data {
        var out = Data()
        out.appendLE(sequence)
        out.append(bytes)
        return out
    }
}

// MARK: - Reading (writing uses Data.appendLE from PayloadEncoder.swift)

private struct ByteReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - position }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= count else {
            throw OffloadCodecError.truncated(needed: position + count, have: bytes.count)
        }
        defer { position += count }
        return bytes[position..<position + count]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u16() throws -> UInt16 { try le(UInt16.self) }
    mutating func u32() throws -> UInt32 { try le(UInt32.self) }
    mutating func u64() throws -> UInt64 { try le(UInt64.self) }

    mutating func rest() -> Data {
        defer { position = bytes.count }
        return Data(bytes[position...])
    }

    private mutating func le<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let slice = try take(MemoryLayout<T>.size)
        return slice.enumerated().reduce(T(0)) { $0 | (T($1.element) << (8 * $1.offset)) }
    }

    mutating func listEntry() throws -> OffloadListEntry {
        let id = try take(OffloadBundleID.size)
        guard let bundleID = OffloadBundleID(bytes: Data(id)) else {
            throw OffloadCodecError.invalidBundleIDLength(id.count)
        }
        let streamBytes = try u64()
        let manifestLength = try u16()
        let chunkCount = try u16()
        let state: OffloadListEntry.State
        switch try u8() {
        case 0: state = .sealed
        case 1: state = .receiptVerified
        case let other: state = .unknown(other)
        }
        return OffloadListEntry(
            bundleID: bundleID, streamBytes: streamBytes, manifestLength: manifestLength,
            chunkCount: chunkCount, state: state)
    }
}
