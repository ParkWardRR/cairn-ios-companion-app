import Foundation
import Testing
@testable import CairnProtocol

/// Replays contracts/ble/v1/vectors/golden/golden-vectors.json (the pinned contracts release), which the firmware repo consumes too. The vectors come from an
/// independent implementation of the spec, so a mismatch means the encoder or the spec drifted.
private struct Vectors: Decodable {
    struct Fix: Decodable {
        struct Input: Decodable {
            let lat, lon, alt, hacc, vacc, speed, course, age: Double
            let seq: UInt16
            /// Byte 26, added in the `companion_flags` change. Absent in every vector written
            /// before it, so a pin that predates the change still replays: the field is
            /// optional here, not in the spec.
            let companion_flags: UInt8?
        }
        let name: String
        let input: Input
        let hex: String
    }
    struct Baro: Decodable { let name: String; let relative_altitude_m: Double; let hex: String }
    struct UTC: Decodable { let name: String; let unix_ms: UInt64; let hex: String }

    let now_unix: Double
    let gnss_fix: [Fix]
    let baro_alt: [Baro]
    let utc_sync: [UTC]
}

private let vectors: Vectors = try! JSONDecoder().decode(
    Vectors.self, from: Contracts.data("ble/v1/vectors/golden/golden-vectors.json"))

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Suite struct GoldenVectorTests {
    /// Which of the pinned vectors carry `companion_flags`. Zero on a pin from before the
    /// change; the moment the pin moves, the hint and charging cases start being replayed with
    /// no edit here. Printed rather than asserted, so neither pin fails the suite.
    @Test func whichVectorsAreInThePin() {
        let flagged = vectors.gnss_fix.filter { ($0.input.companion_flags ?? 0) != 0 }
        print("golden vectors with companion_flags: \(flagged.map(\.name))")
    }

    @Test func gnssFix() throws {
        let now = Date(timeIntervalSince1970: vectors.now_unix)
        for v in vectors.gnss_fix {
            let i = v.input
            let fix = PhoneGNSSFix(
                latitude: i.lat, longitude: i.lon, ellipsoidalAltitude: i.alt,
                horizontalAccuracy: i.hacc, verticalAccuracy: i.vacc, speed: i.speed, course: i.course,
                timestamp: now.addingTimeInterval(-i.age)
            )
            let flags = GNSSFixPayload.CompanionFlags(rawValue: i.companion_flags ?? 0)
            // A `HINT` vector is a cached fix on purpose, so it goes through the one encoder
            // that is allowed to ignore the two-second rule. Everything else goes through the
            // ordinary one, which must still refuse a stale fix.
            let payload = try #require(
                flags.contains(.hint)
                    ? PayloadEncoder.hint(fix, now: now, seq: i.seq, isCharging: flags.contains(.charging))
                    : PayloadEncoder.encode(fix, now: now, seq: i.seq, isCharging: flags.contains(.charging)),
                "\(v.name)"
            )
            #expect(hex(payload.data) == v.hex, "\(v.name)")
            #expect(payload.companionFlags == (i.companion_flags ?? 0), "\(v.name): companion_flags")
        }
    }

    @Test func baroAlt() {
        for v in vectors.baro_alt {
            let payload = BaroAltPayload(relativeAltitudeMetres: v.relative_altitude_m)
            #expect(hex(payload.data) == v.hex, "\(v.name)")
            #expect(BaroAltPayload(data: payload.data) == payload)
        }
    }

    @Test func utcSync() {
        for v in vectors.utc_sync {
            let payload = UTCSyncPayload(unixMs: v.unix_ms)
            #expect(hex(payload.data) == v.hex, "\(v.name)")
            #expect(UTCSyncPayload(data: payload.data) == payload)
        }
    }
}
