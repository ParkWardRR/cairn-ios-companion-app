import Foundation

/// Decoded form of the 28 B `GNSS_FIX` write (docs/ble-protocol.md). Little-endian on the wire.
public struct GNSSFixPayload: Sendable, Equatable {
    public static let size = 28

    public static let invalidAltitude: Int32 = 0x7FFF_FFFF
    public static let invalidU16: UInt16 = 0xFFFF
    /// Largest valid value for accuracy and speed; `0xFFFF` is reserved for "invalid".
    public static let maxValidU16: UInt16 = 0xFFFE

    public struct Validity: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let position = Validity(rawValue: 1 << 0)
        public static let altitude = Validity(rawValue: 1 << 1)
        public static let speed = Validity(rawValue: 1 << 2)
        public static let course = Validity(rawValue: 1 << 3)
    }

    public var latE7: Int32
    public var lonE7: Int32
    public var altCm: Int32
    public var speedCmps: UInt16
    public var headingCdeg: UInt16
    public var hAccCm: UInt16
    public var vAccCm: UInt16
    /// 0 none, 1 2D, 2 3D.
    public var fixType: UInt8
    public var validity: Validity
    public var sampleAgeMs: UInt16
    public var seq: UInt16
    public var companionFlags: UInt8

    public struct CompanionFlags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let charging = CompanionFlags(rawValue: 1 << 0)
    }

    public init(
        latE7: Int32, lonE7: Int32, altCm: Int32,
        speedCmps: UInt16, headingCdeg: UInt16,
        hAccCm: UInt16, vAccCm: UInt16,
        fixType: UInt8, validity: Validity,
        sampleAgeMs: UInt16, seq: UInt16,
        companionFlags: UInt8 = 0
    ) {
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.altCm = altCm
        self.speedCmps = speedCmps
        self.headingCdeg = headingCdeg
        self.hAccCm = hAccCm
        self.vAccCm = vAccCm
        self.fixType = fixType
        self.validity = validity
        self.sampleAgeMs = sampleAgeMs
        self.seq = seq
        self.companionFlags = companionFlags
    }

    public var data: Data {
        var out = Data(capacity: Self.size)
        out.appendLE(latE7)
        out.appendLE(lonE7)
        out.appendLE(altCm)
        out.appendLE(speedCmps)
        out.appendLE(headingCdeg)
        out.appendLE(hAccCm)
        out.appendLE(vAccCm)
        out.append(fixType)
        out.append(validity.rawValue)
        out.appendLE(sampleAgeMs)
        out.appendLE(seq)
        out.append(companionFlags)
        out.append(0) // reserved
        return out
    }

    /// Returns nil unless `data` is exactly 28 B. Used by tests and golden vectors; the firmware owns the real decoder.
    public init?(data: Data) {
        guard data.count == Self.size else { return nil }
        let d = Data(data) // re-base indices to 0
        self.init(
            latE7: d.readLE(at: 0), lonE7: d.readLE(at: 4), altCm: d.readLE(at: 8),
            speedCmps: d.readLE(at: 12), headingCdeg: d.readLE(at: 14),
            hAccCm: d.readLE(at: 16), vAccCm: d.readLE(at: 18),
            fixType: d[20], validity: Validity(rawValue: d[21]),
            sampleAgeMs: d.readLE(at: 22), seq: d.readLE(at: 24),
            companionFlags: d[26]
        )
    }
}

/// Maps Core Location values to wire values per docs/ios-app.md "Encoding rules".
public enum PayloadEncoder {
    /// Fixes whose timestamp differs from `now` by more than this are dropped, not sent.
    public static let maxFixAge: TimeInterval = 2.0

    /// Returns nil when the fix is stale and must not be sent. Invalid fixes are still encoded
    /// (validity bits clear, sentinels set); the firmware rejects `b0 == 0`.
    public static func encode(_ fix: PhoneGNSSFix, now: Date, seq: UInt16, isCharging: Bool = false) -> GNSSFixPayload? {
        let age = now.timeIntervalSince(fix.timestamp)
        guard age.isFinite, abs(age) <= maxFixAge else { return nil }

        var validity: GNSSFixPayload.Validity = []

        let positionValid = isValid(fix.horizontalAccuracy)
            && fix.latitude.isFinite && fix.longitude.isFinite
            && abs(fix.latitude) <= 90 && abs(fix.longitude) <= 180
        let altitudeValid = positionValid && isValid(fix.verticalAccuracy) && fix.ellipsoidalAltitude.isFinite
        let speedValid = isValid(fix.speed)
        let courseValid = isValid(fix.course)

        let latE7: Int32, lonE7: Int32
        if positionValid {
            validity.insert(.position)
            latE7 = Int32((fix.latitude * 1e7).rounded())
            lonE7 = Int32((fix.longitude * 1e7).rounded())
        } else {
            latE7 = 0
            lonE7 = 0
        }

        let altCm: Int32
        if altitudeValid {
            validity.insert(.altitude)
            altCm = clampedInt32(fix.ellipsoidalAltitude * 100)
        } else {
            altCm = GNSSFixPayload.invalidAltitude
        }

        let speedCmps: UInt16
        if speedValid {
            validity.insert(.speed)
            speedCmps = clampedU16(fix.speed * 100)
        } else {
            speedCmps = GNSSFixPayload.invalidU16
        }

        let headingCdeg: UInt16
        if courseValid {
            validity.insert(.course)
            // 359.999° rounds to 36000; wrap so it never reads as an out-of-range heading.
            headingCdeg = UInt16(Int((fix.course * 100).rounded()) % 36_000)
        } else {
            headingCdeg = GNSSFixPayload.invalidU16
        }

        let fixType: UInt8 = !positionValid ? 0 : (altitudeValid ? 2 : 1)

        var flags: UInt8 = 0
        if isCharging { flags |= GNSSFixPayload.CompanionFlags.charging.rawValue }

        return GNSSFixPayload(
            latE7: latE7, lonE7: lonE7, altCm: altCm,
            speedCmps: speedCmps, headingCdeg: headingCdeg,
            hAccCm: positionValid ? clampedU16(fix.horizontalAccuracy * 100) : GNSSFixPayload.invalidU16,
            vAccCm: isValid(fix.verticalAccuracy) ? clampedU16(fix.verticalAccuracy * 100) : GNSSFixPayload.invalidU16,
            fixType: fixType, validity: validity,
            sampleAgeMs: UInt16(max(0, min(age * 1000, 65_535)).rounded()),
            seq: seq,
            companionFlags: flags
        )
    }

    /// Core Location uses negative values for "invalid"; NaN/inf are treated the same way.
    private static func isValid(_ value: Double) -> Bool { value.isFinite && value >= 0 }

    /// Clamps to 0...65534 so overflow never wraps and never collides with the 0xFFFF sentinel.
    private static func clampedU16(_ value: Double) -> UInt16 {
        UInt16(max(0, min(value.rounded(), Double(GNSSFixPayload.maxValidU16))))
    }

    /// Clamps below the 0x7FFFFFFF invalid-altitude sentinel.
    private static func clampedInt32(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(value.rounded(), Double(Int32.max - 1))))
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// `self` must be zero-indexed; callers re-base first.
    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: self[offset + i]) << (8 * i)
        }
        return value
    }
}
