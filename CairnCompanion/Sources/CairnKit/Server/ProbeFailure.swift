import CairnProtocol
import Foundation

/// Words for a failed reachability probe. A raw "A server with the specified hostname could not be
/// found" says nothing to someone whose only mistake is that Tailscale is off on the phone.
public enum ProbeFailure {
    public static func message(for code: URLError.Code?, tailnet: Bool, fallback: String) -> String {
        guard let code else { return fallback }
        switch code {
        case .cannotFindHost, .dnsLookupFailed:
            return tailnet
                ? "Can't find the Tailnet name. Turn Tailscale on for this phone; it isn't needed while the home network works."
                : "Can't find the server on this network. Are you on the home Wi-Fi?"
        case .timedOut, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost:
            return tailnet
                ? "Can't reach the Tailnet right now. Check that Tailscale is connected on this phone."
                : "The server didn't answer. Are you on the home Wi-Fi, and is the server running?"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "This phone doesn't trust the server's certificate. Scan a Cairn setup QR code from the dashboard."
        default:
            return fallback
        }
    }
}
