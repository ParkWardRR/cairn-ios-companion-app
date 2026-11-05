import Foundation
import Testing
@testable import CairnKit
@testable import CairnProtocol

@Suite struct ProbeFailureTests {
    @Test func aMissingTailnetNameSaysToTurnTailscaleOn() {
        let text = ProbeFailure.message(for: .cannotFindHost, tailnet: true, fallback: "raw")
        #expect(text.contains("Turn Tailscale on"))
        #expect(text.contains("isn't needed while the home network works"))
        #expect(ProbeFailure.message(for: .dnsLookupFailed, tailnet: true, fallback: "raw") == text)
    }

    @Test func theSameFailureOnTheLANPointsAtTheWiFi() {
        #expect(ProbeFailure.message(for: .cannotFindHost, tailnet: false, fallback: "raw").contains("home Wi-Fi"))
        #expect(ProbeFailure.message(for: .timedOut, tailnet: false, fallback: "raw").contains("home Wi-Fi"))
    }

    @Test func aTailnetTimeoutPointsAtTailscaleBeingConnected() {
        #expect(ProbeFailure.message(for: .timedOut, tailnet: true, fallback: "raw").contains("Tailscale is connected"))
    }

    @Test func certificateProblemsPointAtTheSetupCode() {
        for code in [URLError.Code.serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasUnknownRoot] {
            #expect(ProbeFailure.message(for: code, tailnet: false, fallback: "raw").contains("setup QR code"))
        }
    }

    @Test func anythingElseKeepsTheSystemsOwnWords() {
        #expect(ProbeFailure.message(for: .badURL, tailnet: true, fallback: "raw") == "raw")
        #expect(ProbeFailure.message(for: nil, tailnet: false, fallback: "raw") == "raw")
    }
}
