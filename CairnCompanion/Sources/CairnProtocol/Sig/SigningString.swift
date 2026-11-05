import CryptoKit
import Foundation

public enum SigningString {
    public static func build(
        method: String,
        target: String,
        timestamp: Int,
        nonce: String,
        bodyHash: String,
        clientID: String
    ) -> Data {
        let string = """
            CAIRN-SIG-V1
            \(method)
            \(target)
            \(timestamp)
            \(nonce)
            \(bodyHash)
            \(clientID)
            """
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return Data(string.utf8)
    }

    public static func bodyHash(_ body: Data) -> String {
        let digest = SHA256.hash(data: body)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func authorizationHeader(
        clientID: String,
        timestamp: Int,
        nonce: String,
        signatureDER: Data
    ) -> String {
        let sig = signatureDER.base64EncodedString()
        return "Cairn-Sig client=\"\(clientID)\",ts=\"\(timestamp)\",nonce=\"\(nonce)\",sig=\"\(sig)\""
    }

    public static func freshNonce() -> String {
        // The system generator is cryptographically secure and cannot fail silently into an
        // all-zero nonce the way an unchecked SecRandomCopyBytes status could.
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
