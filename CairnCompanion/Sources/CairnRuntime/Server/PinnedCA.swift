import CairnKit
import CairnProtocol
import CryptoKit
import Foundation
import Security

/// What the phone will accept as its server's certificate.
///
/// Two addresses, two rules, from `sync/v1` §9:
///
/// - **The LAN listener: pin `server_identity.spki_sha256`**, the SHA-256 of the leaf
///   certificate's SubjectPublicKeyInfo, delivered by the `cairn://configure` QR code and stored
///   at enrolment. Do not rely on the system trust store alone for a private CA.
/// - **The Tailnet URL: validate normally.** The certificate there is Tailscale's ordinary one;
///   pinning it would break at renewal, and disabling validation would be worse than either.
///
/// Never an arbitrary self-signed certificate, on either.
///
/// The old app saved the CA and added it as an anchor without ever checking the pin, so any
/// certificate that CA had signed got through on the same code path. Here the pin is the check
/// and the anchor is only what lets the chain build.
public enum PinnedCA {
    private static let certificateKey = "cairn.pinnedCA.der"
    private static let pinKey = "cairn.pinnedSPKI.sha256"
    private static let lanHostKey = "cairn.lanHost"

    public enum SaveError: Error, Equatable {
        case notACertificate
        case notAPin
    }

    public static var certificate: SecCertificate? {
        guard let der = UserDefaults.standard.data(forKey: certificateKey) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    public static var subjectSummary: String? {
        certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
    }

    /// Lowercase hex, 64 characters. Nil before enrolment.
    public static var spkiPin: String? { UserDefaults.standard.string(forKey: pinKey) }

    /// The host the pin applies to. Everything else validates normally — which is how the
    /// Tailnet URL keeps working when the LAN pin rotates, and the reverse.
    public static var pinnedHost: String? { UserDefaults.standard.string(forKey: lanHostKey) }

    /// What a person can be shown: the first and last eight of the pin, enough to read off the
    /// server's own output and compare, and not enough to be mistaken for a secret.
    public static var pinFingerprint: String? {
        guard let pin = spkiPin, pin.count >= 16 else { return spkiPin }
        return "\(pin.prefix(8))…\(pin.suffix(8))"
    }

    public static func save(der: Data) throws {
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else { throw SaveError.notACertificate }
        UserDefaults.standard.set(der, forKey: certificateKey)
    }

    public static func save(spkiSHA256 pin: String, forHost host: String) throws {
        let normalised = pin.lowercased()
        guard normalised.count == 64, normalised.allSatisfy(\.isHexDigit) else { throw SaveError.notAPin }
        UserDefaults.standard.set(normalised, forKey: pinKey)
        UserDefaults.standard.set(host.lowercased(), forKey: lanHostKey)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: certificateKey)
        UserDefaults.standard.removeObject(forKey: pinKey)
        UserDefaults.standard.removeObject(forKey: lanHostKey)
    }

    /// SHA-256 of a certificate's SubjectPublicKeyInfo, lowercase hex — the thing the contract
    /// calls `spki_sha256`.
    ///
    /// `SecCertificateCopyKey` plus `SecKeyCopyExternalRepresentation` gives the key's bits
    /// *without* the SubjectPublicKeyInfo wrapper, so the DER header for the algorithm has to be
    /// put back before hashing or the digest is of a different thing entirely — and a pin that
    /// never matches looks exactly like a server that cannot be trusted.
    public static func spkiSHA256(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let bits = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }

        let type = (attributes[kSecAttrKeyType] as? String) ?? ""
        let size = attributes[kSecAttrKeySizeInBits] as? Int ?? 0
        guard let header = spkiHeader(type: type, sizeInBits: size) else { return nil }
        return Data(SHA256.hash(data: header + bits)).hexString
    }

    /// The DER prefix of a SubjectPublicKeyInfo, for the key types a Cairn server can present:
    /// P-256, which its own tooling issues, and RSA for a certificate from elsewhere.
    private static func spkiHeader(type: String, sizeInBits: Int) -> Data? {
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        let rsa = kSecAttrKeyTypeRSA as String
        switch (type, sizeInBits) {
        case (ec, 256):
            return Data([
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
            ])
        case (ec, 384):
            return Data([
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
            ])
        case (rsa, 2048):
            return Data([
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7,
                0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00,
            ])
        case (rsa, 4096):
            return Data([
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7,
                0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00,
            ])
        default:
            return nil
        }
    }
}

/// The trust decision, per host.
///
/// Separate from the delegate so the rule — which host gets pinned, and what a missing pin
/// means — is one function a test can ask directly, rather than something only a server can
/// reveal.
public enum ServerTrustRule {
    public enum Decision: Equatable, Sendable {
        /// Validate against the system roots, as for any public certificate.
        case systemTrust
        /// Build the chain with this app's own CA as an anchor, then require the leaf's
        /// SubjectPublicKeyInfo to hash to the pin.
        case pinned(String)
        /// A host this phone has no business trusting.
        case refuse(String)
    }

    /// `host` is the one being connected to; `pinnedHost` and `pin` come from enrolment.
    public static func decide(host: String, pinnedHost: String?, pin: String?) -> Decision {
        let host = host.lowercased()
        // A Tailscale name carries Tailscale's own certificate. Pinning it would break at
        // renewal, and the contract says to validate it normally.
        if host.hasSuffix(".ts.net") { return .systemTrust }
        guard let pinnedHost, pinnedHost == host else {
            // Not the LAN host this phone enrolled with, so nothing is pinned and the system
            // decides — which, for a private CA, means no.
            return .systemTrust
        }
        guard let pin else {
            // The enrolled LAN host with no pin stored is a half-finished enrolment, and
            // trusting it on the system's say-so would quietly undo the point of pinning.
            return .refuse("this phone has no certificate pin for \(host); enrol again")
        }
        return .pinned(pin)
    }
}

/// Evaluates server certificates by `ServerTrustRule`.
final class PinnedCASessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch ServerTrustRule.decide(
            host: challenge.protectionSpace.host,
            pinnedHost: PinnedCA.pinnedHost,
            pin: PinnedCA.spkiPin
        ) {
        case .systemTrust:
            completionHandler(.performDefaultHandling, nil)

        case .refuse:
            completionHandler(.cancelAuthenticationChallenge, nil)

        case .pinned(let pin):
            // The private CA as an anchor is what lets the chain build at all; the SSL policy
            // URLSession attached still checks the host name and the validity dates. The pin is
            // the part that says it is *this* server and not merely one that CA signed.
            if let ca = PinnedCA.certificate {
                SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
            }
            guard SecTrustEvaluateWithError(trust, nil),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  let actual = PinnedCA.spkiSHA256(of: leaf),
                  actual == pin
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

/// The URLSession for every foreground request to the Cairn server, so the trust rule applies
/// everywhere. Background chunk uploads have their own session; see `BackgroundUploader`.
public enum CairnURLSession {
    public static let shared = URLSession(
        configuration: .default, delegate: PinnedCASessionDelegate(), delegateQueue: nil
    )
}
