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
    @Test func gnssFix() throws {
        let now = Date(timeIntervalSince1970: vectors.now_unix)
        for v in vectors.gnss_fix {
            let i = v.input
            let fix = PhoneGNSSFix(
                latitude: i.lat, longitude: i.lon, ellipsoidalAltitude: i.alt,
                horizontalAccuracy: i.hacc, verticalAccuracy: i.vacc, speed: i.speed, course: i.course,
                timestamp: now.addingTimeInterval(-i.age)
            )
            let payload = try #require(PayloadEncoder.encode(fix, now: now, seq: i.seq), "\(v.name)")
            #expect(hex(payload.data) == v.hex, "\(v.name)")
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
