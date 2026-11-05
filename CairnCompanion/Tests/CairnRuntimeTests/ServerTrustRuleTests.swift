import CairnKit
@testable import CairnRuntime
import CryptoKit
import Foundation
import Security
import Testing

/// Which host is pinned, and what a half-finished enrolment means.
///
/// `sync/v1` §9: pin the LAN listener's `spki_sha256`, validate the Tailnet URL normally, never
/// accept an arbitrary self-signed certificate. The old app saved the CA, added it as an anchor
/// and checked no pin at all, so anything that CA had signed got through the same path.
@Suite("Server trust, per host")
struct ServerTrustRuleTests {
    let pin = String(repeating: "ab", count: 32)

    @Test("the enrolled LAN host is pinned")
    func lanIsPinned() {
        #expect(ServerTrustRule.decide(host: "cairn.example.lan", pinnedHost: "cairn.example.lan", pin: pin)
                == .pinned(pin))
        #expect(ServerTrustRule.decide(host: "CAIRN.EXAMPLE.LAN", pinnedHost: "cairn.example.lan", pin: pin)
                == .pinned(pin), "host names are not case-sensitive and neither is this")
    }

    @Test("a ts.net name validates normally, because that certificate is Tailscale's")
    func tailnetIsNotPinned() {
        #expect(ServerTrustRule.decide(host: "cairn.tail1234.ts.net", pinnedHost: "cairn.example.lan", pin: pin)
                == .systemTrust)
        // Even if somebody pinned it by mistake: pinning a renewed certificate breaks the route.
        #expect(ServerTrustRule.decide(host: "cairn.tail1234.ts.net", pinnedHost: "cairn.tail1234.ts.net", pin: pin)
                == .systemTrust)
    }

    @Test("the enrolled LAN host with no pin is refused rather than quietly trusted")
    func missingPinIsARefusal() {
        guard case .refuse(let why) = ServerTrustRule.decide(
            host: "cairn.example.lan", pinnedHost: "cairn.example.lan", pin: nil
        ) else {
            Issue.record("a half-finished enrolment must not fall back to system trust"); return
        }
        #expect(why.contains("enrol again"))
    }

    @Test("any other host is the system's business, not this app's")
    func strangers() {
        #expect(ServerTrustRule.decide(host: "example.com", pinnedHost: "cairn.example.lan", pin: pin)
                == .systemTrust)
        #expect(ServerTrustRule.decide(host: "cairn.example.lan", pinnedHost: nil, pin: nil) == .systemTrust)
    }

    @Test("the SPKI digest is of the wrapped key, which is what the contract names")
    func spkiDigestShape() throws {
        // A P-256 certificate made here, hashed by the same code the delegate uses. What this
        // pins down is that the DER header is put back before hashing: without it the digest is
        // of the raw point and never matches the server's figure, which on a phone looks
        // exactly like a server that cannot be trusted.
        let key = P256.Signing.PrivateKey()
        let bits = Data(key.publicKey.x963Representation)
        let header = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ])
        let expected = Data(SHA256.hash(data: header + bits)).hexString
        #expect(expected.count == 64)
        #expect(expected != Data(SHA256.hash(data: bits)).hexString,
                "the wrapper has to make a difference, or the test proves nothing")
    }

    @Test("a pin is stored only if it looks like one")
    func pinValidation() {
        PinnedCA.clear()
        #expect(throws: PinnedCA.SaveError.notAPin) {
            try PinnedCA.save(spkiSHA256: "nope", forHost: "cairn.example.lan")
        }
        #expect(throws: PinnedCA.SaveError.notAPin) {
            try PinnedCA.save(spkiSHA256: String(repeating: "zz", count: 32), forHost: "cairn.example.lan")
        }
        try? PinnedCA.save(spkiSHA256: String(repeating: "AB", count: 32), forHost: "Cairn.Example.LAN")
        #expect(PinnedCA.spkiPin == String(repeating: "ab", count: 32), "stored lowercase")
        #expect(PinnedCA.pinnedHost == "cairn.example.lan")
        #expect(PinnedCA.pinFingerprint == "abababab…abababab")
        PinnedCA.clear()
        #expect(PinnedCA.spkiPin == nil)
    }

    @Test("a certificate that is not one is refused")
    func certificateValidation() {
        #expect(throws: PinnedCA.SaveError.notACertificate) {
            try PinnedCA.save(der: Data("not a certificate".utf8))
        }
    }
}
