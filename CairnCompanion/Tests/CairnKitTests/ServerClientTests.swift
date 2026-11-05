import CairnKit
import CairnProtocol
import CryptoKit
import Foundation
import Testing

// MARK: - Mock transport replaying exchanges.json

private final class ExchangeTransport: HTTPTransport, @unchecked Sendable {
    private let steps: [[String: Any]]
    private var index = 0
    var requestLog: [(name: String, request: HTTPRequest)] = []

    init(steps: [[String: Any]]) {
        self.steps = steps
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard index < steps.count else {
            throw HTTPTransportError(.other)
        }
        let step = steps[index]
        let name = step["name"] as? String ?? ""
        requestLog.append((name, request))

        let resp = step["response"] as! [String: Any]
        let status = resp["status"] as! Int
        let headers = resp["headers"] as? [String: String] ?? [:]

        var body = Data()
        if let bodyJSON = resp["body_json"] {
            body = try JSONSerialization.data(withJSONObject: bodyJSON)
        } else if let bodyHex = resp["body_hex"] as? String, !bodyHex.isEmpty {
            body = Data(hex: bodyHex)
        }

        index += 1
        return HTTPResponse(status: status, headers: headers, body: body)
    }
}

// MARK: - Fixture helpers

private func loadExchanges() -> [String: Any] {
    Contracts.json("sync/v1/vectors/exchanges.json")
}

private func fixture(_ file: [String: Any]) -> [String: Any] {
    file["fixture"] as! [String: Any]
}

private func clients(_ fixture: [String: Any]) -> [[String: Any]] {
    fixture["clients"] as! [[String: Any]]
}

private func findClient(_ name: String, in clients: [[String: Any]]) -> [String: Any] {
    clients.first { $0["name"] as? String == name }!
}

private func makeSigner(_ client: [String: Any]) -> SoftwareSigner {
    let clientID = client["client_id"] as! String
    let scalar = client["private_scalar_hex"] as! String
    let key = try! P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalar))
    return SoftwareSigner(clientID: clientID, privateKey: key)
}

private func makeClient(_ stepSlice: ArraySlice<[String: Any]>, signerName: String, fix: [String: Any]) -> (CairnServerClient, ExchangeTransport) {
    let transport = ExchangeTransport(steps: Array(stepSlice))
    let signer = makeSigner(findClient(signerName, in: clients(fix)))
    let client = CairnServerClient(transport: transport, signer: signer)
    return (client, transport)
}

private func makeClient(_ step: [String: Any], signerName: String, fix: [String: Any]) -> (CairnServerClient, ExchangeTransport) {
    makeClient(ArraySlice([step]), signerName: signerName, fix: fix)
}

// MARK: - Health

@Suite struct ServerClientHealthTests {
    @Test func healthEndpoint() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[0], signerName: "admin", fix: fix)

        let health = try await client.health()
        #expect(health.status == "ok")
        #expect(health.protocolVersion == 1)
        #expect(health.instanceID == fix["instance_id"] as? String)
    }
}

// MARK: - Enrolment

@Suite struct ServerClientEnrolmentTests {
    @Test func enrolSuccess() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let adminClient = findClient("admin", in: clients(fix))
        let (client, _) = makeClient(steps[1], signerName: "admin", fix: fix)

        let codes = fix["invitation_codes"] as! [String: String]
        let result = try await client.enrol(
            code: codes["admin"]!,
            name: "Admin Phone",
            publicKey: adminClient["public_key_x963_hex"] as! String,
            proof: Data(base64Encoded: "AAAA")!
        )
        #expect(result.clientID == adminClient["client_id"] as? String)
        #expect(result.role == "admin")
    }

    @Test func enrolBadProof() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[3], signerName: "admin", fix: fix)

        do {
            let _ = try await client.enrol(code: "bravo", name: "Bad", publicKey: "04ff", proof: Data())
            Issue.record("expected badRequest")
        } catch let error as CairnServerError {
            guard case .badRequest = error else {
                Issue.record("expected .badRequest, got \(error)")
                return
            }
        }
    }

    @Test func enrolCodeAlreadyUsed() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[6], signerName: "admin", fix: fix)

        do {
            let _ = try await client.enrol(code: "admin", name: "Dupe", publicKey: "04ff", proof: Data())
            Issue.record("expected forbidden")
        } catch let error as CairnServerError {
            guard case .forbidden = error else {
                Issue.record("expected .forbidden, got \(error)")
                return
            }
        }
    }
}

// MARK: - Bearer token

@Suite struct ServerClientTokenTests {
    @Test func mintToken() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[7], signerName: "alpha", fix: fix)

        let grant = try await client.mintToken()
        #expect(!grant.token.isEmpty)
        #expect(grant.scope == "sync")
        #expect(!grant.expiresAt.isEmpty)
    }

    @Test func bearerOnSignedOnlyRoute() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[9], signerName: "alpha", fix: fix)

        do {
            let _ = try await client.mintToken()
            Issue.record("expected signatureRequired")
        } catch let error as CairnServerError {
            #expect(error == .signatureRequired, "bearer on signed-only route → .signatureRequired (spec §2.5 exception)")
        }
    }
}

// MARK: - Push

@Suite struct ServerClientPushTests {
    @Test func pushAccepted() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let signer = makeSigner(findClient("alpha", in: clients(fix)))
        let (client, _) = makeClient(steps[10], signerName: "alpha", fix: fix)

        let op = SyncOperation(
            operationID: "0190a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a01",
            clientID: signer.clientID,
            vehicleID: "303132333435363738393a3b3c3d3e3f",
            kind: "maintenance_event",
            createdAt: "2026-09-21T13:33:20Z",
            payload: .object(["kind": .string("oil"), "odometer_km": .int(45210)]),
            contentHash: "f381423e512870001f6ce15889f136c8851fb48acddf55fb6c40b0227e624d6f"
        )
        let push = try await client.push([op])
        #expect(push.results.count == 1)
        #expect(push.results[0].status == .accepted)
        #expect(push.results[0].serverSequence == 1)
    }

    @Test func pushDuplicate() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let signer = makeSigner(findClient("alpha", in: clients(fix)))
        let (client, _) = makeClient(steps[11], signerName: "alpha", fix: fix)

        let op = SyncOperation(
            operationID: "0190a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a01",
            clientID: signer.clientID, vehicleID: "303132333435363738393a3b3c3d3e3f",
            kind: "maintenance_event", createdAt: "2026-09-21T13:33:20Z",
            payload: .object(["kind": .string("oil"), "odometer_km": .int(45210)]),
            contentHash: "f381423e512870001f6ce15889f136c8851fb48acddf55fb6c40b0227e624d6f"
        )
        let push = try await client.push([op])
        #expect(push.results[0].status == .duplicate)
    }

    @Test func pushRejectedScope() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[13], signerName: "alpha", fix: fix)

        let op = SyncOperation(
            operationID: "0190a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a04",
            clientID: "0190c0de000070008000000000000a02",
            vehicleID: "404142434445464748494a4b4c4d4e4f",
            kind: "maintenance_event", createdAt: "2026-09-21T13:33:20Z",
            payload: .object(["kind": .string("oil")]),
            contentHash: "dummy"
        )
        let push = try await client.push([op])
        #expect(push.results[0].status == .rejected)
        #expect(push.results[0].reason == "scope")
    }

    @Test func pushMalformedBody() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[21], signerName: "alpha", fix: fix)

        do {
            let _ = try await client.push([])
            Issue.record("expected badRequest")
        } catch let error as CairnServerError {
            guard case .badRequest = error else {
                Issue.record("expected .badRequest, got \(error)")
                return
            }
        }
    }
}

// MARK: - Pull

@Suite struct ServerClientPullTests {
    @Test func pullFirstPage() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[23], signerName: "alpha", fix: fix)

        let outcome = try await client.pull(limit: 3)
        guard case .page(let page) = outcome else {
            Issue.record("expected .page, got \(outcome)")
            return
        }
        #expect(page.hasMore)
        #expect(!page.cursor.isEmpty)
        #expect(!page.epoch.isEmpty)
        #expect(page.changes.count <= 3)
    }

    @Test func pullCursorReset410() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let foreignCursor = fix["foreign_epoch_cursor"] as! String
        let (client, _) = makeClient(steps[31], signerName: "alpha", fix: fix)

        let outcome = try await client.pull(cursor: foreignCursor)
        guard case .cursorReset = outcome else {
            Issue.record("expected .cursorReset, got \(outcome)")
            return
        }
    }

    @Test func pullBadCursor() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[30], signerName: "alpha", fix: fix)

        do {
            let _ = try await client.pull(cursor: "bm90LWEtY3Vyc29y")
            Issue.record("expected badRequest")
        } catch let error as CairnServerError {
            guard case .badRequest = error else {
                Issue.record("expected .badRequest, got \(error)")
                return
            }
        }
    }
}

// MARK: - Ack

@Suite struct ServerClientAckTests {
    @Test func ackAccepted() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[33], signerName: "alpha", fix: fix)

        let ack = try await client.ack(cursor: "anything")
        #expect(ack.acknowledged == 7)
    }
}

// MARK: - Relay

@Suite struct ServerClientRelayTests {
    @Test func relayOffer() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[45], signerName: "alpha", fix: fix)

        let offer = try await client.relayOffer(manifest: Data(), signature: "abc123")
        #expect(!offer.bundleID.isEmpty)
        #expect(offer.missingChunks.count == 3)
    }

    @Test func relayChunkAccepted() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[49], signerName: "alpha", fix: fix)

        let ack = try await client.relayChunk(
            bundleID: "364ba7c8cb59ab8f74c09a8f78aeef35",
            sha256: "84791ee5f44c5d0f0877cb6a89cacf5c8c5e42a1fbda3c8581e317203cfe5b82",
            data: Data(repeating: 0, count: 256)
        )
        #expect(ack.accepted)
    }

    @Test func relayCommitReturnsReceipt() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[54], signerName: "alpha", fix: fix)

        let receipt = try await client.relayCommit(bundleID: "364ba7c8cb59ab8f74c09a8f78aeef35")
        #expect(!receipt.bytes.isEmpty)
    }

    @Test func relayOfferOutOfScope() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[41], signerName: "bravo", fix: fix)

        do {
            let _ = try await client.relayOffer(manifest: Data(), signature: "abc")
            Issue.record("expected forbidden")
        } catch let error as CairnServerError {
            guard case .forbidden(.scope) = error else {
                Issue.record("expected .forbidden(.scope), got \(error)")
                return
            }
        }
    }

    @Test func relayOfferBadManifestSignature() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[44], signerName: "alpha", fix: fix)

        do {
            let _ = try await client.relayOffer(manifest: Data(), signature: "bad")
            Issue.record("expected badManifestSignature")
        } catch let error as CairnServerError {
            #expect(error == .badManifestSignature)
        }
    }
}

// MARK: - Auth negatives: uniform 401

@Suite struct ServerClientAuthNegativeTests {
    @Test func uniform401NeverBranchesOnCause() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)

        let authNegativeIndices = [60, 61, 62, 63, 64, 65, 68, 69, 70, 71, 72, 73, 74]
        for i in authNegativeIndices {
            let step = steps[i]
            let name = step["name"] as! String
            let signerName: String
            if let signing = step["signing"] as? [String: Any] {
                signerName = signing["signer"] as! String
            } else {
                signerName = "alpha"
            }
            let (client, _) = makeClient(step, signerName: signerName, fix: fix)

            do {
                let _ = try await client.pull(limit: 1)
                Issue.record("\(name): expected throw")
            } catch let error as CairnServerError {
                #expect(error == .unauthenticated, "\(name): expected uniform .unauthenticated, got \(error)")
            }
        }
    }

    @Test func auth120sSkewAccepted() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)

        for i in [66, 67] {
            let step = steps[i]
            let name = step["name"] as! String
            let (client, _) = makeClient(step, signerName: "alpha", fix: fix)

            let outcome = try await client.pull(limit: 1)
            guard case .page = outcome else {
                Issue.record("\(name): expected .page, got \(outcome)")
                continue
            }
        }
    }
}

// MARK: - Revocation

@Suite struct ServerClientRevocationTests {
    @Test func revokeClient() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[77], signerName: "admin", fix: fix)

        try await client.revokeClient("0190c0de000070008000000000000a04")
    }

    @Test func revokedClientGets401() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[78], signerName: "charlie", fix: fix)

        do {
            let _ = try await client.pull(limit: 1)
            Issue.record("expected unauthenticated after revocation")
        } catch let error as CairnServerError {
            #expect(error == .unauthenticated)
        }
    }

    @Test func revokedBearerTokenGets401() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[79], signerName: "charlie", fix: fix)

        do {
            let _ = try await client.pull(limit: 1)
            Issue.record("expected unauthenticated for revoked bearer")
        } catch let error as CairnServerError {
            #expect(error == .unauthenticated)
        }
    }
}

// MARK: - Token expiry

@Suite struct ServerClientTokenExpiryTests {
    @Test func tokenValidAtExactlyOneHour() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[80], signerName: "alpha", fix: fix)

        let outcome = try await client.pull(limit: 1)
        guard case .page = outcome else {
            Issue.record("expected .page at exact 1-hour, got \(outcome)")
            return
        }
    }

    @Test func tokenExpired() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[81], signerName: "alpha", fix: fix)

        do {
            let _ = try await client.pull(limit: 1)
            Issue.record("expected unauthenticated for expired token")
        } catch let error as CairnServerError {
            #expect(error == .unauthenticated)
        }
    }
}

// MARK: - Nonce uniqueness

@Suite struct ServerClientNonceTests {
    @Test func freshNoncePerRequest() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let step = steps[23]
        let transport = ExchangeTransport(steps: [step, step])
        let signer = makeSigner(findClient("alpha", in: clients(fix)))
        let client = CairnServerClient(transport: transport, signer: signer)

        let _ = try await client.pull(limit: 3)
        let _ = try await client.pull(limit: 3)

        let requests = transport.requestLog
        #expect(requests.count == 2)
        let auth1 = requests[0].request.headers["Authorization"]!
        let auth2 = requests[1].request.headers["Authorization"]!
        #expect(auth1 != auth2, "two requests must never share the same Authorization header")
    }
}

// MARK: - Snapshot

@Suite struct ServerClientSnapshotTests {
    @Test func snapshotScopedClientMustNameVehicle() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let (client, _) = makeClient(steps[36], signerName: "bravo", fix: fix)

        do {
            let _ = try await client.snapshot()
            Issue.record("expected forbidden")
        } catch let error as CairnServerError {
            guard case .forbidden = error else {
                Issue.record("expected .forbidden, got \(error)")
                return
            }
        }
    }
}

// MARK: - Full exchange replay: every response classified correctly

@Suite struct FullExchangeReplayTests {
    @Test func allResponsesClassifiedCorrectly() async throws {
        let file = loadExchanges()
        let steps = file["steps"] as! [[String: Any]]
        let fix = fixture(file)
        let allClients = clients(fix)

        #expect(steps.count >= 83)

        var errorCount = 0
        for (i, step) in steps.enumerated() {
            let name = step["name"] as! String
            let resp = step["response"] as! [String: Any]
            let status = resp["status"] as! Int

            let signerName: String
            if let signing = step["signing"] as? [String: Any] {
                signerName = signing["signer"] as! String
            } else {
                signerName = "admin"
            }
            let signer = makeSigner(findClient(signerName, in: allClients))
            let transport = ExchangeTransport(steps: [step])
            let client = CairnServerClient(transport: transport, signer: signer)

            let request = step["request"] as! [String: Any]
            let target = request["request_target"] as! String
            let method = request["method"] as! String

            do {
                switch (status, target, method) {
                case (200...201, "/v1/health", _):
                    let _ = try await client.health()
                case (200...201, "/v1/enroll/app", _):
                    let _ = try await client.enrol(code: "x", name: "x", publicKey: "04ff", proof: Data())
                case (200...201, "/v1/auth/token", _):
                    let _ = try await client.mintToken()
                case (200, "/v1/sync/push", _):
                    let _ = try await client.push([])
                case (200, let t, _) where t.hasPrefix("/v1/sync/pull"):
                    let _ = try await client.pull(limit: 1)
                case (200, "/v1/sync/ack", _):
                    let _ = try await client.ack(cursor: "x")
                case (200, "/v1/relay/bundles/offer", _):
                    let _ = try await client.relayOffer(manifest: Data(), signature: "x")
                case (200, let t, "PUT") where t.contains("/chunks/"):
                    let _ = try await client.relayChunk(bundleID: "x", sha256: "y", data: Data())
                case (200, let t, _) where t.contains("/commit"):
                    let _ = try await client.relayCommit(bundleID: "x")
                case (200, let t, _) where t.contains("/receipt"):
                    let _ = try await client.relayReceipt(bundleID: "x")
                case (200, let t, _) where t.contains("/revoke"):
                    try await client.revokeClient("0190c0de000070008000000000000a04")

                case (400, "/v1/enroll/app", _):
                    do { let _ = try await client.enrol(code: "x", name: "x", publicKey: "04ff", proof: Data()); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (400, "/v1/sync/push", _):
                    do { let _ = try await client.push([]); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (400, let t, _) where t.hasPrefix("/v1/sync/pull"):
                    do { let _ = try await client.pull(limit: 0); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (400, "/v1/sync/ack", _):
                    do { let _ = try await client.ack(cursor: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (400, let t, _) where t.contains("/relay/"):
                    do { let _ = try await client.relayOffer(manifest: Data(), signature: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (400, let t, _) where t.hasPrefix("/v1/snapshot"):
                    do { let _ = try await client.snapshot(); Issue.record("\(name)") }
                    catch is CairnServerError {}

                case (401, let t, _) where t.hasPrefix("/v1/sync/pull") || t == "/v1/sync/ack":
                    do { let _ = try await client.pull(limit: 1); Issue.record("\(name)") }
                    catch let e as CairnServerError { #expect(e == .unauthenticated, "\(name)") }
                case (401, "/v1/auth/token", _):
                    do { let _ = try await client.mintToken(); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (401, let t, _) where t.contains("/relay/"):
                    do { let _ = try await client.relayOffer(manifest: Data(), signature: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}

                case (403, "/v1/enroll/app", _):
                    do { let _ = try await client.enrol(code: "x", name: "x", publicKey: "04ff", proof: Data()); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (403, let t, _) where t.hasPrefix("/v1/snapshot"):
                    do { let _ = try await client.snapshot(); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (403, "/v1/clients", _):
                    do { let _ = try await client.pull(limit: 1); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (403, let t, "PUT") where t.contains("/chunks/"):
                    do { let _ = try await client.relayChunk(bundleID: "x", sha256: "y", data: Data()); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (403, let t, _) where t.contains("/commit"):
                    do { let _ = try await client.relayCommit(bundleID: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (403, let t, _) where t.contains("/receipt"):
                    do { let _ = try await client.relayReceipt(bundleID: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (403, let t, _) where t.contains("/relay/"):
                    do { let _ = try await client.relayOffer(manifest: Data(), signature: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}

                case (404, let t, _) where t.contains("/chunks/"):
                    do { let _ = try await client.relayChunk(bundleID: "x", sha256: "y", data: Data()); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (404, let t, _) where t.contains("/receipt"):
                    do { let _ = try await client.relayReceipt(bundleID: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}

                case (409, let t, _) where t.contains("/chunks/"):
                    do { let _ = try await client.relayChunk(bundleID: "x", sha256: "y", data: Data()); Issue.record("\(name)") }
                    catch is CairnServerError {}
                case (409, let t, _) where t.contains("/commit"):
                    do { let _ = try await client.relayCommit(bundleID: "x"); Issue.record("\(name)") }
                    catch is CairnServerError {}

                case (410, _, _):
                    let outcome = try await client.pull(cursor: "old")
                    guard case .cursorReset = outcome else {
                        Issue.record("\(name): expected .cursorReset")
                        errorCount += 1; continue
                    }

                default:
                    continue
                }
            } catch {
                Issue.record("step \(i) \(name): unexpected throw: \(error)")
                errorCount += 1
            }
        }
        #expect(errorCount == 0, "\(errorCount) steps classified incorrectly")
    }
}

// MARK: - R3: the errors the offload loop has to tell apart

@Suite("Named relay errors")
struct NamedRelayErrorTests {
    /// A transport that answers one canned response, so a status code can be asked about
    /// directly rather than through a whole relay conversation.
    private final class OneAnswer: HTTPTransport, @unchecked Sendable {
        let status: Int
        let body: Data
        private(set) var calls = 0
        init(status: Int, error code: String) {
            self.status = status
            self.body = Data("{\"error\":\"\(code)\"}".utf8)
        }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            calls += 1
            return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
        }
    }

    private func client(_ transport: OneAnswer) -> CairnServerClient {
        CairnServerClient(transport: transport,
                          signer: KeyProviderSigner(provider: SoftwareKeyProvider(), clientID: "00ff"))
    }

    @Test("429 too_many_offers is its own error, not rate limiting")
    func tooManyOffers() async {
        // The data is fine; this client simply has too many bundles in flight. Collapsing it
        // into rate_limited would make the offload loop back off when it should commit.
        let transport = OneAnswer(status: 429, error: "too_many_offers")
        await #expect(throws: CairnServerError.tooManyOffers) {
            _ = try await client(transport).relayOffer(manifest: Data("{}".utf8), signature: String(repeating: "a", count: 128))
        }
    }

    @Test("429 rate_limited still means slow down")
    func rateLimited() async {
        let transport = OneAnswer(status: 429, error: "rate_limited")
        await #expect(throws: CairnServerError.rateLimited(retryAfter: nil)) {
            _ = try await client(transport).relayOffer(manifest: Data("{}".utf8), signature: String(repeating: "a", count: 128))
        }
    }

    @Test("507 quota_exceeded is a stop, not a 5xx to retry with backoff")
    func quotaExceeded() async {
        let transport = OneAnswer(status: 507, error: "quota_exceeded")
        await #expect(throws: CairnServerError.quotaExceeded) {
            _ = try await client(transport).relayOffer(manifest: Data("{}".utf8), signature: String(repeating: "a", count: 128))
        }
    }

    @Test("each one reports the status and the code it came from")
    func statusesAndCodes() {
        #expect(CairnServerError.tooManyOffers.httpStatus == 429)
        #expect(CairnServerError.tooManyOffers.errorCode == "too_many_offers")
        #expect(CairnServerError.quotaExceeded.httpStatus == 507)
        #expect(CairnServerError.quotaExceeded.errorCode == "quota_exceeded")
    }
}
