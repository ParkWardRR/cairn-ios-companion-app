import Foundation

public enum CanonicalJSON {
    public static func encode(_ value: Any) throws -> Data {
        let string = try encodeValue(value)
        return Data(string.utf8)
    }

    private static func encodeValue(_ value: Any) throws -> String {
        switch value {
        case let n as Int:
            return "\(n)"
        case let n as Int64:
            return "\(n)"
        case let s as String:
            return encodeString(s)
        case let b as Bool:
            return b ? "true" : "false"
        case is NSNull:
            return "null"
        case let arr as [Any]:
            let elements = try arr.map { try encodeValue($0) }
            return "[\(elements.joined(separator: ","))]"
        case let dict as [String: Any]:
            let sorted = dict.keys.sorted()
            let pairs = try sorted.map { key -> String in
                let encodedKey = encodeString(key)
                let encodedValue = try encodeValue(dict[key]!)
                return "\(encodedKey):\(encodedValue)"
            }
            return "{\(pairs.joined(separator: ","))}"
        default:
            throw CanonicalJSONError.unsupportedType(String(describing: type(of: value)))
        }
    }

    private static func encodeString(_ s: String) -> String {
        var result = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case let c where c.value < 0x20:
                result += String(format: "\\u%04x", c.value)
            default:
                result += String(scalar)
            }
        }
        result += "\""
        return result
    }

    public enum CanonicalJSONError: Error {
        case unsupportedType(String)
    }
}
