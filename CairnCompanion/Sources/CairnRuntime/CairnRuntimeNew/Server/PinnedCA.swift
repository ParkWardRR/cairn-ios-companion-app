import CairnKit
import CairnProtocol
import Foundation
import Security

/// The server's private CA certificate, delivered by the `cairn://configure` QR code. Holding it
/// here means the phone trusts the self-hosted server without installing a configuration profile
/// and enabling it under Certificate Trust Settings. It is only an extra trust anchor for this
/// app's own connections; it does not change what the rest of the phone trusts.
public enum PinnedCA {
    private static let key = "cairn.pinnedCA.der"

    public enum SaveError: Error { case notACertificate }

    public static var certificate: SecCertificate? {
        guard let der = UserDefaults.standard.data(forKey: key) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    public static var subjectSummary: String? {
        certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
    }

    public static func save(der: Data) throws {
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else { throw SaveError.notACertificate }
        UserDefaults.standard.set(der, forKey: key)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Evaluates server certificates against the system roots plus the pinned CA, if one is saved.
///
/// App Transport Security runs its own system-trust check that cannot see an app-supplied
/// anchor, so Info.plist sets NSAllowsArbitraryLoads (project.yml). Trust still comes only from
/// this delegate: the system roots plus the pinned CA, with the host name and dates checked.
final class PinnedCASessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let ca = PinnedCA.certificate
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // The SSL policy URLSession attached still checks the host name and validity dates.
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// The URLSession for every request to the Cairn server, so the pinned CA applies everywhere.
public enum CairnURLSession {
    public static let shared = URLSession(
        configuration: .default, delegate: PinnedCASessionDelegate(), delegateQueue: nil
    )
}
