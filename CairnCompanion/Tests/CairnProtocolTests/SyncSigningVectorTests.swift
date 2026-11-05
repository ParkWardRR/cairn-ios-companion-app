@testable import CairnProtocol
import CryptoKit
import Foundation
import Testing

/// Replays `contracts/sync/v1/vectors/vectors.json` against this app's request builder: the
/// signing string, the body hash, the Authorization header and the enrolment proof.
///
/// The exchange timeline — the eighty-odd steps with their recorded responses — is replayed in
/// CairnKitTests/ExchangeVectorTests, which needs the server client. These are the pieces the
/// protocol target owns on its own.

private func publicKey(_ x963Hex: String) -> P256.Signing.PublicKey {
    try! P256.Signing.PublicKey(x963Representation: Data(hex: x963Hex))
}

private func privateKey(_ scalarHex: String) -> P256.Signing.PrivateKey {
    try! P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalarHex))
}

/// A signer for the test keys. The real one lives in CairnKit beside the key store; what is
/// being checked here is the string, not who signs it.
private struct TestSigner {
    let clientID: String
    let privateKey: P256.Signing.PrivateKey
    var publicKeyX963: Data { Data(privateKey.publicKey.x963Representation) }
    func sign(_ data: Data) throws -> Data { try privateKey.signature(for: data).derRepresentation }
}

private func verifies(_ derBase64: String, over message: Data, key: P256.Signing.PublicKey) -> Bool {
    guard let der = Data(base64Encoded: derBase64),
          let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else { return false }
    return key.isValidSignature(signature, for: message)
}

/// `Cairn-Sig client="..",ts="..",nonce="..",sig=".."` -> its four fields.
private func parseAuthorization(_ header: String) -> [String: String]? {
    let prefix = "Cairn-Sig "
    guard header.hasPrefix(prefix) else { return nil }
    var fields: [String: String] = [:]
    for part in header.dropFirst(prefix.count).split(separator: ",") {
        guard let eq = part.firstIndex(of: "=") else { return nil }
        let key = String(part[..<eq])
        var value = String(part[part.index(after: eq)...])
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
        value = String(value.dropFirst().dropLast())
        fields[key] = value
    }
    return fields
}

@Suite struct SyncSigningVectorTests {
    private let vectors = Contracts.json("sync/v1/vectors/vectors.json")

    @Test func signingStringsAndHeaders() throws {
        let key = vectors["test_key"] as! [String: String]
        let pub = publicKey(key["public_key_x963_hex"]!)
        let signer = TestSigner(clientID: key["client_id"]!, privateKey: privateKey(key["private_scalar_hex"]!))
        #expect(signer.publicKeyX963 == Data(hex: key["public_key_x963_hex"]!))

        let cases = vectors["signing"] as! [[String: Any]]
        #expect(cases.count >= 4)
        for c in cases {
            let name = c["name"] as! String
            let body = Data(hex: c["body_hex"] as! String)
            #expect(SigningString.bodyHash(body) == c["body_sha256"] as? String, "\(name): body hash")

            let string = SigningString.build(
                method: c["method"] as! String, target: c["request_target"] as! String,
                timestamp: Int(c["ts"] as! String)!, nonce: c["nonce"] as! String,
                bodyHash: SigningString.bodyHash(body), clientID: signer.clientID)
            #expect(String(decoding: string, as: UTF8.self) == c["signing_string"] as? String, "\(name): signing string")

            // The server's signature verifies under the test key, and so does ours (randomised, so verify).
            let theirs = c["signature_der_base64"] as! String
            #expect(verifies(theirs, over: string, key: pub), "\(name): recorded signature")
            let ours = try signer.sign(string).base64EncodedString()
            #expect(verifies(ours, over: string, key: pub), "\(name): our signature")

            let header = SigningString.authorizationHeader(
                clientID: signer.clientID, timestamp: Int(c["ts"] as! String)!, nonce: c["nonce"] as! String,
                signatureDER: Data(base64Encoded: theirs)!)
            #expect(header == c["authorization_header"] as? String, "\(name): header")
        }
    }

    @Test func enrolmentProof() throws {
        let key = vectors["test_key"] as! [String: String]
        let pub = publicKey(key["public_key_x963_hex"]!)
        let enrol = vectors["enrolment"] as! [String: String]
        let message = EnrolmentProof.message(code: enrol["code"]!, publicKeyHex: enrol["public_key_hex"]!)
        #expect(String(decoding: message, as: UTF8.self) == enrol["proof_message"])
        #expect(verifies(enrol["proof_der_base64"]!, over: message, key: pub))
    }
}
