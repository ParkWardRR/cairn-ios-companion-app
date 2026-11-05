import Foundation

/// `GNSS_QUALITY` notify: internal receiver state. Layout is proposed, not frozen (docs/ble-protocol.md).
public struct GNSSQuality: Sendable, Equatable {
    public static let size = 8

    public var fixType: UInt8
    public var satsUsed: UInt8
    public var hdopE2: UInt16
    public var fixAgeMs: UInt32

    /// HDOP in natural units, or nil when the receiver reports unknown (`0xFFFF`).
    public var hdop: Double? { hdopE2 == 0xFFFF ? nil : Double(hdopE2) / 100 }

    public init(fixType: UInt8, satsUsed: UInt8, hdopE2: UInt16, fixAgeMs: UInt32) {
        self.fixType = fixType
        self.satsUsed = satsUsed
        self.hdopE2 = hdopE2
        self.fixAgeMs = fixAgeMs
    }

    /// Encoding is for tests and for `FakeCentral`: the device writes these, not the phone.
    public var data: Data {
        var out = Data([fixType, satsUsed])
        out.appendLE(hdopE2)
        out.appendLE(fixAgeMs)
        return out
    }
}

/// `COMPANION_STATUS` notify: firmware acceptance feedback. Layout is proposed, not frozen.
public struct CompanionStatus: Sendable, Equatable {
    public static let size = 8

    public var lastAcceptedSeq: UInt16
    public var acceptedCount: UInt16
    public var rejectedCount: UInt16
    public var queueDropCount: UInt16

    public init(lastAcceptedSeq: UInt16, acceptedCount: UInt16, rejectedCount: UInt16, queueDropCount: UInt16) {
        self.lastAcceptedSeq = lastAcceptedSeq
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.queueDropCount = queueDropCount
    }

    public var data: Data {
        var out = Data()
        for value in [lastAcceptedSeq, acceptedCount, rejectedCount, queueDropCount] { out.appendLE(value) }
        return out
    }
}

/// `OBD_LIVE` notify (48 bytes): latest OBD-II snapshot from the dongle's ELM/STN adapter.
public struct OBDLiveSnapshot: Sendable, Equatable {
    public static let size = 48
    public static let invalidU16: UInt16 = 0xFFFF
    public static let invalidI16: Int16 = 0x7FFF

    public var rpm: UInt16
    public var speedKphE1: UInt16
    public var throttlePct: UInt8
    public var engineLoadPct: UInt8
    public var coolantTempC: Int16
    public var intakeTempC: Int16
    public var boostKpaE1: Int16
    public var mafE2: UInt16
    public var fuelPressureKpa: UInt16
    public var timingAdvE2: Int16
    public var stft1E2: Int16
    public var ltft1E2: Int16
    public var stft2E2: Int16
    public var ltft2E2: Int16
    public var oilTempC: Int16
    public var voltageMv: UInt16
    public var pidBitmap: UInt16
    public var ageMs: UInt32

    public var speedKph: Double? { speedKphE1 == Self.invalidU16 ? nil : Double(speedKphE1) / 10 }
    public var boostKpa: Double? { boostKpaE1 == Self.invalidI16 ? nil : Double(boostKpaE1) / 10 }
    public var maf: Double? { mafE2 == Self.invalidU16 ? nil : Double(mafE2) / 100 }
    public var timingAdv: Double? { timingAdvE2 == Self.invalidI16 ? nil : Double(timingAdvE2) / 100 }
    public var stft1: Double? { stft1E2 == Self.invalidI16 ? nil : Double(stft1E2) / 100 }
    public var ltft1: Double? { ltft1E2 == Self.invalidI16 ? nil : Double(ltft1E2) / 100 }
    public var stft2: Double? { stft2E2 == Self.invalidI16 ? nil : Double(stft2E2) / 100 }
    public var ltft2: Double? { ltft2E2 == Self.invalidI16 ? nil : Double(ltft2E2) / 100 }
    public var voltage: Double? { voltageMv == Self.invalidU16 ? nil : Double(voltageMv) / 1000 }

    public var hasRPM: Bool { rpm != Self.invalidU16 }
    public var hasSpeed: Bool { speedKphE1 != Self.invalidU16 }
    public var hasCoolant: Bool { coolantTempC != Self.invalidI16 }
    public var hasIntakeTemp: Bool { intakeTempC != Self.invalidI16 }
    public var hasBoost: Bool { boostKpaE1 != Self.invalidI16 }
    public var hasThrottle: Bool { throttlePct != 0xFF }
    public var hasOilTemp: Bool { oilTempC != Self.invalidI16 }
}

/// `DEVICE_STATUS` notify (12 bytes): dongle health and trip state.
public struct DeviceStatus: Sendable, Equatable {
    public static let size = 12

    public var tripState: UInt8
    public var flags: UInt8
    public var healthBitmap: UInt16
    public var batteryMv: UInt16
    public var sdFreeMb: UInt16
    public var uptimeS: UInt32

    public var tripPhase: TripPhase { TripPhase(rawValue: tripState) ?? .unknown }
    public var batteryV: Double? { batteryMv == 0xFFFF ? nil : Double(batteryMv) / 1000 }
    public var sdFree: UInt16? { sdFreeMb == 0xFFFF ? nil : sdFreeMb }

    public enum TripPhase: UInt8, Sendable {
        case idle = 0, driving = 1, paused = 2
        case unknown = 0xFF
    }

    public struct Health: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let obdOk = Health(rawValue: 1 << 0)
        public static let gnssOk = Health(rawValue: 1 << 1)
        public static let sdOk = Health(rawValue: 1 << 2)
        public static let imuOk = Health(rawValue: 1 << 3)
    }

    public var health: Health { Health(rawValue: healthBitmap) }
}

/// `PROTOCOL_VERSION` read: `u8 version` + `u8 capabilities` (`ble/v1/spec.md`).
///
/// Reading this characteristic is also what makes iOS pair, because the firmware marks it as
/// needing encryption. That is deliberate (D2): the app never asks for a pairing mode, it asks
/// for two bytes and lets iOS put up whatever dialog the dongle's IO capability demands.
public struct ProtocolVersion: Sendable, Equatable {
    public static let size = 2

    public var version: UInt8
    public var capabilities: CairnCapabilities

    public init(version: UInt8, capabilities: CairnCapabilities) {
        self.version = version
        self.capabilities = capabilities
    }

    /// False for unknown major versions; the app must not stream in that case.
    public var isSupported: Bool { version == CairnGATT.supportedMajorVersion }

    public var hasBundleOffload: Bool { capabilities.contains(.bundleOffload) }
    public var hasDeviceInformation: Bool { capabilities.contains(.deviceInformation) }

    public var data: Data { Data([version, capabilities.rawValue]) }

    /// `v1 · OFFLOAD, DEVICE_INFO` — what the Dongle screen shows and what a link-log line says.
    public var shortDescription: String {
        let bits = capabilities.titles
        return bits.isEmpty ? "v\(version)" : "v\(version) · \(bits.joined(separator: ", "))"
    }
}

/// Decoders validate length before reading. GATT gives boundaries, not guarantees.
public enum PayloadDecoder {
    public static func gnssQuality(_ data: Data) -> GNSSQuality? {
        guard data.count == GNSSQuality.size else { return nil }
        let d = Data(data)
        return GNSSQuality(fixType: d[0], satsUsed: d[1], hdopE2: d.readLE(at: 2), fixAgeMs: d.readLE(at: 4))
    }

    public static func companionStatus(_ data: Data) -> CompanionStatus? {
        guard data.count == CompanionStatus.size else { return nil }
        let d = Data(data)
        return CompanionStatus(
            lastAcceptedSeq: d.readLE(at: 0), acceptedCount: d.readLE(at: 2),
            rejectedCount: d.readLE(at: 4), queueDropCount: d.readLE(at: 6)
        )
    }

    public static func obdLive(_ data: Data) -> OBDLiveSnapshot? {
        guard data.count == OBDLiveSnapshot.size else { return nil }
        let d = Data(data)
        return OBDLiveSnapshot(
            rpm: d.readLE(at: 0), speedKphE1: d.readLE(at: 2),
            throttlePct: d[4], engineLoadPct: d[5],
            coolantTempC: d.readLE(at: 6), intakeTempC: d.readLE(at: 8),
            boostKpaE1: d.readLE(at: 10), mafE2: d.readLE(at: 12),
            fuelPressureKpa: d.readLE(at: 14), timingAdvE2: d.readLE(at: 16),
            stft1E2: d.readLE(at: 18), ltft1E2: d.readLE(at: 20),
            stft2E2: d.readLE(at: 22), ltft2E2: d.readLE(at: 24),
            oilTempC: d.readLE(at: 26), voltageMv: d.readLE(at: 28),
            pidBitmap: d.readLE(at: 30), ageMs: d.readLE(at: 32)
        )
    }

    public static func deviceStatus(_ data: Data) -> DeviceStatus? {
        guard data.count == DeviceStatus.size else { return nil }
        let d = Data(data)
        return DeviceStatus(
            tripState: d[0], flags: d[1],
            healthBitmap: d.readLE(at: 2), batteryMv: d.readLE(at: 4),
            sdFreeMb: d.readLE(at: 6), uptimeS: d.readLE(at: 8)
        )
    }

    /// At least two bytes, not exactly two: a firmware that appends a field to this read must
    /// not take the link down, and the tail means nothing to this build. Everything else here
    /// is a fixed-size notify, where a wrong length is a wrong payload.
    public static func protocolVersion(_ data: Data) -> ProtocolVersion? {
        guard data.count >= ProtocolVersion.size else { return nil }
        let d = Data(data)
        return ProtocolVersion(version: d[0], capabilities: CairnCapabilities(rawValue: d[1]))
    }
}
