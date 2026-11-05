import Foundation

/// The `cairn://configure` link a server admin shows as a QR code: the server URL(s), a single-use
/// invitation code and the private CA certificate, so setup is one scan instead of typing a URL,
/// typing a code and installing a profile. Mirrors `configureLink` in cairn-vehicle-server's
/// `cmd/cairn-admin`; change both together.
///
///     cairn://configure?v=1&url=<https>&tailnet=<https>&code=<code>&ca=<DER, base64url, unpadded>
///
/// The link arrives from outside the app (camera, Messages, any app), so it is untrusted input:
/// it only fills in a confirmation sheet and nothing is saved or sent until the user agrees.
public struct ConfigureLink: Equatable, Sendable {
    public let serverURL: String
    public let tailnetURL: String
    public let invitationCode: String
    public let caCertificateDER: Data?

    public enum ParseError: Error, Equatable, Sendable {
        case notAConfigureLink
        case unsupportedVersion
        case invalidServerURL
        case invalidTailnetURL
        case missingInvitationCode
        case malformedCertificate
    }

    public static let version = "1"
    /// A private CA certificate is a few hundred bytes; anything this big is not one.
    static let maxCertificateBytes = 4096

    public init(serverURL: String, tailnetURL: String = "", invitationCode: String, caCertificateDER: Data? = nil) {
        self.serverURL = serverURL
        self.tailnetURL = tailnetURL
        self.invitationCode = invitationCode
        self.caCertificateDER = caCertificateDER
    }

    public var serverHost: String { URL(string: serverURL)?.host ?? serverURL }

    public static func parse(_ url: URL) throws -> ConfigureLink {
        guard url.scheme?.lowercased() == "cairn", url.host?.lowercased() == "configure",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw ParseError.notAConfigureLink }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        guard value("v") == version else { throw ParseError.unsupportedVersion }
        guard let server = value("url"), isHTTPS(server) else { throw ParseError.invalidServerURL }
        let tailnet = value("tailnet")
        if let tailnet, !isHTTPS(tailnet) { throw ParseError.invalidTailnetURL }
        guard let code = value("code")?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            throw ParseError.missingInvitationCode
        }
        var der: Data?
        if let ca = value("ca") {
            // A DER certificate is an ASN.1 SEQUENCE: tag 0x30.
            guard let data = base64URLDecode(ca), data.count <= maxCertificateBytes, data.first == 0x30 else {
                throw ParseError.malformedCertificate
            }
            der = data
        }
        return ConfigureLink(serverURL: server, tailnetURL: tailnet ?? "", invitationCode: code, caCertificateDER: der)
    }

    /// The link for this configuration, as the server builds it.
    public var url: URL {
        var c = URLComponents()
        c.scheme = "cairn"
        c.host = "configure"
        var items = [URLQueryItem(name: "v", value: Self.version), URLQueryItem(name: "url", value: serverURL)]
        if !tailnetURL.isEmpty { items.append(URLQueryItem(name: "tailnet", value: tailnetURL)) }
        items.append(URLQueryItem(name: "code", value: invitationCode))
        if let der = caCertificateDER {
            items.append(URLQueryItem(name: "ca", value: Self.base64URLEncode(der)))
        }
        c.queryItems = items
        return c.url!
    }

    static func isHTTPS(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", let host = u.host, !host.isEmpty else { return false }
        return true
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }
}
