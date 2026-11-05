import Foundation

/// `BARO_ALT` write: relative altitude from `CMAltimeter`, 4 B (docs/ble-protocol.md, full-plan.md).
/// Relative to where the altimeter session started, not MSL and not the GNSS ellipsoid.
public struct BaroAltPayload: Sendable, Equatable {
    public static let size = 4

    /// Reserved for "no reading"; real values clamp one below it.
    public static let invalid: Int32 = 0x7FFF_FFFF

    public var relativeAltitudeCm: Int32

    public init(relativeAltitudeCm: Int32) {
        self.relativeAltitudeCm = relativeAltitudeCm
    }

    /// `metres` is `CMAltitudeData.relativeAltitude`. Non-finite input encodes as the invalid sentinel.
    public init(relativeAltitudeMetres metres: Double) {
        guard metres.isFinite else {
            self.init(relativeAltitudeCm: Self.invalid)
            return
        }
        let cm = (metres * 100).rounded()
        self.init(relativeAltitudeCm: Int32(max(Double(Int32.min), min(cm, Double(Int32.max - 1)))))
    }

    public var data: Data {
        var out = Data(capacity: Self.size)
        out.appendLE(relativeAltitudeCm)
        return out
    }

    public init?(data: Data) {
        guard data.count == Self.size else { return nil }
        self.init(relativeAltitudeCm: Data(data).readLE(at: 0))
    }
}

/// `UTC_SYNC` write: phone wall clock as Unix milliseconds, 8 B. Sent on connect and about once a minute.
public struct UTCSyncPayload: Sendable, Equatable {
    public static let size = 8

    public var unixMs: UInt64

    public init(unixMs: UInt64) {
        self.unixMs = unixMs
    }

    /// Dates before the epoch clamp to 0 rather than trapping.
    public init(date: Date) {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        self.init(unixMs: ms.isFinite && ms > 0 ? UInt64(min(ms, Double(UInt64.max / 2))) : 0)
    }

    public var data: Data {
        var out = Data(capacity: Self.size)
        out.appendLE(unixMs)
        return out
    }

    public init?(data: Data) {
        guard data.count == Self.size else { return nil }
        self.init(unixMs: Data(data).readLE(at: 0))
    }
}
