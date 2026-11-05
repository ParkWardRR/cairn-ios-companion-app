import CairnProtocol
import CryptoKit
import Foundation
import Testing

@Suite("EnrolmentProof")
struct EnrolmentProofTests {
    @Test func proofMessageFormat() {
        let msg = EnrolmentProof.message(
            code: "ABCD-1234-EF56-7890-ABCD-1234-EF56-7890",
            publicKeyHex: "04deadbeef"
        )
        let expected = "CAIRN-ENROLL-V1\nabcd1234ef567890abcd1234ef567890\n04deadbeef"
        #expect(String(data: msg, encoding: .utf8) == expected)
    }

    @Test func codeNormalizesCase() {
        let msg = EnrolmentProof.message(code: "AABB", publicKeyHex: "04ff")
        let str = String(data: msg, encoding: .utf8)!
        #expect(str.contains("aabb"))
    }

    @Test func proofSignsAndVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let msg = EnrolmentProof.message(
            code: "deadbeef1234",
            publicKeyHex: Data(key.publicKey.x963Representation).hexString
        )
        let sig = try key.signature(for: msg)
        #expect(key.publicKey.isValidSignature(sig, for: msg))
    }
}

@Suite("SigningString")
struct SigningStringTests {
    @Test func buildFormat() {
        let data = SigningString.build(
            method: "POST",
            target: "/v1/sync/push",
            timestamp: 1700000000,
            nonce: "aabbccdd00112233aabbccdd00112233",
            bodyHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            clientID: "client_abc123"
        )
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        #expect(lines.count == 7)
        #expect(lines[0] == "CAIRN-SIG-V1")
        #expect(lines[1] == "POST")
        #expect(lines[2] == "/v1/sync/push")
        #expect(lines[3] == "1700000000")
        #expect(lines[4] == "aabbccdd00112233aabbccdd00112233")
        #expect(lines[6] == "client_abc123")
    }

    @Test func emptyBodyHash() {
        let hash = SigningString.bodyHash(Data())
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func authorizationHeaderFormat() {
        let header = SigningString.authorizationHeader(
            clientID: "c1",
            timestamp: 12345,
            nonce: "aabb",
            signatureDER: Data([0x30, 0x06])
        )
        #expect(header.hasPrefix("Cairn-Sig client=\"c1\""))
        #expect(header.contains("ts=\"12345\""))
        #expect(header.contains("nonce=\"aabb\""))
        #expect(header.contains("sig=\""))
    }

    @Test func freshNonceIs32Hex() {
        let nonce = SigningString.freshNonce()
        #expect(nonce.count == 32)
        #expect(nonce.allSatisfy { $0.isHexDigit })
    }

    @Test func twoNoncesDiffer() {
        #expect(SigningString.freshNonce() != SigningString.freshNonce())
    }

    /// The signer itself lives in CairnKit, next to the key store. What matters here is that
    /// what this target builds is a signable, verifiable message, which is pure P-256.
    @Test func signAndVerifyRoundTrip() throws {
        let key = P256.Signing.PrivateKey()
        let body = Data("hello".utf8)
        let msg = SigningString.build(
            method: "POST",
            target: "/v1/sync/push",
            timestamp: 1700000000,
            nonce: SigningString.freshNonce(),
            bodyHash: SigningString.bodyHash(body),
            clientID: "test-client"
        )
        let sig = try key.signature(for: msg)
        #expect(key.publicKey.isValidSignature(sig, for: msg))
    }
}

@Suite("CanonicalJSON")
struct CanonicalJSONTests {
    @Test func sortedKeys() throws {
        let dict: [String: Any] = ["z": 1, "a": 2, "m": 3]
        let data = try CanonicalJSON.encode(dict)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "{\"a\":2,\"m\":3,\"z\":1}")
    }

    @Test func integersOnly() throws {
        let dict: [String: Any] = ["n": 42]
        let data = try CanonicalJSON.encode(dict)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "{\"n\":42}")
    }

    @Test func nestedObjects() throws {
        let dict: [String: Any] = ["a": ["b": 1, "a": 2]]
        let data = try CanonicalJSON.encode(dict)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "{\"a\":{\"a\":2,\"b\":1}}")
    }

    @Test func arrays() throws {
        let arr: [Any] = [1, "two", 3]
        let data = try CanonicalJSON.encode(arr)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "[1,\"two\",3]")
    }

    @Test func boolAndNull() throws {
        let dict: [String: Any] = ["a": true, "b": false, "c": NSNull()]
        let data = try CanonicalJSON.encode(dict)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "{\"a\":true,\"b\":false,\"c\":null}")
    }

    @Test func stringEscaping() throws {
        let dict: [String: Any] = ["s": "hello\nworld\"\\"]
        let data = try CanonicalJSON.encode(dict)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "{\"s\":\"hello\\nworld\\\"\\\\\"}")
    }

    @Test func literalUnicode() throws {
        let dict: [String: Any] = ["emoji": "\u{1F600}"]
        let data = try CanonicalJSON.encode(dict)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("\u{1F600}"))
        #expect(!str.contains("\\u"))
    }

    @Test func rejectsFloat() throws {
        let dict: [String: Any] = ["bad": 3.14]
        #expect(throws: CanonicalJSON.CanonicalJSONError.self) {
            try CanonicalJSON.encode(dict)
        }
    }
}
