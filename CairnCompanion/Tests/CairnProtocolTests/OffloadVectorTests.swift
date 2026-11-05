import Foundation
import Testing
@testable import CairnProtocol

// The BLE offload vectors at the pinned contracts release (contracts.lock): ble/v1/vectors/offload.
// Each scenario is replayed through a fake transport, not a radio. The phone side (OffloadSession)
// must produce exactly the control and data bytes the vector records, and must parse every
// indication and notification the dongle produced. Issue #14 (codec only; no CoreBluetooth).

// MARK: - Vector file

private struct OffloadVectors: Decodable {
    struct Bundle: Decodable {
        let bundle_id: String
        let stream_bytes: UInt64
        let manifest_len: UInt16
        let chunk_count: UInt16
        let stream_first_64_bytes_hex: String
        let genuine_receipt_hex: String
        let wrong_key_receipt_hex: String
    }
    struct Event: Decodable {
        let t: String
        let hex: String
    }
    struct Scenario: Decodable {
        let name: String
        let events: [Event]
    }
    let att_mtu: Int
    let bundle: Bundle
    let scenarios: [Scenario]
}

// MARK: - Fake transport

/// Stands in for the GATT link. It holds the dongle's recorded side of one scenario: the phone's
/// writes are checked against what the vector says the phone writes, and the dongle's indications
/// and notifications are handed back in the recorded order.
private final class FakeTransport {
    let events: [OffloadVectors.Event]
    private(set) var cursor = 0
    let scenario: String

    init(scenario: OffloadVectors.Scenario) {
        self.scenario = scenario.name
        self.events = scenario.events
    }

    var isFinished: Bool { cursor >= events.count }
    var nextIsPhoneWrite: Bool { !isFinished && (events[cursor].t == "control_write" || events[cursor].t == "data_write") }
    var nextIsMTU: Bool { !isFinished && events[cursor].t == "mtu" }

    func nextMTU() -> Int {
        let bytes = Data(hex: events[cursor].hex)
        cursor += 1
        return Int(bytes[0]) | Int(bytes[1]) << 8
    }

    func write(_ kind: String, _ data: Data) {
        guard !isFinished, events[cursor].t == kind else {
            Issue.record("\(scenario): phone wrote \(kind) where the vector has \(isFinished ? "nothing" : events[cursor].t)")
            return
        }
        #expect(data == Data(hex: events[cursor].hex), "\(scenario): \(kind) bytes at event \(cursor)")
        cursor += 1
    }

    /// The dongle's output up to the phone's next write.
    func deviceOutput() -> [OffloadVectors.Event] {
        var out: [OffloadVectors.Event] = []
        while !isFinished, events[cursor].t == "indication" || events[cursor].t == "notification" {
            out.append(events[cursor])
            cursor += 1
        }
        return out
    }
}

private enum PhoneAction {
    case send(OffloadRequest)
    /// The correctly sequenced receipt frames, via the session.
    case receipt(requestID: UInt8, Data)
    /// A frame written without going through the session: the vectors record a bad sequence number.
    case rawFrame(sequence: UInt16, Data)
}

private struct Replay {
    var events: [OffloadEvent] = []
    var session = OffloadSession()
    var notifications: [Data] = []
}

private func play(_ scenario: OffloadVectors.Scenario, actions: [PhoneAction]) throws -> Replay {
    let transport = FakeTransport(scenario: scenario)
    var replay = Replay()
    var remaining = actions[...]

    func runWrites() throws {
        while transport.nextIsPhoneWrite {
            guard let action = remaining.popFirst() else {
                Issue.record("\(scenario.name): the vector has a phone write that no action produces")
                return
            }
            switch action {
            case .send(let request):
                transport.write("control_write", replay.session.send(request))
            case .receipt(let id, let receipt):
                for frame in try replay.session.receiptFrames(requestID: id, receipt: receipt) {
                    transport.write("data_write", frame)
                }
            case .rawFrame(let sequence, let bytes):
                transport.write("data_write", OffloadDataFrame(sequence: sequence, bytes: bytes).encode())
            }
        }
    }

    while !transport.isFinished {
        if transport.nextIsMTU { replay.session.updateMTU(transport.nextMTU()); continue }
        if transport.nextIsPhoneWrite { try runWrites(); continue }
        for event in transport.deviceOutput() {
            let bytes = Data(hex: event.hex)
            if event.t == "indication" {
                replay.events.append(try replay.session.receiveIndication(bytes))
            } else {
                // Notifications also round-trip through the frame codec byte for byte.
                #expect(try OffloadDataFrame(decoding: bytes).encode() == bytes)
                replay.notifications.append(bytes)
                try replay.session.receiveNotification(bytes)
            }
        }
    }
    #expect(remaining.isEmpty, "\(scenario.name): \(remaining.count) phone actions were never written")
    return replay
}

/// The bytes the dongle sent as notifications, sequence numbers stripped.
private func notificationBytes(_ replay: Replay) -> Data {
    replay.notifications.reduce(into: Data()) { $0.append($1.dropFirst(2)) }
}

// MARK: - The vectors

@Suite("BLE offload vectors (#14)")
struct OffloadVectorTests {
    private func load() throws -> OffloadVectors {
        try JSONDecoder().decode(OffloadVectors.self, from: Contracts.data("ble/v1/vectors/offload/vectors.json"))
    }

    @Test func everyScenarioReplaysThroughTheFakeTransport() throws {
        let vectors = try load()
        #expect(vectors.att_mtu == 247)
        let bundle = OffloadBundleID(hex: vectors.bundle.bundle_id)!
        let other = OffloadBundleID(hex: "426b17997550788e79a0db2193101813")!
        let genuine = Data(hex: vectors.bundle.genuine_receipt_hex)
        let wrongKey = Data(hex: vectors.bundle.wrong_key_receipt_hex)
        #expect(genuine.count == 192)

        var covered = Set<String>()
        for scenario in vectors.scenarios {
            covered.insert(scenario.name)
            switch scenario.name {
            case "list":
                let r = try play(scenario, actions: [.send(.list(requestID: 1, firstIndex: 0))])
                let entry = OffloadListEntry(
                    bundleID: bundle, streamBytes: vectors.bundle.stream_bytes,
                    manifestLength: vectors.bundle.manifest_len, chunkCount: vectors.bundle.chunk_count, state: .sealed)
                #expect(r.events == [.listPage(requestID: 1, OffloadListPage(total: 1, firstIndex: 0, entries: [entry]))])

            case "get_manifest":
                let r = try play(scenario, actions: [.send(.getManifest(requestID: 2, bundleID: bundle))])
                // manifest.cbor then the 64-byte Ed25519 manifest.sig.
                let total = UInt32(vectors.bundle.manifest_len) + 64
                #expect(r.events == [
                    .transferStarted(requestID: 2, kind: .manifest, length: total),
                    .transferComplete(requestID: 2, kind: .manifest, data: notificationBytes(r)),
                ])
                #expect(notificationBytes(r).count == Int(total))

            case "read_across_member_boundary":
                let r = try play(scenario, actions: [.send(.read(requestID: 3, bundleID: bundle, offset: 430, length: 100))])
                #expect(r.events == [
                    .transferStarted(requestID: 3, kind: .read, length: 100),
                    .transferComplete(requestID: 3, kind: .read, data: notificationBytes(r)),
                ])
                #expect(notificationBytes(r).count == 100)

            case "read_first_bytes":
                let r = try play(scenario, actions: [.send(.read(requestID: 4, bundleID: bundle, offset: 0, length: 40))])
                // Independent of the notifications: the bundle's own record of its first bytes.
                let first = Data(hex: vectors.bundle.stream_first_64_bytes_hex).prefix(40)
                #expect(r.events == [
                    .transferStarted(requestID: 4, kind: .read, length: 40),
                    .transferComplete(requestID: 4, kind: .read, data: Data(first)),
                ])

            case "read_bad_arguments":
                let reads: [(UInt8, UInt64, UInt32)] = [
                    (5, vectors.bundle.stream_bytes, 1),       // offset at the end
                    (6, 0, 0),                                  // zero length
                    (7, 0, OffloadRequest.maximumReadLength + 1), // over the 64 KiB cap
                    (8, vectors.bundle.stream_bytes - 1, 2),   // past the end
                    (9, UInt64.max - 5, 100),                   // would wrap
                ]
                let r = try play(scenario, actions: reads.map { .send(.read(requestID: $0.0, bundleID: bundle, offset: $0.1, length: $0.2)) })
                #expect(r.events == reads.map { .refused(requestID: $0.0, .read, .badArgument) })

            case "unknown_bundle":
                let r = try play(scenario, actions: [
                    .send(.getManifest(requestID: 0x0a, bundleID: other)),
                    .send(.read(requestID: 0x0b, bundleID: other, offset: 0, length: 10)),
                    .send(.putReceipt(requestID: 0x0c, bundleID: other, receiptLength: 100)),
                ])
                #expect(r.events == [
                    .refused(requestID: 0x0a, .getManifest, .unknownBundle),
                    .refused(requestID: 0x0b, .read, .unknownBundle),
                    .refused(requestID: 0x0c, .putReceipt, .unknownBundle),
                ])

            case "busy_then_abort":
                let r = try play(scenario, actions: [
                    .send(.read(requestID: 0x0d, bundleID: bundle, offset: 0, length: 6690)),
                    .send(.list(requestID: 0x0e, firstIndex: 0)),
                    .send(.abort(requestID: 0x0f)),
                ])
                #expect(r.events == [
                    .transferStarted(requestID: 0x0d, kind: .read, length: 6690),
                    .refused(requestID: 0x0e, .list, .busy),
                    .aborted(requestID: 0x0f),
                ])
                #expect(r.notifications.count == 16)

            case "abort_when_idle":
                let r = try play(scenario, actions: [.send(.abort(requestID: 0x10))])
                #expect(r.events == [.refused(requestID: 0x10, .abort, .noTransfer)])

            case "trip_active":
                let r = try play(scenario, actions: [
                    .send(.list(requestID: 0x11, firstIndex: 0)),
                    .send(.getManifest(requestID: 0x12, bundleID: bundle)),
                    .send(.read(requestID: 0x13, bundleID: bundle, offset: 0, length: 10)),
                    .send(.putReceipt(requestID: 0x14, bundleID: bundle, receiptLength: 100)),
                    .send(.abort(requestID: 0x15)),
                ])
                #expect(r.events == [
                    .refused(requestID: 0x11, .list, .tripActive),
                    .refused(requestID: 0x12, .getManifest, .tripActive),
                    .refused(requestID: 0x13, .read, .tripActive),
                    .refused(requestID: 0x14, .putReceipt, .tripActive),
                    .refused(requestID: 0x15, .abort, .noTransfer),
                ])

            case "mtu_too_small":
                let r = try play(scenario, actions: [.send(.list(requestID: 0x16, firstIndex: 0))])
                #expect(r.events == [.refused(requestID: 0x16, .list, .ioError)])
                // The vector ends at ATT MTU 23: the session knows offload is not usable there.
                #expect(r.session.attMTU == 23)
                #expect(!r.session.canOffload)

            case "put_receipt_genuine":
                let r = try play(scenario, actions: [
                    .send(.putReceipt(requestID: 0x17, bundleID: bundle, receiptLength: UInt16(genuine.count))),
                    .receipt(requestID: 0x17, genuine),
                ])
                #expect(r.events == [.receiptReady(requestID: 0x17), .receiptOutcome(requestID: 0x17, .verifiedAndPruned)])
                if case .receiptOutcome(_, let outcome) = r.events.last { #expect(outcome.bundleIsDone) }

            case "put_receipt_wrong_key":
                let r = try play(scenario, actions: [
                    .send(.putReceipt(requestID: 0x18, bundleID: bundle, receiptLength: UInt16(wrongKey.count))),
                    .receipt(requestID: 0x18, wrongKey),
                ])
                #expect(r.events == [.receiptReady(requestID: 0x18), .receiptOutcome(requestID: 0x18, .rejectedSignature)])

            case "put_receipt_no_pinned_key":
                let r = try play(scenario, actions: [
                    .send(.putReceipt(requestID: 0x19, bundleID: bundle, receiptLength: UInt16(genuine.count))),
                    .receipt(requestID: 0x19, genuine),
                ])
                #expect(r.events == [.receiptReady(requestID: 0x19), .receiptOutcome(requestID: 0x19, .noPinnedKey)])

            case "put_receipt_bad_length":
                let r = try play(scenario, actions: [
                    .send(.putReceipt(requestID: 0x1a, bundleID: bundle, receiptLength: 0)),
                    .send(.putReceipt(requestID: 0x1b, bundleID: bundle, receiptLength: OffloadRequest.maximumReceiptLength + 1)),
                ])
                #expect(r.events == [
                    .refused(requestID: 0x1a, .putReceipt, .badReceiptLength),
                    .refused(requestID: 0x1b, .putReceipt, .badReceiptLength),
                ])

            case "put_receipt_out_of_order":
                let r = try play(scenario, actions: [
                    .send(.putReceipt(requestID: 0x1c, bundleID: bundle, receiptLength: UInt16(genuine.count))),
                    .rawFrame(sequence: 1, Data(genuine.prefix(50))),  // the vector sends the first 50 bytes, seq 1 instead of 0
                ])
                #expect(r.events == [.receiptReady(requestID: 0x1c), .receiptUploadFailed(requestID: 0x1c, .badArgument)])

            default:
                Issue.record("""
                    No expectation for scenario '\(scenario.name)' in the pinned offload vectors. \
                    The pin was bumped to a release with a new scenario: add it here.
                    """)
            }
        }
        #expect(covered.count == vectors.scenarios.count)
        #expect(!covered.isEmpty)
    }

    @Test func receiptFramesEqualTheRecordedDataWritesAtTheVectorMTU() throws {
        let vectors = try load()
        let genuine = Data(hex: vectors.bundle.genuine_receipt_hex)
        let recorded = vectors.scenarios.first { $0.name == "put_receipt_genuine" }?.events.first { $0.t == "data_write" }
        let frames = try #require(OffloadReceiptFramer.frames(for: genuine, attMTU: vectors.att_mtu))
        #expect(frames == [Data(hex: try #require(recorded).hex)])
    }
}
