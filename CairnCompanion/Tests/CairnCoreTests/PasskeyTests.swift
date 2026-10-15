import Foundation
import Testing
@testable import CairnCore

// What the dashboard (@simplewebauthn/server) sends for a sign-in with no named passkey, and for making one.
private let challenge = Data((0..<32).map { UInt8($0) })
private func options(_ extra: String) -> Data {
    Data("""
    {"challengeId":"abc123","options":{"challenge":"\(Base64URL.encode(challenge))",\(extra)}}
    """.utf8)
}

@Suite struct Base64URLTests {
    @Test func roundTripsWithoutPaddingOrUnsafeCharacters() {
        for n in 0..<12 {
            let data = Data((0..<n).map { UInt8(255 - $0) })
            let text = Base64URL.encode(data)
            #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
            #expect(Base64URL.decode(text) == data)
        }
    }
    @Test func decodesWhatWebAuthnProduces() {
        #expect(Base64URL.decode("AQID") == Data([1, 2, 3]))
        #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
    }
}

@Suite struct PasskeyCodecTests {
    @Test func readsASignInRequestWithNoNamedPasskey() throws {
        let r = try PasskeyCodec.signInRequest(from: options(#""rpId":"cairn.example.lan","userVerification":"required""#))
        #expect(r.challengeID == "abc123")
        #expect(r.challenge == challenge)
        #expect(r.rpID == "cairn.example.lan")
        #expect(r.allowedCredentialIDs.isEmpty)
    }

    @Test func readsTheNamedPasskeysOfAnOrdinarySignIn() throws {
        let r = try PasskeyCodec.signInRequest(from: options(#""rpId":"h","allowCredentials":[{"id":"AQID","type":"public-key"}]"#))
        #expect(r.allowedCredentialIDs == [Data([1, 2, 3])])
    }

    @Test func readsACreateRequest() throws {
        let r = try PasskeyCodec.createRequest(from: options(#""rp":{"name":"Cairn","id":"h"},"user":{"id":"BAUG","name":"owner","displayName":"owner"},"excludeCredentials":[{"id":"AQID","type":"public-key"}]"#))
        #expect(r.rpID == "h")
        #expect(r.userID == Data([4, 5, 6]))
        #expect(r.userName == "owner")
        #expect(r.excludedCredentialIDs == [Data([1, 2, 3])])
    }

    @Test func refusesWhatIsMissing() {
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.signInRequest(from: Data("{}".utf8)) }
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.signInRequest(from: options(#""rpId":"""#)) }
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.signInRequest(from: Data(#"{"challengeId":"x","options":{"rpId":"h","challenge":"!!"}}"#.utf8)) }
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.createRequest(from: options(#""rp":{"id":"h"}"#)) }
    }

    @Test func answersASignInInTheShapeTheDashboardVerifies() throws {
        let req = try PasskeyCodec.signInRequest(from: options(#""rpId":"h""#))
        let body = try PasskeyCodec.signInBody(for: req, credentialID: Data([1, 2, 3]), clientDataJSON: Data("cd".utf8), authenticatorData: Data([9, 9]), signature: Data([7]), userHandle: Data([4, 5, 6]))
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["challengeId"] as? String == "abc123")
        let cred = try #require(root["response"] as? [String: Any])
        #expect(cred["id"] as? String == "AQID")
        #expect(cred["rawId"] as? String == "AQID")
        #expect(cred["type"] as? String == "public-key")
        #expect(cred["authenticatorAttachment"] as? String == "platform")
        #expect(cred["clientExtensionResults"] as? [String: Any] != nil)
        let inner = try #require(cred["response"] as? [String: Any])
        #expect(Base64URL.decode(inner["clientDataJSON"] as! String) == Data("cd".utf8))
        #expect(Base64URL.decode(inner["authenticatorData"] as! String) == Data([9, 9]))
        #expect(Base64URL.decode(inner["signature"] as! String) == Data([7]))
        #expect(Base64URL.decode(inner["userHandle"] as! String) == Data([4, 5, 6]))
    }

    @Test func leavesOutAnEmptyUserHandle() throws {
        let req = try PasskeyCodec.signInRequest(from: options(#""rpId":"h""#))
        let body = try PasskeyCodec.signInBody(for: req, credentialID: Data([1]), clientDataJSON: Data([1]), authenticatorData: Data([1]), signature: Data([1]), userHandle: Data())
        let cred = try #require((JSONSerialization.jsonObject(with: body) as? [String: Any])?["response"] as? [String: Any])
        #expect((cred["response"] as? [String: Any])?["userHandle"] == nil)
    }

    @Test func answersACreateWithANameAndTransports() throws {
        let req = try PasskeyCodec.createRequest(from: options(#""rp":{"id":"h"},"user":{"id":"BAUG","name":"owner"}"#))
        let body = try PasskeyCodec.createBody(for: req, name: "Twesh's iPhone", credentialID: Data([1, 2, 3]), clientDataJSON: Data("cd".utf8), attestationObject: Data([0xA1]))
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["name"] as? String == "Twesh's iPhone")
        let cred = try #require(root["response"] as? [String: Any])
        let inner = try #require(cred["response"] as? [String: Any])
        #expect(Base64URL.decode(inner["attestationObject"] as! String) == Data([0xA1]))
        #expect((inner["transports"] as? [String])?.contains("internal") == true)
    }
}

