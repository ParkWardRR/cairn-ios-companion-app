import CairnKit
import CairnProtocol
import CryptoKit
import Foundation
import Testing

// MARK: - Mock transport

private final class SequenceTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [HTTPResponse]
    private var index = 0
    var requestLog: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestLog.append(request)
        guard index < responses.count else {
            return HTTPResponse(status: 500, body: Data())
        }
        let resp = responses[index]
        index += 1
        return resp
    }
}

// MARK: - Mock chunk provider

private final class MockChunkProvider: ChunkProvider, @unchecked Sendable {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func readChunk(offset: Int64, length: Int64) async throws -> Data {
        let start = Int(offset)
        let end = min(start + Int(length), data.count)
        guard start < data.count else { return Data() }
        return data[start..<end]
    }
}

// MARK: - Response helpers

private func exchangeResponse(_ step: [String: Any]) -> HTTPResponse {
    let resp = step["response"] as! [String: Any]
    let status = resp["status"] as! Int
    let headers = resp["headers"] as? [String: String] ?? [:]
    var body = Data()
    if let bodyJSON = resp["body_json"] {
        body = try! JSONSerialization.data(withJSONObject: bodyJSON)
    } else if let bodyHex = resp["body_hex"] as? String, !bodyHex.isEmpty {
        body = Data(hex: bodyHex)
    }
    return HTTPResponse(status: status, headers: headers, body: body)
}

// MARK: - Basic relay tests

@Suite struct BundleRelayBasicTests {
    @Test func relayUploadAllChunksAndCommit() async throws {
        let offerBody: [String: Any] = [
            "bundle_id": "test-bundle",
            "missing_chunks": [
                ["index": 0, "offset": 0, "length": 100, "sha256": "hash0"],
                ["index": 1, "offset": 100, "length": 100, "sha256": "hash1"],
            ],
            "receipt_available": false,
            "total_chunks": 2,
            "bytes_expected": 200,
        ]
        let chunkAck0: [String: Any] = ["accepted": true, "missing_chunks": [1]]
        let chunkAck1: [String: Any] = ["accepted": true, "missing_chunks": [Int]()]

        let transport = SequenceTransport([
            HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: offerBody)),
            HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: chunkAck0)),
            HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: chunkAck1)),
            HTTPResponse(status: 200, body: Data([0xA1, 0x62, 0x6F, 0x6B])),
        ])

        let signer = SoftwareSigner(clientID: "c1")
        let client = CairnServerClient(transport: transport, signer: signer)
        let service = BundleRelayService(client: client)

        let bundleData = Data(repeating: 0xAB, count: 200)
        let chunks = MockChunkProvider(data: bundleData)

        let result = try await service.relay(
            manifest: Data([0xA0]),
            signature: "sig123",
            chunkProvider: chunks
        )

        #expect(result.bundleID == "test-bundle")
        #expect(result.chunksUploaded == 2)
        #expect(!result.alreadyCommitted)
        #expect(transport.requestLog.count == 4)
    }

    @Test func relayAlreadyCommittedSkipsUpload() async throws {
        let offerBody: [String: Any] = [
            "bundle_id": "done-bundle",
            "missing_chunks": [[String: Any]](),
            "receipt_available": true,
            "total_chunks": 2,
        ]

        let transport = SequenceTransport([
            HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: offerBody)),
            HTTPResponse(status: 200, body: Data([0xA1, 0x62, 0x6F, 0x6B])),
        ])

        let signer = SoftwareSigner(clientID: "c1")
        let client = CairnServerClient(transport: transport, signer: signer)
        let service = BundleRelayService(client: client)

        let result = try await service.relay(
            manifest: Data([0xA0]),
            signature: "sig123",
            chunkProvider: MockChunkProvider(data: Data())
        )

        #expect(result.bundleID == "done-bundle")
        #expect(result.chunksUploaded == 0)
        #expect(result.alreadyCommitted)
        #expect(transport.requestLog.count == 2)
    }
}

// MARK: - Exchange vector relay test

@Suite struct BundleRelayExchangeTests {
    @Test func relayWithExchangeVectors() async throws {
        let file = Contracts.json("sync/v1/vectors/exchanges.json")
        let allSteps = file["steps"] as! [[String: Any]]
        let fix = file["fixture"] as! [String: Any]
        let allClients = fix["clients"] as! [[String: Any]]
        let alphaData = allClients.first { $0["name"] as? String == "alpha" }!
        let scalar = alphaData["private_scalar_hex"] as! String
        let clientID = alphaData["client_id"] as! String
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalar))
        let signer = SoftwareSigner(clientID: clientID, privateKey: privateKey)

        let bundles = fix["bundles"] as! [[String: Any]]
        let bundle = bundles.first { $0["name"] as? String == "delivered" }!
        let manifestHex = bundle["manifest_cbor_hex"] as! String
        let manifestData = Data(hex: manifestHex)
        let signatureHex = bundle["manifest_signature_hex"] as! String

        let offerStep = allSteps[45]
        let chunk0Step = allSteps[49]
        let chunk1Step = allSteps[50]
        let chunk2Step = allSteps[51]
        let commitStep = allSteps[54]

        let transport = SequenceTransport([
            exchangeResponse(offerStep),
            exchangeResponse(chunk0Step),
            exchangeResponse(chunk1Step),
            exchangeResponse(chunk2Step),
            exchangeResponse(commitStep),
        ])

        let client = CairnServerClient(transport: transport, signer: signer)
        let service = BundleRelayService(client: client)

        let bundleBytes = Data(repeating: 0, count: 764)
        let chunks = MockChunkProvider(data: bundleBytes)

        let result = try await service.relay(
            manifest: manifestData,
            signature: signatureHex,
            chunkProvider: chunks
        )

        #expect(result.bundleID == bundle["bundle_id"] as? String)
        #expect(result.chunksUploaded == 3)

        #expect(transport.requestLog[0].target.contains("/relay/bundles/offer"))
        #expect(transport.requestLog[1].method == "PUT")
        #expect(transport.requestLog[2].method == "PUT")
        #expect(transport.requestLog[3].method == "PUT")
        #expect(transport.requestLog[4].target.contains("/commit"))
    }

    @Test func relayBadManifestSignature() async throws {
        let file = Contracts.json("sync/v1/vectors/exchanges.json")
        let allSteps = file["steps"] as! [[String: Any]]
        let fix = file["fixture"] as! [String: Any]
        let allClients = fix["clients"] as! [[String: Any]]
        let alphaData = allClients.first { $0["name"] as? String == "alpha" }!
        let scalar = alphaData["private_scalar_hex"] as! String
        let clientID = alphaData["client_id"] as! String
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalar))
        let signer = SoftwareSigner(clientID: clientID, privateKey: privateKey)

        let badSigStep = allSteps[44]
        let transport = SequenceTransport([exchangeResponse(badSigStep)])

        let client = CairnServerClient(transport: transport, signer: signer)
        let service = BundleRelayService(client: client)

        do {
            _ = try await service.relay(
                manifest: Data([0xA0]),
                signature: "badsig",
                chunkProvider: MockChunkProvider(data: Data())
            )
            Issue.record("expected badManifestSignature")
        } catch let error as CairnServerError {
            #expect(error == .badManifestSignature)
        }
    }

    @Test func relayReoffer() async throws {
        let file = Contracts.json("sync/v1/vectors/exchanges.json")
        let allSteps = file["steps"] as! [[String: Any]]
        let fix = file["fixture"] as! [String: Any]
        let allClients = fix["clients"] as! [[String: Any]]
        let alphaData = allClients.first { $0["name"] as? String == "alpha" }!
        let scalar = alphaData["private_scalar_hex"] as! String
        let clientID = alphaData["client_id"] as! String
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalar))
        let signer = SoftwareSigner(clientID: clientID, privateKey: privateKey)

        let reofferStep = allSteps[58]
        let receiptStep = allSteps[56]

        let transport = SequenceTransport([
            exchangeResponse(reofferStep),
            exchangeResponse(receiptStep),
        ])

        let client = CairnServerClient(transport: transport, signer: signer)
        let service = BundleRelayService(client: client)

        let result = try await service.relay(
            manifest: Data([0xA0]),
            signature: "sig",
            chunkProvider: MockChunkProvider(data: Data())
        )

        #expect(result.chunksUploaded == 0)
        #expect(result.alreadyCommitted)
    }
}
