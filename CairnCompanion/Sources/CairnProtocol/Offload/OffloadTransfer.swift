import Foundation

/// IEEE 802.3 CRC-32 (reflected, polynomial 0xEDB88320), the one the dongle puts in the
/// transfer-done indication.
public enum OffloadCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// Why a data transfer must be re-issued (offload.md section 3.3).
public enum OffloadTransferFailure: Error, Equatable, Sendable {
    /// The dongle ended the transfer with a non-OK status (a trip started, a stall, an I/O error).
    case device(OffloadStatus)
    /// A notification was lost or reordered: `expected` was the next sequence number, `got` arrived.
    case sequenceGap(expected: UInt16, got: UInt16)
    /// The byte count differs from what was asked for, what the dongle reports sending, or what arrived.
    case lengthMismatch(requested: UInt32, reportedSent: UInt32, received: Int)
    case crcMismatch(reported: UInt32, computed: UInt32)
}

/// Reassembles the `OFFLOAD_DATA` notifications of one `GET_MANIFEST` or `READ`.
public struct OffloadTransferAssembler: Sendable {
    public let expectedLength: UInt32
    private var nextSequence: UInt16 = 0
    private var buffer = Data()
    private var gap: (expected: UInt16, got: UInt16)?

    public init(expectedLength: UInt32) {
        self.expectedLength = expectedLength
    }

    public var receivedCount: Int { buffer.count }

    /// Records a notification. A gap is remembered and reported by `finish`, not thrown, because
    /// the dongle's transfer-done indication still follows and is what ends the transfer.
    public mutating func accept(_ frame: OffloadDataFrame) {
        guard gap == nil else { return }
        guard frame.sequence == nextSequence else {
            gap = (nextSequence, frame.sequence)
            return
        }
        buffer.append(frame.bytes)
        nextSequence &+= 1
    }

    /// Checks the transfer-done indication against what arrived: contiguous sequence numbers,
    /// the requested length, and the CRC. Returns the bytes only if every check passes.
    public func finish(bytesSent: UInt32, crc32: UInt32) -> Result<Data, OffloadTransferFailure> {
        if let gap { return .failure(.sequenceGap(expected: gap.expected, got: gap.got)) }
        guard bytesSent == expectedLength, buffer.count == Int(expectedLength) else {
            return .failure(.lengthMismatch(requested: expectedLength, reportedSent: bytesSent, received: buffer.count))
        }
        let computed = OffloadCRC32.checksum(buffer)
        guard computed == crc32 else { return .failure(.crcMismatch(reported: crc32, computed: computed)) }
        return .success(buffer)
    }
}

/// Splits a receipt into `OFFLOAD_DATA` write frames (`u16 seq || bytes`, `seq` from 0).
public enum OffloadReceiptFramer {
    /// Fewer than this and the dongle answers every request `IO_ERROR` (offload.md section 2).
    public static let minimumATTMTU = 43
    public static let maximumMessageLength = 244

    /// A message is sized to the negotiated MTU minus 3, up to 244 bytes.
    public static func maximumMessageLength(forATTMTU mtu: Int) -> Int {
        min(max(mtu - 3, 0), maximumMessageLength)
    }

    /// Returns nil when the MTU leaves no room for data after the 2-byte sequence number.
    public static func frames(for receipt: Data, attMTU: Int) -> [Data]? {
        let room = maximumMessageLength(forATTMTU: attMTU) - 2
        guard room > 0 else { return nil }
        var frames: [Data] = []
        var sequence: UInt16 = 0
        var offset = receipt.startIndex
        repeat {
            let end = receipt.index(offset, offsetBy: room, limitedBy: receipt.endIndex) ?? receipt.endIndex
            frames.append(OffloadDataFrame(sequence: sequence, bytes: receipt[offset..<end]).encode())
            sequence &+= 1
            offset = end
        } while offset < receipt.endIndex
        return frames
    }
}
