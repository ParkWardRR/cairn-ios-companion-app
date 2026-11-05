import Foundation

/// One failure, with the number the radio actually gave.
///
/// The audit's first finding was that a pairing failure reached the old app as a plain
/// disconnect. Every delegate call that can carry an error turns into one of these instead, and
/// the domain and the code survive all the way to the Dongle screen and the exported log — so a
/// bench run can be set beside the dongle's serial output and say which side refused.
public struct LinkFailure: Equatable, Sendable, Hashable, CustomStringConvertible {
    /// `NSError.domain`: `CBATTErrorDomain`, `CBErrorDomain`, or whatever else iOS hands over.
    public let domain: String
    public let code: Int
    /// `localizedDescription`, or a sentence the machine wrote when the failure is its own.
    public let message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    /// `CBATTErrorDomain#5 Authentication is insufficient.` — a log line you can grep for.
    public var description: String { "\(domain)#\(code) \(message)" }

    /// `ATT 5` or `CB 14`, short enough for the Dongle screen's "last error" row.
    public var shortCode: String {
        switch domain {
        case Self.attDomain: "ATT \(code)"
        case Self.cbDomain: "CB \(code)"
        default: "\(domain)#\(code)"
        }
    }

    // CoreBluetooth's two domains, spelled out because `CairnKit` imports no Apple framework.
    // `CairnRuntimeTests` asserts these strings and every code below against CoreBluetooth
    // itself, so a constant that drifts fails a test rather than a bench run.
    public static let attDomain = "CBATTErrorDomain"
    public static let cbDomain = "CBErrorDomain"
    /// Failures the machine raised itself rather than read off an `NSError`.
    public static let cairnDomain = "CairnLinkDomain"

    /// `CBATTError` codes this app reasons about.
    public enum ATT: Int, Sendable {
        case insufficientAuthentication = 5
        case insufficientEncryptionKeySize = 12
        case insufficientEncryption = 15
    }

    /// `CBError` codes this app reasons about.
    public enum CB: Int, Sendable {
        case connectionTimeout = 6
        case peripheralDisconnected = 7
        case connectionFailed = 10
        /// iOS noticed the dongle no longer recognises this phone's bond keys.
        case peerRemovedPairingInformation = 14
        case encryptionTimedOut = 15
    }

    /// The user declined the pairing dialog, or iOS holds no key the dongle will accept.
    ///
    /// Both ATT codes mean the same thing to the app: the link is not encrypted enough to read
    /// the characteristic, and only pairing can change that.
    public var isAuthentication: Bool {
        guard domain == Self.attDomain else { return false }
        return code == ATT.insufficientAuthentication.rawValue
            || code == ATT.insufficientEncryption.rawValue
            || code == ATT.insufficientEncryptionKeySize.rawValue
    }

    /// iOS says the peer forgot us. The firmware drops its own half of the bond on
    /// `PINKEY_MISSING`, `AUTH_FAIL` and the two encryption errors (`src/ble_companion.cpp`), so
    /// the next attempt should pair cleanly and this is worth one more try before giving up.
    public var isPeerRemovedPairing: Bool {
        domain == Self.cbDomain && code == CB.peerRemovedPairingInformation.rawValue
    }

    /// Encryption failed on the link itself rather than on one characteristic.
    public var isEncryptionFailure: Bool {
        domain == Self.cbDomain && code == CB.encryptionTimedOut.rawValue
    }

    // MARK: - Failures the machine raises itself

    public static func cairn(_ code: Int, _ message: String) -> LinkFailure {
        LinkFailure(domain: cairnDomain, code: code, message: message)
    }

    public static let connectTimedOut = cairn(1, "the connection did not complete in 15 s")
    public static let notFound = cairn(2, "no Cairn dongle answered the scan")
    public static func missingCharacteristics(_ names: [String]) -> LinkFailure {
        cairn(3, "the dongle is missing \(names.joined(separator: " and "))")
    }
    public static let serviceNotFound = cairn(4, "the dongle has no Cairn service")
    public static func unsupportedVersion(_ version: UInt8) -> LinkFailure {
        cairn(5, "the dongle speaks protocol v\(version); this build speaks v1")
    }
    public static let badVersionPayload = cairn(6, "PROTOCOL_VERSION was not two bytes")
    public static func writeTooSmall(_ length: Int) -> LinkFailure {
        cairn(7, "the link will take only \(length) B per write, and a GNSS_FIX is 28 B")
    }
    public static let pairingRefused = cairn(8, "the dongle dropped the link while pairing")
}
