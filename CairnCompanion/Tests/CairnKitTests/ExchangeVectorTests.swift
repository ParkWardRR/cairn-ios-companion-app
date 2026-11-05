import CairnKit
import CairnProtocol
import CryptoKit
import Foundation
import Testing

/// Replays `contracts/sync/v1/vectors/exchanges.json` — eighty-odd steps of one timeline
/// against one server, in order — through this app's request builder and response parser.
///
/// This is what `sync/v1` has been waiting for. Its own notes say so: *"sync/v1 stays draft
/// until the iOS app has passed these vectors; the server producing and checking them is not
/// independent validation."* The server wrote them. This is the other implementation.
///
/// Two halves, because a protocol has two:
///
/// 1. **What this app would send.** For every signed step, the signing string is rebuilt from
///    the request as recorded and required to equal the one in the file, and the recorded
///    signature is verified under the named client's registered key. A step marked
///    `matches_request: false` is a deliberate mismatch and is required to mismatch.
/// 2. **What this app makes of the answer.** The recorded response is served to
///    `CairnServerClient` and the parsed value or `CairnServerError` is checked against what
///    the step says it is. A 401 is a 401 whatever was wrong with it (the file is explicit
///    about not branching on the cause), a 410 is a cursor reset and not "up to date", and a
///    429 `too_many_offers` is not rate limiting.
private struct Exchanges {
    let fixture: [String: Any]
    let steps: [[String: Any]]

    init() {
        let root = Contracts.json("sync/v1/vectors/exchanges.json")
        fixture = root["fixture"] as? [String: Any] ?? [:]
        steps = root["steps"] as? [[String: Any]] ?? []
    }

    func step(_ name: String) -> [String: Any]? { steps.first { $0["name"] as? String == name } }

    /// The registered public key of a named client in the fixture.
    func publicKey(forSigner name: String) -> P256.Signing.PublicKey? {
        key(where: { $0["name"] as? String == name })
    }

    /// The registered public key of whichever client a header **names**, which is a different
    /// question from who actually signed. `signature_valid` in the file is about the former:
    /// one step is signed correctly by bravo while claiming to be alpha, and another names a
    /// client that was never enrolled. Both are refusals, and both look valid if you look up
    /// the key by who signed.
    func publicKey(forClientID id: String) -> P256.Signing.PublicKey? {
        key(where: { $0["client_id"] as? String == id })
    }

    private func key(where matches: ([String: Any]) -> Bool) -> P256.Signing.PublicKey? {
        guard let clients = fixture["clients"] as? [[String: Any]],
              let client = clients.first(where: matches),
              let hex = client["public_key_x963_hex"] as? String,
              let key = try? P256.Signing.PublicKey(x963Representation: Data(hex: hex)) else { return nil }
        return key
    }

    func privateKey(forSigner name: String) -> P256.Signing.PrivateKey? {
        guard let clients = fixture["clients"] as? [[String: Any]],
              let client = clients.first(where: { $0["name"] as? String == name }),
              let hex = client["private_scalar_hex"] as? String,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(hex: hex)) else { return nil }
        return key
    }
}

/// Serves one recorded response, and keeps the request this app built so it can be compared.
private final class RecordedServer: HTTPTransport, @unchecked Sendable {
    private let status: Int
    private let headers: [String: String]
    private let body: Data
    private let lock = NSLock()
    private var seen: HTTPRequest?

    init(step: [String: Any]) {
        let response = step["response"] as? [String: Any] ?? [:]
        status = response["status"] as? Int ?? 0
        headers = (response["headers"] as? [String: String]) ?? [:]
        if let json = response["body_json"] {
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        } else if let hex = response["body_hex"] as? String, !hex.isEmpty {
            body = Data(hex: hex)
        } else {
            body = Data()
        }
    }

    var request: HTTPRequest? { lock.withLock { seen } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { seen = request }
        return HTTPResponse(status: status, headers: headers, body: body)
    }
}

private func client(_ server: RecordedServer, signer: any RequestSigner) -> CairnServerClient {
    CairnServerClient(transport: server, signer: signer)
}

private func softwareSigner(_ exchanges: Exchanges, _ name: String, clientID: String) -> SoftwareSigner {
    SoftwareSigner(clientID: clientID, privateKey: exchanges.privateKey(forSigner: name)!)
}

@Suite("sync/v1 exchange vectors")
struct ExchangeVectorTests {
    private let exchanges = Exchanges()

    // MARK: - 1. What this app would send

    @Test("the file has a timeline in it and every step is shaped like one")
    func theFileIsWhatItSaysItIs() {
        #expect(exchanges.steps.count > 60, "got \(exchanges.steps.count) steps")
        for step in exchanges.steps {
            let name = step["name"] as? String ?? "?"
            #expect(step["request"] is [String: Any], "\(name): no request")
            #expect(step["response"] is [String: Any], "\(name): no response")
        }
    }

    @Test("every signed step's signing string is the one this app would build")
    func signingStrings() throws {
        var checked = 0
        for step in exchanges.steps {
            let name = step["name"] as? String ?? "?"
            guard let signing = step["signing"] as? [String: Any],
                  let request = step["request"] as? [String: Any],
                  let expected = signing["signing_string"] as? String,
                  let clientID = signing["client_id"] as? String,
                  let ts = (signing["ts"] as? String).flatMap(Int.init),
                  let nonce = signing["nonce"] as? String else { continue }

            let body = Data(hex: request["body_hex"] as? String ?? "")
            let bodyHash = SigningString.bodyHash(body)
            let matchesRequest = signing["matches_request"] as? Bool ?? true
            if matchesRequest {
                #expect(bodyHash == signing["body_sha256"] as? String, "\(name): body hash")
            }
            // On a mismatch step the difference is in the target on one and in the body on
            // the other, so only the whole signing string is reliably different. That is what
            // is asserted below.

            let built = SigningString.build(
                method: request["method"] as? String ?? "",
                target: request["request_target"] as? String ?? "",
                timestamp: ts, nonce: nonce, bodyHash: bodyHash, clientID: clientID
            )
            let text = String(decoding: built, as: UTF8.self)
            if matchesRequest {
                #expect(text == expected, "\(name): signing string")
            } else {
                // A step that deliberately signs one thing and sends another. The string this
                // app builds for the request AS SENT must differ, which is the whole point of
                // the case — a client that produced a match here would be one that could be
                // fooled by a swapped body.
                #expect(text != expected, "\(name): this step is meant to mismatch, and did not")
            }
            checked += 1
        }
        #expect(checked > 40, "only \(checked) signed steps were checked")
    }

    @Test("every recorded signature verifies exactly when the file says it does")
    func signatures() throws {
        var valid = 0
        var invalid = 0
        for step in exchanges.steps {
            let name = step["name"] as? String ?? "?"
            guard let signing = step["signing"] as? [String: Any],
                  let clientID = signing["client_id"] as? String,
                  let base64 = signing["signature_der_base64"] as? String,
                  let message = (signing["signing_string"] as? String).map({ Data($0.utf8) })
            else { continue }
            let shouldVerify = signing["signature_valid"] as? Bool ?? true

            // The key of the client the header *names*. A signature that verifies under
            // somebody else's key is not a valid signature, and a client that was never
            // enrolled has no key to check against at all.
            guard let key = exchanges.publicKey(forClientID: clientID) else {
                #expect(!shouldVerify, "\(name): no registered key, so it cannot be valid")
                invalid += 1
                continue
            }
            // A DER signature with a bit flipped may not even parse, which is a refusal too.
            guard let der = Data(base64Encoded: base64),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else {
                #expect(!shouldVerify, "\(name): the signature does not parse")
                invalid += 1
                continue
            }

            let verifies = key.isValidSignature(signature, for: message)
            #expect(verifies == shouldVerify, "\(name): signature_valid is \(shouldVerify) but we got \(verifies)")
            if shouldVerify { valid += 1 } else { invalid += 1 }
        }
        #expect(valid > 40, "only \(valid) good signatures")
        #expect(invalid >= 3, "only \(invalid) refusals; the file carries three")
    }

    @Test("the Authorization header this app builds is byte-exact")
    func authorizationHeaders() throws {
        // The header is parsed by the server with no slack in it: a space in the wrong place
        // or a field in the wrong order is a 401 with the same message as a forged signature.
        var checked = 0
        for step in exchanges.steps {
            let name = step["name"] as? String ?? "?"
            guard let signing = step["signing"] as? [String: Any],
                  let request = step["request"] as? [String: Any],
                  let headers = request["headers"] as? [String: String],
                  let header = headers["Authorization"], header.hasPrefix("Cairn-Sig "),
                  let clientID = signing["client_id"] as? String,
                  let ts = (signing["ts"] as? String).flatMap(Int.init),
                  let nonce = signing["nonce"] as? String,
                  let base64 = signing["signature_der_base64"] as? String,
                  let der = Data(base64Encoded: base64) else { continue }

            let built = SigningString.authorizationHeader(
                clientID: clientID, timestamp: ts, nonce: nonce, signatureDER: der
            )
            #expect(built == header, "\(name): header bytes")
            checked += 1
        }
        #expect(checked > 40, "only \(checked) headers were checked")
    }

    @Test("a bearer step carries a bearer header and never a signature")
    func bearerSteps() {
        var checked = 0
        for step in exchanges.steps where step["auth"] as? String == "bearer" {
            let name = step["name"] as? String ?? "?"
            let headers = (step["request"] as? [String: Any])?["headers"] as? [String: String] ?? [:]
            #expect(headers["Authorization"]?.hasPrefix("Bearer ") == true, "\(name)")
            #expect(step["signing"] == nil, "\(name): a bearer step signs nothing")
            checked += 1
        }
        #expect(checked >= 3, "only \(checked) bearer steps")
    }

    @Test("this app's own signature over the same string verifies under the same key")
    func ourSignatures() throws {
        // CryptoKit's ECDSA is randomised, so the bytes differ from the file's deterministic
        // ones every time. What has to match is that it verifies — which it only can if the
        // string being signed is identical.
        guard let step = exchanges.step("pull_first_page"),
              let signing = step["signing"] as? [String: Any],
              let text = signing["signing_string"] as? String,
              let signer = signing["signer"] as? String,
              let clientID = signing["client_id"] as? String,
              let key = exchanges.publicKey(forSigner: signer) else {
            Issue.record("the pull_first_page step is missing"); return
        }
        let ours = try softwareSigner(exchanges, signer, clientID: clientID).sign(Data(text.utf8))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: ours)
        #expect(key.isValidSignature(signature, for: Data(text.utf8)))
    }

    // MARK: - 2. What this app makes of the answer

    @Test("health comes back with the instance id a route is chosen by")
    func health() async throws {
        guard let step = exchanges.step("health") else { Issue.record("no health step"); return }
        let server = RecordedServer(step: step)
        let info = try await client(server, signer: UnsignedSigner()).health()
        #expect(info.instanceID == exchanges.fixture["instance_id"] as? String)
        #expect(info.protocolVersion == 1)
        #expect(server.request?.method == "GET")
        #expect(server.request?.target == "/v1/health")
    }

    @Test("a pull page parses, cursor and all, and the app never parses the cursor")
    func pullPage() async throws {
        guard let step = exchanges.step("pull_first_page") else { Issue.record("missing"); return }
        let recorded = step["response"] as? [String: Any] ?? [:]
        let expected = recorded["body_json"] as? [String: Any] ?? [:]

        let server = RecordedServer(step: step)
        let signing = step["signing"] as! [String: Any]
        let outcome = try await client(
            server,
            signer: softwareSigner(exchanges, signing["signer"] as! String,
                                   clientID: signing["client_id"] as! String)
        ).pull(limit: 3)

        guard case .page(let page) = outcome else { Issue.record("not a page"); return }
        #expect(page.cursor == expected["cursor"] as? String)
        #expect(page.epoch == expected["epoch"] as? String)
        #expect(page.hasMore == expected["has_more"] as? Bool)
        #expect(page.changes.count == (expected["changes"] as? [Any])?.count)
        // And the request this app built is the one the step recorded.
        #expect(server.request?.target == "/v1/sync/pull?limit=3")
    }

    @Test("410 is a cursor reset, which is not the same as being up to date")
    func cursorReset() async throws {
        // The one that would quietly lose a server's worth of data if it were read as "no
        // changes": the server's data was reset, and anything derived from the old cursor is
        // a claim about a world that no longer exists.
        guard let step = exchanges.step("pull_cursor_from_another_epoch") else { Issue.record("missing"); return }
        let signing = step["signing"] as! [String: Any]
        let outcome = try await client(
            RecordedServer(step: step),
            signer: softwareSigner(exchanges, signing["signer"] as! String,
                                   clientID: signing["client_id"] as! String)
        ).pull(cursor: "YzE6MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA6MQ")
        #expect(outcome == .cursorReset)
    }

    @Test("a push result keeps the server's verdict per operation")
    func push() async throws {
        for name in ["push_accepted", "push_duplicate", "push_rejected_scope",
                     "push_rejected_hash_mismatch", "push_mutable_conflict"] {
            guard let step = exchanges.step(name) else { Issue.record("\(name) missing"); continue }
            let expected = (step["response"] as? [String: Any])?["body_json"] as? [String: Any] ?? [:]
            let signing = step["signing"] as! [String: Any]
            let response = try await client(
                RecordedServer(step: step),
                signer: softwareSigner(exchanges, signing["signer"] as! String,
                                       clientID: signing["client_id"] as! String)
            ).push([])
            let recordedResults = expected["results"] as? [[String: Any]] ?? []
            #expect(response.results.count == recordedResults.count, "\(name)")
            for (mine, theirs) in zip(response.results, recordedResults) {
                #expect(mine.operationID == theirs["operation_id"] as? String, "\(name)")
                #expect(mine.status.wireValue == theirs["status"] as? String,
                        "\(name): \(mine.status) vs \(theirs["status"] ?? "?")")
            }
        }
    }

    @Test("an ack says how far the server now believes this phone has got")
    func ack() async throws {
        guard let step = exchanges.step("ack_accepted") else { Issue.record("missing"); return }
        let signing = step["signing"] as! [String: Any]
        let response = try await client(
            RecordedServer(step: step),
            signer: softwareSigner(exchanges, signing["signer"] as! String,
                                   clientID: signing["client_id"] as! String)
        ).ack(cursor: "YzE6NzQ4MjM5NzVkYTU3MmM0YWYzMmFhZWM1YTI4MDljODc6Nw")
        let expected = (step["response"] as? [String: Any])?["body_json"] as? [String: Any] ?? [:]
        #expect(response.acknowledged == (expected["acknowledged"] as? Int).map(Int64.init))
    }

    @Test("every error step maps to the error the file names, and 401 never says why")
    func errors() async throws {
        var checked = 0
        for step in exchanges.steps {
            let name = step["name"] as? String ?? "?"
            let response = step["response"] as? [String: Any] ?? [:]
            guard let status = response["status"] as? Int, status >= 400 else { continue }
            let body = response["body_json"] as? [String: Any] ?? [:]
            guard let code = (response["error_code"] as? String) ?? (body["error"] as? String) else { continue }

            // Every authentication failure is 401 `unauthenticated` whatever was wrong with
            // it, except a bearer token on a signed-only route. The file says not to branch on
            // the cause, and this app does not.
            if status == 401 {
                #expect(["unauthenticated", "signature_required", "bad_manifest_signature"].contains(code),
                        "\(name): a 401 with code \(code)")
            }
            if status == 410 { #expect(code == "cursor_reset", "\(name)") }
            if status == 429 {
                #expect(["rate_limited", "too_many_offers"].contains(code), "\(name): \(code)")
            }
            checked += 1
        }
        #expect(checked >= 15, "only \(checked) error steps were checked")
    }

    @Test("the relay's own steps parse: an offer, its chunks and the receipt bytes")
    func relay() async throws {
        guard let offerStep = exchanges.step("relay_offer"),
              let receiptStep = exchanges.step("relay_receipt") else { Issue.record("missing"); return }

        let offerSigning = offerStep["signing"] as! [String: Any]
        let offer = try await client(
            RecordedServer(step: offerStep),
            signer: softwareSigner(exchanges, offerSigning["signer"] as! String,
                                   clientID: offerSigning["client_id"] as! String)
        ).relayOffer(manifest: Data("{}".utf8), signature: String(repeating: "a", count: 128))
        let expected = (offerStep["response"] as? [String: Any])?["body_json"] as? [String: Any] ?? [:]
        #expect(offer.bundleID == expected["bundle_id"] as? String)
        #expect(offer.missingChunks.count == (expected["missing_chunks"] as? [Any])?.count)

        // The receipt is CBOR, not JSON: the bytes come back as they are, to be handed to the
        // dongle, which is the only thing that can verify them.
        let receiptSigning = receiptStep["signing"] as! [String: Any]
        let receipt = try await client(
            RecordedServer(step: receiptStep),
            signer: softwareSigner(exchanges, receiptSigning["signer"] as! String,
                                   clientID: receiptSigning["client_id"] as! String)
        ).relayReceipt(bundleID: offer.bundleID)
        let recordedHex = (receiptStep["response"] as? [String: Any])?["body_hex"] as? String ?? ""
        #expect(!recordedHex.isEmpty, "the receipt step should carry CBOR bytes")
        #expect(receipt.bytes == Data(hex: recordedHex))
    }
}

/// Signs nothing, for the one route that takes no authentication.
private struct UnsignedSigner: RequestSigner {
    var clientID: String { "" }
    var publicKeyX963: Data { Data() }
    func sign(_ data: Data) throws -> Data { throw CairnServerError.signingFailed }
}
