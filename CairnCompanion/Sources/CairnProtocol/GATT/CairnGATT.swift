import Foundation

/// The dongle's GATT identifiers and the sizes that go with them, from
/// `contracts/ble/v1/spec.md`, `offload.md` and `device-info.md`.
///
/// These are plain strings, not `CBUUID`: `CairnProtocol` holds no Apple framework types, so the
/// table can be read in a test, printed in a log and compared against the contract without a
/// radio anywhere near it. `CoreBluetoothCentral` in `CairnRuntime` is the only place that turns
/// one into a `CBUUID`.
public enum CairnGATT {
    public static let advertisedName = "Cairn"

    /// Every characteristic the contract names, in one list, so the Dongle screen can say which
    /// of them a given firmware actually exposes.
    public enum Characteristic: String, Sendable, CaseIterable {
        case gnssFix = "0001"
        case baroAlt = "0002"
        case utcSync = "0003"
        case engineDeclaration = "0004"
        case gnssQuality = "0010"
        case companionStatus = "0011"
        case obdLive = "0020"
        case deviceStatus = "0021"
        case offloadControl = "0030"
        case offloadData = "0031"
        case deviceInfo = "0040"
        case protocolVersion = "00F0"

        public var uuid: String { CairnGATT.uuid(suffix: rawValue) }

        /// What it is called in a log line and on the Dongle screen.
        public var title: String {
            switch self {
            case .gnssFix: "GNSS_FIX"
            case .baroAlt: "BARO_ALT"
            case .utcSync: "UTC_SYNC"
            case .engineDeclaration: "ENGINE_DECLARATION"
            case .gnssQuality: "GNSS_QUALITY"
            case .companionStatus: "COMPANION_STATUS"
            case .obdLive: "OBD_LIVE"
            case .deviceStatus: "DEVICE_STATUS"
            case .offloadControl: "OFFLOAD_CONTROL"
            case .offloadData: "OFFLOAD_DATA"
            case .deviceInfo: "DEVICE_INFO"
            case .protocolVersion: "PROTOCOL_VERSION"
            }
        }
    }

    public static let serviceUUID = uuid(suffix: "0000")

    /// Without these two there is no link worth having: one to write fixes to, one to read the
    /// version and capabilities from. Everything else is optional and gated on presence, so a
    /// firmware that adds `OBD_LIVE` needs no change here (architecture rule 4).
    public static let requiredCharacteristics: Set<Characteristic> = [.gnssFix, .protocolVersion]

    /// Minimum write length needed to send a `GNSS_FIX`.
    public static let requiredWriteLength = GNSSFixPayload.size

    /// Protocol major version this build speaks. The app refuses to stream to any other.
    public static let supportedMajorVersion: UInt8 = 1

    public static func characteristic(uuid: String) -> Characteristic? {
        let wanted = uuid.uppercased()
        return Characteristic.allCases.first { $0.uuid.uppercased() == wanted }
    }

    static func uuid(suffix: String) -> String {
        "A8E3\(suffix)-4F5B-11EF-A017-325096B39F47"
    }
}

/// The capability bitmap of the `PROTOCOL_VERSION` read: byte 1, one byte, per
/// `ble/v1/spec.md` § PROTOCOL_VERSION. Only bits 2 and 3 are defined; everything else about a
/// dongle is read from `DEVICE_INFO` (`device-info.md` § 2).
///
/// A feature is used only when its bit is set *and* its characteristic was discovered. Both
/// halves matter: the bits said offload was there while `0030` was missing from the app's
/// discovery list, which is how bundle offload came to be dead code (audit § 2).
public struct CairnCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Bundle offload is supported, and the dongle's offload task actually started
    /// (`offload.md` § 3).
    public static let bundleOffload = CairnCapabilities(rawValue: 1 << 2)
    /// `DEVICE_INFO` is present. Reading `0040` without this bit is forbidden.
    public static let deviceInformation = CairnCapabilities(rawValue: 1 << 3)

    /// Names for the bits that are set, plus `bitN` for any this build does not know, so a
    /// newer firmware's extra bit shows on the Dongle screen instead of vanishing.
    public var titles: [String] {
        let known: [(CairnCapabilities, String)] = [
            (.bundleOffload, "OFFLOAD"), (.deviceInformation, "DEVICE_INFO"),
        ]
        var out = known.filter { contains($0.0) }.map(\.1)
        let accounted = known.reduce(into: CairnCapabilities()) { $0.insert($1.0) }
        let unknown = rawValue & ~accounted.rawValue
        for bit in 0..<8 where unknown & (1 << UInt8(bit)) != 0 { out.append("bit\(bit)") }
        return out
    }
}
