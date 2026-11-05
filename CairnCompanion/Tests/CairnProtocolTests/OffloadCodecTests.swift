import Foundation
import Testing
@testable import CairnProtocol

/// Codec behaviour that does not come from the contracts vectors: framing errors, transfer
/// failure detection and receipt framing. The vector conformance is in OffloadVectorTests.
@Suite("Offload codec")
struct OffloadCodecTests {
    private let bundle = OffloadBundleID(hex: "000102030405060708090a0b0c0d0e0f")!

    @Test func crc32MatchesTheStandardCheckValues() {
        #expect(OffloadCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(OffloadCRC32.checksum(Data("hello".utf8)) == 0x3610_A686)
        #expect(OffloadCRC32.checksum(Data()) == 0)
    }

    @Test func bundleIDHexRoundTripAndLengthChecks() {
        #expect(bundle.hex == "000102030405060708090a0b0c0d0e0f")
        #expect(OffloadBundleID(hex: "00") == nil)
        #expect(OffloadBundleID(hex: String(repeating: "zz", count: 16)) == nil)
        #expect(OffloadBundleID(bytes: Data(count: 15)) == nil)
    }

    @Test func statusAndOutcomeKeepUnknownValues() {
        for raw in UInt8(0)...9 {
            #expect(OffloadStatus(rawValue: raw).rawValue == raw)
            #expect(PutReceiptOutcome(rawValue: raw).rawValue == raw)
        }
        #expect(OffloadStatus(rawValue: 200) == .unknown(200))
        #expect(PutReceiptOutcome.verifiedAndPruned.bundleIsDone)
        #expect(PutReceiptOutcome.verifiedPruneIncomplete.bundleIsDone)
        for outcome in [PutReceiptOutcome.rejectedSignature, .rejectedContentRoot, .noPinnedKey] {
            #expect(!outcome.bundleIsDone)
        }
    }

    @Test func requestEncodingIsLittleEndian() {
        #expect(OffloadRequest.list(requestID: 7, firstIndex: 0x0102).encode() == Data([0x01, 7, 0x02, 0x01]))
        #expect(OffloadRequest.abort(requestID: 9).encode() == Data([0x05, 9]))
        let read = OffloadRequest.read(requestID: 1, bundleID: bundle, offset: 0x0807_0605_0403_0201, length: 0x0403_0201).encode()
        #expect(read.count == 2 + 16 + 8 + 4)
        #expect(Array(read.suffix(12)) == [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4])
    }

    @Test func decodeRejectsMalformedFrames() {
        #expect(throws: OffloadCodecError.truncated(needed: 1, have: 0)) { try OffloadIndication.decode(Data()) }
        // A request opcode (no high bit) is not an indication.
        #expect(throws: OffloadCodecError.unexpectedOpcode(0x03)) { try OffloadIndication.decode(Data([0x03, 1, 0])) }
        #expect(throws: OffloadCodecError.unexpectedOpcode(0x99)) { try OffloadIndication.decode(Data([0x99, 1, 0])) }
        // READ OK needs a u32 length.
        #expect(throws: OffloadCodecError.self) { try OffloadIndication.decode(Data([0x83, 1, 0, 0x10, 0])) }
        // A refusal carries no payload.
        #expect(throws: OffloadCodecError.trailingBytes(1)) { try OffloadIndication.decode(Data([0x83, 1, 3, 0])) }
        // LIST says two entries but carries one.
        var list = Data([0x81, 1, 0, 2, 0, 0, 0, 2])
        list.append(Data(count: OffloadListEntry.size))
        #expect(throws: OffloadCodecError.self) { try OffloadIndication.decode(list) }
        // transfer-done is exactly 11 bytes.
        #expect(throws: OffloadCodecError.self) { try OffloadIndication.decode(Data([0x86, 1, 0, 1, 0, 0, 0])) }
    }

    @Test func dataFrameNeedsASequenceNumber() throws {
        #expect(throws: OffloadCodecError.self) { try OffloadDataFrame(decoding: Data([0x01])) }
        let frame = try OffloadDataFrame(decoding: Data([0x02, 0x01, 0xAA]))
        #expect(frame.sequence == 0x0102)
        #expect(frame.bytes == Data([0xAA]))
        #expect(frame.encode() == Data([0x02, 0x01, 0xAA]))
    }

    // MARK: Transfer checks (offload.md 3.3)

    private func frame(_ seq: UInt16, _ text: String) -> OffloadDataFrame {
        OffloadDataFrame(sequence: seq, bytes: Data(text.utf8))
    }

    @Test func assemblerAcceptsAContiguousTransfer() {
        var a = OffloadTransferAssembler(expectedLength: 5)
        a.accept(frame(0, "hel"))
        a.accept(frame(1, "lo"))
        #expect(a.finish(bytesSent: 5, crc32: 0x3610_A686) == .success(Data("hello".utf8)))
    }

    @Test func assemblerReportsALostNotification() {
        var a = OffloadTransferAssembler(expectedLength: 5)
        a.accept(frame(0, "hel"))
        a.accept(frame(2, "lo"))  // seq 1 was lost
        #expect(a.finish(bytesSent: 5, crc32: 0x3610_A686) == .failure(.sequenceGap(expected: 1, got: 2)))
    }

    @Test func assemblerReportsShortAndWrongLengths() {
        var a = OffloadTransferAssembler(expectedLength: 5)
        a.accept(frame(0, "hel"))
        #expect(a.finish(bytesSent: 5, crc32: 0) == .failure(.lengthMismatch(requested: 5, reportedSent: 5, received: 3)))
        a.accept(frame(1, "lo"))
        #expect(a.finish(bytesSent: 4, crc32: 0) == .failure(.lengthMismatch(requested: 5, reportedSent: 4, received: 5)))
    }

    @Test func assemblerReportsACorruptByte() {
        var a = OffloadTransferAssembler(expectedLength: 5)
        a.accept(frame(0, "hellp"))
        #expect(a.finish(bytesSent: 5, crc32: 0x3610_A686)
                == .failure(.crcMismatch(reported: 0x3610_A686, computed: OffloadCRC32.checksum(Data("hellp".utf8)))))
    }

    @Test func sequenceNumbersWrapAt16Bits() {
        let count = Int(UInt16.max) + 2
        var a = OffloadTransferAssembler(expectedLength: UInt32(count))
        for i in 0..<count { a.accept(OffloadDataFrame(sequence: UInt16(truncatingIfNeeded: i), bytes: Data([0x5A]))) }
        let expected = OffloadCRC32.checksum(Data(repeating: 0x5A, count: count))
        #expect(a.finish(bytesSent: UInt32(count), crc32: expected) == .success(Data(repeating: 0x5A, count: count)))
    }

    // MARK: Receipt framing

    @Test func receiptIsSplitToTheMTUWithContiguousSequence() throws {
        let receipt = Data((0..<100).map { UInt8($0) })
        // MTU 43: message 40, so 38 data bytes per frame.
        let frames = try #require(OffloadReceiptFramer.frames(for: receipt, attMTU: 43))
        #expect(frames.map(\.count) == [40, 40, 26])
        var joined = Data()
        for (i, raw) in frames.enumerated() {
            let f = try OffloadDataFrame(decoding: raw)
            #expect(f.sequence == UInt16(i))
            joined.append(f.bytes)
        }
        #expect(joined == receipt)
    }

    @Test func receiptFramesNeverExceed244Bytes() throws {
        let frames = try #require(OffloadReceiptFramer.frames(for: Data(count: 1000), attMTU: 517))
        #expect(frames.allSatisfy { $0.count <= 244 })
        #expect(frames.dropLast().allSatisfy { $0.count == 244 })
    }

    @Test func noFramesWhenTheMTULeavesNoRoom() {
        #expect(OffloadReceiptFramer.frames(for: Data(count: 10), attMTU: 5) == nil)
    }

    // MARK: Session

    @Test func sessionRefusesResponsesNobodyAskedFor() {
        var session = OffloadSession()
        #expect(throws: OffloadSessionError.unexpectedResponse(requestID: 3)) {
            try session.receiveIndication(Data([0x81, 3, 4]))
        }
        #expect(throws: OffloadSessionError.unexpectedData) {
            try session.receiveNotification(Data([0, 0, 1]))
        }
        _ = session.send(.list(requestID: 3, firstIndex: 0))
        // A READ response to a LIST request.
        #expect(throws: OffloadSessionError.unexpectedResponse(requestID: 3)) {
            try session.receiveIndication(Data([0x83, 3, 4]))
        }
    }

    @Test func requestIDsSkipOnesInUse() {
        var session = OffloadSession()
        _ = session.send(.abort(requestID: 1))
        _ = session.send(.abort(requestID: 2))
        #expect(session.makeRequestID() == 3)
        #expect(session.makeRequestID() == 4)
    }

    @Test func receiptFramesNeedTheReadyIndicationAndTheAnnouncedLength() throws {
        var session = OffloadSession()
        session.updateMTU(247)
        _ = session.send(.putReceipt(requestID: 5, bundleID: bundle, receiptLength: 10))
        #expect(throws: OffloadSessionError.receiptNotReady(requestID: 5)) {
            try session.receiptFrames(requestID: 5, receipt: Data(count: 10))
        }
        #expect(try session.receiveIndication(Data([0x84, 5, 0])) == .receiptReady(requestID: 5))
        #expect(throws: OffloadSessionError.receiptLengthMismatch(requestID: 5, announced: 10, given: 9)) {
            try session.receiptFrames(requestID: 5, receipt: Data(count: 9))
        }
        #expect(try session.receiptFrames(requestID: 5, receipt: Data(count: 10)).count == 1)
    }

    @Test func aTransferSurvivesAndReportsALostNotificationEndToEnd() throws {
        var session = OffloadSession()
        _ = session.send(.read(requestID: 8, bundleID: bundle, offset: 0, length: 5))
        #expect(try session.receiveIndication(Data([0x83, 8, 0, 5, 0, 0, 0]))
                == .transferStarted(requestID: 8, kind: .read, length: 5))
        try session.receiveNotification(frame(0, "hel").encode())
        try session.receiveNotification(frame(2, "lo").encode())
        var done = Data([0x86, 8, 0, 5, 0, 0, 0])
        done.append(contentsOf: [0x86, 0xA6, 0x10, 0x36])
        #expect(try session.receiveIndication(done)
                == .transferFailed(requestID: 8, kind: .read, .sequenceGap(expected: 1, got: 2)))
    }

    @Test func aTransferEndedByTheDongleReportsItsStatus() throws {
        var session = OffloadSession()
        _ = session.send(.read(requestID: 8, bundleID: bundle, offset: 0, length: 5))
        _ = try session.receiveIndication(Data([0x83, 8, 0, 5, 0, 0, 0]))
        // A trip started during the transfer: the done indication carries TRIP_ACTIVE.
        let done = Data([0x86, 8, 4, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(try session.receiveIndication(done) == .transferFailed(requestID: 8, kind: .read, .device(.tripActive)))
    }

    @Test func aReadResponseWithADifferentLengthIsNotTrusted() throws {
        var session = OffloadSession()
        _ = session.send(.read(requestID: 8, bundleID: bundle, offset: 0, length: 5))
        #expect(try session.receiveIndication(Data([0x83, 8, 0, 4, 0, 0, 0]))
                == .transferFailed(requestID: 8, kind: .read, .lengthMismatch(requested: 5, reportedSent: 4, received: 0)))
    }

    @Test func receiptUploadThatFailsEndsWithoutAnOutcome() throws {
        var session = OffloadSession()
        _ = session.send(.putReceipt(requestID: 5, bundleID: bundle, receiptLength: 10))
        _ = try session.receiveIndication(Data([0x84, 5, 0]))
        #expect(try session.receiveIndication(Data([0x84, 5, 7])) == .receiptUploadFailed(requestID: 5, .noTransfer))
    }
}
