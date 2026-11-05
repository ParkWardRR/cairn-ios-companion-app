import CairnProtocol
import CryptoKit
import Foundation

public actor CairnServerClient {
    private let transport: any HTTPTransport
    /// Where chunk uploads go, when they go somewhere else.
    ///
    /// A chunk is the one request that may outlive the app: a drive leaves the phone locked in
    /// a mount, iOS suspends what it likes, and a 64 KiB `PUT` handed to a background
    /// `URLSession` finishes whether or not the app is still there (`sync/v1` §10). Everything
    /// else is a short signed request that only makes sense in the foreground, because only the
    /// foreground can reach the Secure Enclave to sign it.
    private let chunkTransport: any HTTPTransport
    private let signer: any RequestSigner
    private let tokenStore: any BearerTokenStore
    private let clock: @Sendable () -> Int
    private let onRevoked: (@Sendable () async -> Void)?

    public init(
        transport: any HTTPTransport,
        signer: any RequestSigner,
        tokenStore: any BearerTokenStore = InMemoryBearerTokenStore(),
        chunkTransport: (any HTTPTransport)? = nil,
        clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
        onRevoked: (@Sendable () async -> Void)? = nil
    ) {
        self.transport = transport
        self.chunkTransport = chunkTransport ?? transport
        self.signer = signer
        self.tokenStore = tokenStore
        self.clock = clock
        self.onRevoked = onRevoked
    }

    // MARK: - Health

    public func health() async throws -> HealthInfo {
        let request = HTTPRequest(method: "GET", target: "/v1/health")
        let response = try await execute(request)
        return try decode(response)
    }

    // MARK: - Enrolment

    public func enrol(
        code: String,
        name: String,
        publicKey: String,
        proof: Data
    ) async throws -> EnrolmentResult {
        let body: [String: Any] = [
            "code": code,
            "name": name,
            "public_key": publicKey,
            "proof": proof.base64EncodedString()
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let request = HTTPRequest(
            method: "POST", target: "/v1/enroll/app",
            headers: ["Content-Type": "application/json"],
            body: bodyData
        )
        let response = try await execute(request)
        return try decode(response)
    }

    // MARK: - Bearer token

    public func mintToken() async throws -> TokenGrant {
        let request = try signedRequest(method: "POST", target: "/v1/auth/token", body: Data())
        let response = try await execute(request)
        let grant: TokenGrant = try decode(response)
        if let expires = ServerTimestamp.parse(grant.expiresAt) {
            await tokenStore.save(BearerToken(token: grant.token, expiresAt: expires))
        }
        return grant
    }

    public func clearToken() async {
        await tokenStore.clear()
    }

    // MARK: - Push

    public func push(_ operations: [SyncOperation]) async throws -> PushResponse {
        let wrapper = PushWrapper(operations: operations)
        let body = try JSONEncoder().encode(wrapper)
        return try await authenticatedJSON(method: "POST", target: "/v1/sync/push", body: body)
    }

    // MARK: - Pull

    public func pull(cursor: String? = nil, limit: Int? = nil, vehicleID: String? = nil) async throws -> PullOutcome {
        var parts: [String] = []
        if let cursor { parts.append("cursor=\(cursor)") }
        if let limit { parts.append("limit=\(limit)") }
        if let vehicleID { parts.append("vehicle=\(vehicleID)") }
        let query = parts.isEmpty ? "" : "?\(parts.joined(separator: "&"))"
        let target = "/v1/sync/pull\(query)"

        let request = try signedRequest(method: "GET", target: target, body: Data())
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HTTPTransportError {
            throw CairnServerError.transport(error.failure)
        } catch {
            throw CairnServerError.transport(.other)
        }

        if response.status == 410 {
            return .cursorReset
        }
        guard (200...299).contains(response.status) else {
            throw classify(response)
        }
        let page: PullPage = try decodeBody(response)
        return .page(page)
    }

    // MARK: - Ack

    public func ack(cursor: String) async throws -> AckResponse {
        let body = try JSONEncoder().encode(["cursor": cursor])
        return try await authenticatedJSON(method: "POST", target: "/v1/sync/ack", body: body)
    }

    // MARK: - Snapshot

    public func snapshot(vehicleID: String? = nil) async throws -> Data {
        let query = vehicleID.map { "?vehicle=\($0)" } ?? ""
        let target = "/v1/snapshot\(query)"
        let request = try signedRequest(method: "GET", target: target, body: Data())
        let response = try await execute(request)
        return response.body
    }

    // MARK: - Relay

    public func relayOffer(manifest: Data, signature: String) async throws -> RelayOffer {
        var request = try signedRequest(method: "POST", target: "/v1/relay/bundles/offer", body: manifest)
        request.headers["Content-Type"] = "application/cbor"
        request.headers["X-Cairn-Signature"] = signature
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HTTPTransportError {
            throw CairnServerError.transport(error.failure)
        } catch {
            throw CairnServerError.transport(.other)
        }
        if response.status == 401 {
            let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: response.body)
            if errorBody?.error == "bad_manifest_signature" {
                throw CairnServerError.badManifestSignature
            }
            throw CairnServerError.unauthenticated
        }
        guard (200...299).contains(response.status) else {
            throw classify(response)
        }
        return try decodeBody(response)
    }

    /// A chunk, by bearer token when one is asked for.
    ///
    /// Chunks are the only thing that goes up by bearer, and that is the whole reason the token
    /// exists: a background `URLSession` task is handed to the system and runs later, possibly
    /// after the app is gone, and it cannot sign anything then because the Secure Enclave needs
    /// the app alive. A one-hour token it can carry is the trade (`sync/v1` §2.3, §10).
    ///
    /// A token expires. The clock check below catches the ordinary case, and a 401 catches the
    /// one it cannot — a token revoked, or a server restarted, mid-upload. One fresh token and
    /// one retry; a second 401 is a real refusal and is raised.
    public func relayChunk(bundleID: String, sha256: String, data chunkData: Data, useBearer: Bool = false) async throws -> ChunkAck {
        let target = "/v1/relay/bundles/\(bundleID)/chunks/\(sha256)"

        func bearerRequest(_ token: BearerToken) -> HTTPRequest {
            HTTPRequest(
                method: "PUT", target: target,
                headers: ["Authorization": "Bearer \(token.token)", "Content-Type": "application/octet-stream"],
                body: chunkData
            )
        }

        if useBearer, let token = await tokenStore.load(), Date() < token.expiresAt {
            let response = try await execute(bearerRequest(token), over: chunkTransport)
            if response.status != 401 { return try decode(response) }
            await tokenStore.clear()
            if let refreshed = try? await mintToken(),
               let expires = ServerTimestamp.parse(refreshed.expiresAt) {
                let retried = try await execute(
                    bearerRequest(BearerToken(token: refreshed.token, expiresAt: expires)),
                    over: chunkTransport
                )
                return try decode(retried)
            }
            // No token to be had: fall through to a signed request, which works while the app
            // is in the foreground and is better than losing the chunk.
        }

        var signed = try signedRequest(method: "PUT", target: target, body: chunkData)
        signed.headers["Content-Type"] = "application/octet-stream"
        let response = try await execute(signed)
        return try decode(response)
    }

    public func relayCommit(bundleID: String) async throws -> RelayReceipt {
        let target = "/v1/relay/bundles/\(bundleID)/commit"
        let request = try signedRequest(method: "POST", target: target, body: Data())
        let response = try await execute(request)
        let already = response.header("X-Cairn-Already-Committed") == "true"
        return RelayReceipt(bytes: response.body, receiptID: nil, alreadyCommitted: already)
    }

    public func relayReceipt(bundleID: String) async throws -> RelayReceipt {
        let target = "/v1/relay/bundles/\(bundleID)/receipt"
        let request = try signedRequest(method: "GET", target: target, body: Data())
        let response = try await execute(request)
        return RelayReceipt(bytes: response.body, receiptID: nil, alreadyCommitted: false)
    }

    // MARK: - Admin

    public func listClients() async throws -> [ClientEntry] {
        try await authenticatedJSON(method: "GET", target: "/v1/clients", body: Data())
    }

    public func listDevices() async throws -> [DeviceEntry] {
        try await authenticatedJSON(method: "GET", target: "/v1/devices", body: Data())
    }

    public func revokeClient(_ clientID: String, reason: String? = nil) async throws {
        try validateHex(clientID, label: "client_id")
        let target = "/v1/clients/\(clientID)/revoke"
        let body = reason.flatMap { try? JSONEncoder().encode(["reason": $0]) } ?? Data()
        let _: RevokeBody = try await authenticatedJSON(method: "POST", target: target, body: body)
    }

    public func revokeDevice(_ deviceID: String, reason: String? = nil) async throws {
        try validateHex(deviceID, label: "device_id")
        let target = "/v1/devices/\(deviceID)/revoke"
        let body = reason.flatMap { try? JSONEncoder().encode(["reason": $0]) } ?? Data()
        let _: RevokeBody = try await authenticatedJSON(method: "POST", target: target, body: body)
    }

    // MARK: - Request building

    private func signedRequest(method: String, target: String, body: Data) throws -> HTTPRequest {
        let ts = clock()
        let nonce = SigningString.freshNonce()
        let bodyHash = SigningString.bodyHash(body)
        let signingData = SigningString.build(
            method: method, target: target, timestamp: ts,
            nonce: nonce, bodyHash: bodyHash, clientID: signer.clientID
        )
        let signatureDER: Data
        do {
            signatureDER = try signer.sign(signingData)
        } catch {
            throw CairnServerError.signingFailed
        }
        let auth = SigningString.authorizationHeader(
            clientID: signer.clientID, timestamp: ts, nonce: nonce, signatureDER: signatureDER
        )
        return HTTPRequest(method: method, target: target, headers: ["Authorization": auth], body: body)
    }

    // MARK: - Authenticated convenience

    private func authenticatedJSON<T: Decodable>(method: String, target: String, body: Data) async throws -> T {
        var request = try signedRequest(method: method, target: target, body: body)
        if !body.isEmpty { request.headers["Content-Type"] = "application/json" }
        let response = try await execute(request)
        return try decode(response)
    }

    // MARK: - Transport + classify

    private func execute(
        _ request: HTTPRequest, over transport: (any HTTPTransport)? = nil
    ) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await (transport ?? self.transport).send(request)
        } catch let error as HTTPTransportError {
            throw CairnServerError.transport(error.failure)
        } catch {
            throw CairnServerError.transport(.other)
        }
        guard (200...299).contains(response.status) else {
            if response.status == 401, let onRevoked {
                await onRevoked()
            }
            throw classify(response)
        }
        return response
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw CairnServerError.malformedResponse
        }
    }

    private func decodeBody<T: Decodable>(_ response: HTTPResponse) throws -> T {
        try decode(response)
    }

    private func classify(_ response: HTTPResponse) -> CairnServerError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: response.body)
        let code = body?.error ?? ""
        switch response.status {
        case 401:
            switch code {
            case "signature_required": return .signatureRequired
            case "bad_manifest_signature": return .badManifestSignature
            default: return .unauthenticated
            }
        case 403:
            return .forbidden(ForbiddenReason(code: code))
        case 400:
            return .badRequest(code: code)
        case 404:
            return .notFound(code: code)
        case 409:
            return .conflict(code: code)
        case 410:
            return .cursorReset
        case 422:
            return .quarantined
        case 429:
            // Two different 429s with different meanings (`sync/v1` §13). `too_many_offers`
            // says the data is fine and this client simply has too many bundles in flight;
            // `rate_limited` says slow down. Collapsing them would make the first look like a
            // server under load and the offload loop back off when it should commit.
            if code == "too_many_offers" { return .tooManyOffers }
            let retryAfter = response.header("Retry-After").flatMap { TimeInterval($0) }
            return .rateLimited(retryAfter: retryAfter)
        case 507:
            // The server's relay answers 507 `quota_exceeded` when a device is out of its
            // storage allowance. It is in the 5xx range and is not a server failure: retrying
            // it with backoff, which is what the 5xx arm below would do, wastes a drive.
            return .quotaExceeded
        case 500...599:
            return .serverFailure(status: response.status)
        default:
            return .unexpected(status: response.status, code: code.isEmpty ? nil : code)
        }
    }

    private func validateHex(_ value: String, label: String) throws {
        guard value.allSatisfy(\.isHexDigit) else {
            throw CairnServerError.invalidArgument(label)
        }
    }
}

// MARK: - Internal wire types

private struct PushWrapper: Encodable {
    var operations: [SyncOperation]
}

private struct ErrorBody: Decodable {
    var error: String
    var message: String?
    var epoch: String?
}

private struct RevokeBody: Decodable {
    var revoked: String?
}
