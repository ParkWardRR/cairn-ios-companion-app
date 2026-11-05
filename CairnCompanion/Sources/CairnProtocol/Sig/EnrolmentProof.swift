import Foundation

public enum EnrolmentProof {
    /// Dashes and case are ignored (spec section 3): the 32 lowercase hex characters the server keys on.
    public static func normalizedCode(_ code: String) -> String {
        code.lowercased().replacingOccurrences(of: "-", with: "")
    }

    public static func message(code: String, publicKeyHex: String) -> Data {
        let string = "CAIRN-ENROLL-V1\n\(normalizedCode(code))\n\(publicKeyHex)"
        return Data(string.utf8)
    }
}
