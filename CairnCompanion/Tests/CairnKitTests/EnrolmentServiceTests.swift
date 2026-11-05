import CairnKit
import CairnProtocol
import CryptoKit
import Foundation
import Testing

// MARK: - Mock transport for enrolment tests

private final class MockTransport: HTTPTransport, @unchecked Sendable {
    var handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    var capturedRequests: [HTTPRequest] = []

    init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        capturedRequests.append(request)
        return try await handler(request)
    }
}

private func enrolResponse(clientID: String, role: String, vehicles: [String]) -> HTTPResponse {
    let body: [String: Any] = [
        "client_id": clientID,
        "role": role,
        "vehicles": vehicles,
        "server_time": "2025-01-15T12:00:00Z",
        "server_identity": [
            "instance_id": "test-instance-abc123",
            "spki_sha256": "aabbccdd"
        ]
    ]
    let data = try! JSONSerialization.data(withJSONObject: body)
    return HTTPResponse(status: 201, headers: ["Content-Type": "application/json"], body: data)
}

private func errorResponse(status: Int, error: String, message: String = "") -> HTTPResponse {
    let body = try! JSONSerialization.data(withJSONObject: ["error": error, "message": message])
    return HTTPResponse(status: status, body: body)
}

// MARK: - Enrolment service tests

@Suite struct EnrolmentServiceBasicTests {
    @Test func successfulEnrolment() async throws {
        let keyProvider = SoftwareKeyProvider()
        let store = InMemoryIdentityStore()
        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)

        let transport = MockTransport { request in
            #expect(request.method == "POST")
            #expect(request.target == "/v1/enroll/app")

            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            #expect(body["public_key"] as? String == keyProvider.publicKeyHex)
            #expect(body["name"] as? String == "Test Device")
            let proofB64 = body["proof"] as! String
            #expect(!proofB64.isEmpty)

            return enrolResponse(clientID: "c1d2e3f4", role: "admin", vehicles: ["*"])
        }

        let placeholder = PlaceholderTestSigner()
        let client = CairnServerClient(transport: transport, signer: placeholder)

        let identity = try await service.enrol(
            code: "ABCD-1234",
            deviceName: "Test Device",
            using: client,
            localBaseURL: "https://cairn.example.lan",
            tailnetBaseURL: "https://cairn.ts.net"
        )

        #expect(identity.clientID == "c1d2e3f4")
        #expect(identity.role == "admin")
        #expect(identity.scope == ["*"])
        #expect(identity.instanceID == "test-instance-abc123")
        #expect(identity.spkiSHA256 == "aabbccdd")
        #expect(identity.localBaseURL == "https://cairn.example.lan")
        #expect(identity.tailnetBaseURL == "https://cairn.ts.net")

        let (state, stored) = await store.load()
        #expect(state == .enrolled)
        #expect(stored?.clientID == "c1d2e3f4")
    }

    @Test func enrolmentNormalizesCode() async throws {
        let keyProvider = SoftwareKeyProvider()
        let store = InMemoryIdentityStore()
        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)

        let transport = MockTransport { _ in
            enrolResponse(clientID: "aabb", role: "user", vehicles: ["v1"])
        }

        let client = CairnServerClient(transport: transport, signer: PlaceholderTestSigner())
        _ = try await service.enrol(
            code: "ABCD-EF12-3456-7890",
            deviceName: "Phone",
            using: client,
            localBaseURL: "",
            tailnetBaseURL: ""
        )

        let body = try JSONSerialization.jsonObject(with: transport.capturedRequests[0].body) as! [String: Any]
        #expect(body["code"] as? String == "abcdef1234567890")
    }

    @Test func enrolmentProofIsValidSignature() async throws {
        let keyProvider = SoftwareKeyProvider()
        let store = InMemoryIdentityStore()
        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)

        let transport = MockTransport { _ in
            enrolResponse(clientID: "cc", role: "admin", vehicles: ["*"])
        }

        let client = CairnServerClient(transport: transport, signer: PlaceholderTestSigner())
        _ = try await service.enrol(
            code: "test1234",
            deviceName: "Dev",
            using: client,
            localBaseURL: "",
            tailnetBaseURL: ""
        )

        let body = try JSONSerialization.jsonObject(with: transport.capturedRequests[0].body) as! [String: Any]
        let capturedProof = Data(base64Encoded: body["proof"] as! String)!
        let capturedPublicKey = body["public_key"] as! String
        let capturedCode = body["code"] as! String

        let expectedMessage = EnrolmentProof.message(
            code: capturedCode, publicKeyHex: capturedPublicKey
        )
        let pubKeyData = Data(hex: capturedPublicKey)
        let pubKey = try P256.Signing.PublicKey(x963Representation: pubKeyData)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: capturedProof)
        #expect(pubKey.isValidSignature(sig, for: expectedMessage))
    }
}

@Suite struct EnrolmentServiceErrorTests {
    @Test func serverRejectionResetsState() async throws {
        let store = InMemoryIdentityStore()
        let service = EnrolmentService(
            keyProvider: SoftwareKeyProvider(),
            identityStore: store
        )

        let transport = MockTransport { _ in
            errorResponse(status: 403, error: "enrolment_refused")
        }

        let client = CairnServerClient(transport: transport, signer: PlaceholderTestSigner())
        do {
            _ = try await service.enrol(
                code: "bad-code",
                deviceName: "Phone",
                using: client,
                localBaseURL: "",
                tailnetBaseURL: ""
            )
            Issue.record("expected error")
        } catch let error as CairnServerError {
            guard case .forbidden(.enrolmentRefused) = error else {
                Issue.record("expected .forbidden(.enrolmentRefused), got \(error)")
                return
            }
        }

        let (state, _) = await store.load()
        #expect(state == .notEnrolled)
    }

    @Test func badRequestOnInvalidProof() async throws {
        let store = InMemoryIdentityStore()
        let service = EnrolmentService(
            keyProvider: SoftwareKeyProvider(),
            identityStore: store
        )

        let transport = MockTransport { _ in
            errorResponse(status: 400, error: "bad_proof")
        }

        let client = CairnServerClient(transport: transport, signer: PlaceholderTestSigner())
        do {
            _ = try await service.enrol(
                code: "code",
                deviceName: "Phone",
                using: client,
                localBaseURL: "",
                tailnetBaseURL: ""
            )
            Issue.record("expected error")
        } catch let error as CairnServerError {
            guard case .badRequest(code: "bad_proof") = error else {
                Issue.record("expected .badRequest(bad_proof), got \(error)")
                return
            }
        }

        let (state, _) = await store.load()
        #expect(state == .notEnrolled)
    }
}

@Suite struct EnrolmentServiceIdentityTests {
    @Test func loadIdentityReturnsStoredState() async throws {
        let store = InMemoryIdentityStore()
        let keyProvider = SoftwareKeyProvider()
        let identity = EnrolledIdentity(
            clientID: "abc123", role: "admin", scope: ["*"],
            instanceID: "inst1", spkiSHA256: "spki",
            localBaseURL: "https://cairn.example.lan",
            tailnetBaseURL: "https://cairn.ts.net",
            publicKeyHex: keyProvider.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(
            keyProvider: keyProvider,
            identityStore: store
        )

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .enrolled)
        #expect(loaded?.clientID == "abc123")
        #expect(loaded?.isAdmin == true)
    }

    @Test func resetClearsIdentityAndKey() async throws {
        let store = InMemoryIdentityStore()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["v1"],
            instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: ""
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(
            keyProvider: SoftwareKeyProvider(),
            identityStore: store
        )

        try await service.reset()

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .notEnrolled)
        #expect(loaded == nil)
    }

    private struct KeyThatCannotBeReplaced: KeyProvider {
        let inner = SoftwareKeyProvider()
        var publicKeyX963: Data { inner.publicKeyX963 }
        var publicKeyHex: String { inner.publicKeyHex }
        func sign(_ data: Data) throws -> Data { try inner.sign(data) }
        func deleteKey() throws { throw EnrolmentError.proofSigningFailed }
    }

    @Test func resetClearsTheEnrolmentEvenWhenTheKeyCannotBeReplaced() async throws {
        let store = InMemoryIdentityStore()
        let key = KeyThatCannotBeReplaced()
        try await store.save(state: .enrolled, identity: EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["*"], instanceID: "i", spkiSHA256: "s",
            localBaseURL: "", tailnetBaseURL: "", publicKeyHex: key.publicKeyHex
        ))
        let service = EnrolmentService(keyProvider: key, identityStore: store)

        await #expect(throws: EnrolmentError.self) { try await service.reset() }

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .notEnrolled)
        #expect(loaded == nil)
    }

    @Test func resetWorksFromTheStatesThatAskedForIt() async throws {
        for stored in [EnrolmentState.revoked, .needsReenrolment, .enrolled] {
            let store = InMemoryIdentityStore()
            try await store.save(state: stored == .needsReenrolment ? .enrolled : stored, identity: EnrolledIdentity(
                clientID: "abc", role: "user", scope: ["*"], instanceID: "i", spkiSHA256: "s",
                localBaseURL: "", tailnetBaseURL: "", publicKeyHex: stored == .needsReenrolment ? "00" : nil
            ))
            let service = EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: store)
            try await service.reset()
            let (state, _) = await service.loadIdentity()
            #expect(state == .notEnrolled, "from \(stored)")
        }
    }

    @Test func makeSignerReturnsNilWhenNotEnrolled() async throws {
        let service = EnrolmentService(
            keyProvider: SoftwareKeyProvider(),
            identityStore: InMemoryIdentityStore()
        )

        let signer = await service.makeSigner()
        #expect(signer == nil)
    }

    @Test func makeSignerReturnsValidSignerWhenEnrolled() async throws {
        let keyProvider = SoftwareKeyProvider()
        let store = InMemoryIdentityStore()
        let identity = EnrolledIdentity(
            clientID: "deadbeef", role: "admin", scope: ["*"],
            instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: "",
            publicKeyHex: keyProvider.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)
        let signer = await service.makeSigner()

        #expect(signer != nil)
        #expect(signer?.clientID == "deadbeef")
        #expect(signer?.publicKeyX963 == keyProvider.publicKeyX963)

        let testData = Data("test message".utf8)
        let signature = try signer!.sign(testData)
        let pubKey = try P256.Signing.PublicKey(x963Representation: keyProvider.publicKeyX963)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        #expect(pubKey.isValidSignature(sig, for: testData))
    }

    // The bug this guards against: the Secure Enclave key was never saved, so each launch made a
    // new key and every signed request was refused with 401 signature_does_not_verify.
    @Test func anIdentityEnrolledWithAnotherKeyNeedsReenrolmentAndGetsNoSigner() async throws {
        let store = InMemoryIdentityStore()
        let earlierKey = SoftwareKeyProvider()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["*"], instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: "", publicKeyHex: earlierKey.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: store)
        let (state, loaded) = await service.loadIdentity()
        #expect(state == .needsReenrolment)
        #expect(loaded?.clientID == "abc")
        #expect(await service.makeSigner() == nil)
    }

    @Test func anIdentitySavedBeforeKeysWereKeptNeedsReenrolment() async throws {
        let store = InMemoryIdentityStore()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["*"], instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: ""
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: store)
        let (state, _) = await service.loadIdentity()
        #expect(state == .needsReenrolment)
    }

    @Test func aStoredIdentityWithoutAKeyStillDecodes() throws {
        let old = Data("""
        {"clientID":"abc","role":"user","scope":["*"],"instanceID":"i","spkiSHA256":"s","localBaseURL":"","tailnetBaseURL":""}
        """.utf8)
        let identity = try JSONDecoder().decode(EnrolledIdentity.self, from: old)
        #expect(identity.publicKeyHex == nil)
    }

    @Test func markRevoked() async throws {
        let store = InMemoryIdentityStore()
        let keyProvider = SoftwareKeyProvider()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "admin", scope: ["*"],
            instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: "",
            publicKeyHex: keyProvider.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(
            keyProvider: keyProvider,
            identityStore: store
        )

        try await service.markRevoked()

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .revoked)
        #expect(loaded?.clientID == "abc")
    }
}

@Suite struct EnrolmentServiceExchangeTests {
    @Test func enrolWithExchangeVectors() async throws {
        let file = Contracts.json("sync/v1/vectors/exchanges.json")
        let steps = file["steps"] as! [[String: Any]]
        let fix = file["fixture"] as! [String: Any]
        let allClients = fix["clients"] as! [[String: Any]]
        let adminData = allClients.first { $0["name"] as? String == "admin" }!
        let codes = fix["invitation_codes"] as! [String: String]
        let adminCode = codes["admin"]!

        let scalar = adminData["private_scalar_hex"] as! String
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalar))
        let keyProvider = SoftwareKeyProvider(privateKey: privateKey)

        let store = InMemoryIdentityStore()
        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)

        let step = steps[1]
        let resp = step["response"] as! [String: Any]
        let respBody = try JSONSerialization.data(withJSONObject: resp["body_json"]!)
        let respStatus = resp["status"] as! Int
        let respHeaders = resp["headers"] as? [String: String] ?? [:]
        let transport = MockTransport { _ in
            HTTPResponse(status: respStatus, headers: respHeaders, body: respBody)
        }

        let client = CairnServerClient(transport: transport, signer: PlaceholderTestSigner())
        let identity = try await service.enrol(
            code: adminCode,
            deviceName: "Admin Phone",
            using: client,
            localBaseURL: "https://cairn.example.lan",
            tailnetBaseURL: "https://cairn.ts.net"
        )

        let expectedClientID = adminData["client_id"] as! String
        #expect(identity.clientID == expectedClientID)
        #expect(identity.role == "admin")

        let (state, _) = await store.load()
        #expect(state == .enrolled)
    }
}

// MARK: - Test helpers

private struct PlaceholderTestSigner: RequestSigner, Sendable {
    let clientID = ""
    let publicKeyX963 = Data()
    func sign(_ data: Data) throws -> Data {
        throw CairnServerError.signingFailed
    }
}
