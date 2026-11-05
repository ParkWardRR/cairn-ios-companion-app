import Foundation
import Testing
@testable import CairnProtocol

@Suite struct ConfigureLinkTests {
    // Not a real certificate: a DER SEQUENCE header and some bytes, including ones that
    // base64 renders as '+' and '/' so the URL-safe alphabet is exercised.
    let der = Data([0x30, 0x82, 0x01, 0xfb, 0xff, 0xfe, 0x3e, 0x3f, 0x00])

    @Test func roundTripsEverything() throws {
        let link = ConfigureLink(serverURL: "https://cairn.alpina.casa:8444", tailnetURL: "https://cairn.ts.net",
                                 invitationCode: "a9e6-2d47-954d", caCertificateDER: der)
        let parsed = try ConfigureLink.parse(link.url)
        #expect(parsed == link)
        #expect(parsed.serverHost == "cairn.alpina.casa")
    }

    @Test func parsesTheLinkTheServerBuilds() throws {
        // Shape produced by cmd/cairn-admin's configureLink for a short fake DER.
        let url = URL(string: "cairn://configure?ca=MIIB_g&code=a9e6-2d47&tailnet=https%3A%2F%2Fcairn.ts.net&url=https%3A%2F%2Fcairn.alpina.casa%3A8444&v=1")!
        let parsed = try ConfigureLink.parse(url)
        #expect(parsed.serverURL == "https://cairn.alpina.casa:8444")
        #expect(parsed.tailnetURL == "https://cairn.ts.net")
        #expect(parsed.invitationCode == "a9e6-2d47")
        #expect(parsed.caCertificateDER == Data([0x30, 0x82, 0x01, 0xfe]))
    }

    @Test func optionalPartsMayBeAbsent() throws {
        let parsed = try ConfigureLink.parse(URL(string: "cairn://configure?v=1&url=https%3A%2F%2Fh.lan&code=c")!)
        #expect(parsed.tailnetURL.isEmpty)
        #expect(parsed.caCertificateDER == nil)
    }

    @Test(arguments: [
        ("https://configure?v=1&url=https%3A%2F%2Fh.lan&code=c", ConfigureLink.ParseError.notAConfigureLink),
        ("cairn://other?v=1&url=https%3A%2F%2Fh.lan&code=c", .notAConfigureLink),
        ("cairn://configure?url=https%3A%2F%2Fh.lan&code=c", .unsupportedVersion),
        ("cairn://configure?v=2&url=https%3A%2F%2Fh.lan&code=c", .unsupportedVersion),
        ("cairn://configure?v=1&code=c", .invalidServerURL),
        ("cairn://configure?v=1&url=http%3A%2F%2Fh.lan&code=c", .invalidServerURL),
        ("cairn://configure?v=1&url=h.lan&code=c", .invalidServerURL),
        ("cairn://configure?v=1&url=https%3A%2F%2Fh.lan&tailnet=http%3A%2F%2Ft&code=c", .invalidTailnetURL),
        ("cairn://configure?v=1&url=https%3A%2F%2Fh.lan", .missingInvitationCode),
        ("cairn://configure?v=1&url=https%3A%2F%2Fh.lan&code=%20", .missingInvitationCode),
        ("cairn://configure?v=1&url=https%3A%2F%2Fh.lan&code=c&ca=AAAA", .malformedCertificate),
        ("cairn://configure?v=1&url=https%3A%2F%2Fh.lan&code=c&ca=***", .malformedCertificate),
    ])
    func rejectsWhatItShouldNotTrust(raw: String, expected: ConfigureLink.ParseError) {
        #expect(throws: expected) { try ConfigureLink.parse(URL(string: raw)!) }
    }

    @Test func rejectsAnOversizedCertificate() {
        let big = ConfigureLink(serverURL: "https://h.lan", invitationCode: "c",
                                caCertificateDER: Data([0x30]) + Data(count: ConfigureLink.maxCertificateBytes))
        #expect(throws: ConfigureLink.ParseError.malformedCertificate) { try ConfigureLink.parse(big.url) }
    }
}
