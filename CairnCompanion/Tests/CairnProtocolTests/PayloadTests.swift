import Foundation
import Testing
@testable import CairnProtocol

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(
    lat: Double = 37.7749, lon: Double = -122.4194, alt: Double = 12.34,
    hAcc: Double = 5, vAcc: Double = 8, speed: Double = 13.4, course: Double = 90,
    age: TimeInterval = 0.25
) -> PhoneGNSSFix {
    PhoneGNSSFix(
        latitude: lat, longitude: lon, ellipsoidalAltitude: alt,
        horizontalAccuracy: hAcc, verticalAccuracy: vAcc, speed: speed, course: course,
        timestamp: now.addingTimeInterval(-age)
    )
}

@Suite struct PayloadTests {
    @Test func goldenVector() throws {
        let payload = try #require(PayloadEncoder.encode(fix(), now: now, seq: 0x0102))
        let expected: [UInt8] = [
            0x08, 0xFE, 0x83, 0x16,       // lat_e7  377749000
            0x30, 0x48, 0x08, 0xB7,       // lon_e7 -1224194000
            0xD2, 0x04, 0x00, 0x00,       // alt_cm  1234
            0x3C, 0x05,                   // speed_cmps 1340
            0x28, 0x23,                   // heading_cdeg 9000
            0xF4, 0x01,                   // h_acc_cm 500
            0x20, 0x03,                   // v_acc_cm 800
            0x02,                         // fix_type 3D
            0x0F,                         // validity b0..b3
            0xFA, 0x00,                   // sample_age_ms 250
            0x02, 0x01,                   // seq
            0x00, 0x00,                   // reserved
        ]
        #expect(Array(payload.data) == expected)
        #expect(GNSSFixPayload(data: payload.data) == payload)
    }

    @Test func sizeIsAlways28() throws {
        #expect(try #require(PayloadEncoder.encode(fix(), now: now, seq: 0)).data.count == 28)
        #expect(try #require(PayloadEncoder.encode(fix(hAcc: -1), now: now, seq: 0)).data.count == 28)
    }

    @Test func invalidHorizontalAccuracyClearsPosition() throws {
        let p = try #require(PayloadEncoder.encode(fix(hAcc: -1), now: now, seq: 1))
        #expect(p.fixType == 0)
        #expect(!p.validity.contains(.position))
        #expect(p.latE7 == 0 && p.lonE7 == 0)
        #expect(p.hAccCm == 0xFFFF)
    }

    @Test func invalidVerticalAccuracyIsTwoD() throws {
        let p = try #require(PayloadEncoder.encode(fix(vAcc: -1), now: now, seq: 1))
        #expect(p.fixType == 1)
        #expect(!p.validity.contains(.altitude))
        #expect(p.validity.contains(.position))
        #expect(p.altCm == 0x7FFF_FFFF)
        #expect(p.vAccCm == 0xFFFF)
    }

    @Test func negativeSpeedIsNeverZero() throws {
        let p = try #require(PayloadEncoder.encode(fix(speed: -1), now: now, seq: 1))
        #expect(p.speedCmps == 0xFFFF)
        #expect(!p.validity.contains(.speed))
    }

    @Test func zeroSpeedIsValid() throws {
        let p = try #require(PayloadEncoder.encode(fix(speed: 0), now: now, seq: 1))
        #expect(p.speedCmps == 0)
        #expect(p.validity.contains(.speed))
    }

    @Test func negativeCourseIsNeverNorth() throws {
        let p = try #require(PayloadEncoder.encode(fix(course: -1), now: now, seq: 1))
        #expect(p.headingCdeg == 0xFFFF)
        #expect(!p.validity.contains(.course))
    }

    @Test func courseNearNorthWraps() throws {
        let p = try #require(PayloadEncoder.encode(fix(course: 359.9999), now: now, seq: 1))
        #expect(p.headingCdeg == 0)
        #expect(p.validity.contains(.course))
    }

    @Test func accuracyClampsInsteadOfWrapping() throws {
        let p = try #require(PayloadEncoder.encode(fix(hAcc: 10_000, vAcc: 1_000_000), now: now, seq: 1))
        #expect(p.hAccCm == 65_534)
        #expect(p.vAccCm == 65_534)
    }

    @Test func speedClampsBelowSentinel() throws {
        let p = try #require(PayloadEncoder.encode(fix(speed: 10_000), now: now, seq: 1))
        #expect(p.speedCmps == 65_534)
        #expect(p.validity.contains(.speed))
    }

    @Test func nonFiniteValuesAreInvalid() throws {
        let p = try #require(PayloadEncoder.encode(fix(lat: .nan, speed: .infinity, course: .nan), now: now, seq: 1))
        #expect(!p.validity.contains(.position))
        #expect(!p.validity.contains(.speed))
        #expect(!p.validity.contains(.course))
    }

    @Test func outOfRangeCoordinateIsInvalid() throws {
        let p = try #require(PayloadEncoder.encode(fix(lat: 91), now: now, seq: 1))
        #expect(!p.validity.contains(.position))
    }

    @Test func seqRoundTripsAtWrap() throws {
        let p = try #require(PayloadEncoder.encode(fix(), now: now, seq: .max))
        #expect(GNSSFixPayload(data: p.data)?.seq == 0xFFFF)
    }

    @Test func rejectsWrongLengthOnDecode() {
        #expect(GNSSFixPayload(data: Data(count: 27)) == nil)
        #expect(GNSSFixPayload(data: Data(count: 29)) == nil)
    }

    @Test func decodesQualityAndStatus() throws {
        let q = try #require(PayloadDecoder.gnssQuality(Data([2, 9, 0x96, 0x00, 0xE8, 0x03, 0, 0])))
        #expect(q == GNSSQuality(fixType: 2, satsUsed: 9, hdopE2: 150, fixAgeMs: 1000))
        #expect(q.hdop == 1.5)

        let s = try #require(PayloadDecoder.companionStatus(Data([1, 0, 2, 0, 3, 0, 4, 0])))
        #expect(s == CompanionStatus(lastAcceptedSeq: 1, acceptedCount: 2, rejectedCount: 3, queueDropCount: 4))

        #expect(PayloadDecoder.gnssQuality(Data(count: 7)) == nil)
        #expect(PayloadDecoder.companionStatus(Data(count: 9)) == nil)
    }

    @Test func unknownHDOPIsNil() throws {
        let q = try #require(PayloadDecoder.gnssQuality(Data([0, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])))
        #expect(q.hdop == nil)
    }

    @Test func protocolVersionGate() throws {
        #expect(try #require(PayloadDecoder.protocolVersion(Data([1, 0]))).isSupported)
        #expect(try !#require(PayloadDecoder.protocolVersion(Data([2, 0]))).isSupported)
    }
}

@Suite struct OBDLiveTests {
    private func makeOBDData(
        rpm: UInt16 = 3500, speedE1: UInt16 = 650, throttle: UInt8 = 42, load: UInt8 = 55,
        coolant: Int16 = 90, intake: Int16 = 35, boostE1: Int16 = 85,
        mafE2: UInt16 = 1250, fuelPressure: UInt16 = 350, timingE2: Int16 = 1400,
        stft1: Int16 = 250, ltft1: Int16 = -125, stft2: Int16 = 0x7FFF, ltft2: Int16 = 0x7FFF,
        oilTemp: Int16 = 105, voltageMv: UInt16 = 14200, bitmap: UInt16 = 0xFFFF, ageMs: UInt32 = 50
    ) -> Data {
        var d = Data(capacity: 48)
        d.appendLE(rpm); d.appendLE(speedE1)
        d.append(throttle); d.append(load)
        d.appendLE(coolant); d.appendLE(intake)
        d.appendLE(boostE1); d.appendLE(mafE2)
        d.appendLE(fuelPressure); d.appendLE(timingE2)
        d.appendLE(stft1); d.appendLE(ltft1)
        d.appendLE(stft2); d.appendLE(ltft2)
        d.appendLE(oilTemp); d.appendLE(voltageMv)
        d.appendLE(bitmap); d.appendLE(ageMs)
        d.append(contentsOf: [UInt8](repeating: 0, count: 12))
        return d
    }

    @Test func decodesValidSnapshot() throws {
        let obd = try #require(PayloadDecoder.obdLive(makeOBDData()))
        #expect(obd.rpm == 3500)
        #expect(obd.speedKph == 65.0)
        #expect(obd.throttlePct == 42)
        #expect(obd.coolantTempC == 90)
        #expect(obd.boostKpa == 8.5)
        #expect(obd.stft1 == 2.5)
        #expect(obd.ltft1 == -1.25)
        #expect(obd.voltage == 14.2)
        #expect(obd.hasRPM)
        #expect(obd.hasCoolant)
    }

    @Test func sentinelsReturnNil() throws {
        let obd = try #require(PayloadDecoder.obdLive(makeOBDData(
            rpm: 0xFFFF, speedE1: 0xFFFF, throttle: 0xFF,
            coolant: 0x7FFF, boostE1: 0x7FFF, voltageMv: 0xFFFF
        )))
        #expect(!obd.hasRPM)
        #expect(obd.speedKph == nil)
        #expect(!obd.hasThrottle)
        #expect(!obd.hasCoolant)
        #expect(!obd.hasBoost)
        #expect(obd.voltage == nil)
    }

    @Test func rejectsWrongLength() {
        #expect(PayloadDecoder.obdLive(Data(count: 47)) == nil)
        #expect(PayloadDecoder.obdLive(Data(count: 49)) == nil)
    }
}

@Suite struct DeviceStatusTests {
    private func makeStatusData(
        trip: UInt8 = 1, flags: UInt8 = 0, health: UInt16 = 0x000F,
        battery: UInt16 = 12600, sdFree: UInt16 = 2048, uptime: UInt32 = 3661
    ) -> Data {
        var d = Data(capacity: 12)
        d.append(trip); d.append(flags)
        d.appendLE(health); d.appendLE(battery)
        d.appendLE(sdFree); d.appendLE(uptime)
        return d
    }

    @Test func decodesValidStatus() throws {
        let ds = try #require(PayloadDecoder.deviceStatus(makeStatusData()))
        #expect(ds.tripPhase == .driving)
        #expect(ds.batteryV == 12.6)
        #expect(ds.sdFree == 2048)
        #expect(ds.uptimeS == 3661)
        #expect(ds.health.contains(.obdOk))
        #expect(ds.health.contains(.gnssOk))
        #expect(ds.health.contains(.sdOk))
        #expect(ds.health.contains(.imuOk))
    }

    @Test func unknownTripStateBecomesUnknown() throws {
        let ds = try #require(PayloadDecoder.deviceStatus(makeStatusData(trip: 99)))
        #expect(ds.tripPhase == .unknown)
    }

    @Test func sentinelsReturnNil() throws {
        let ds = try #require(PayloadDecoder.deviceStatus(makeStatusData(battery: 0xFFFF, sdFree: 0xFFFF)))
        #expect(ds.batteryV == nil)
        #expect(ds.sdFree == nil)
    }

    @Test func rejectsWrongLength() {
        #expect(PayloadDecoder.deviceStatus(Data(count: 11)) == nil)
        #expect(PayloadDecoder.deviceStatus(Data(count: 13)) == nil)
    }
}

@Suite struct StalenessTests {
    @Test func dropsFixesOlderThanTwoSeconds() {
        #expect(PayloadEncoder.encode(fix(age: 2.01), now: now, seq: 1) == nil)
    }

    @Test func keepsFixAtTheBoundary() {
        #expect(PayloadEncoder.encode(fix(age: 2.0), now: now, seq: 1) != nil)
    }

    @Test func dropsFixesFromTheFuture() {
        #expect(PayloadEncoder.encode(fix(age: -2.5), now: now, seq: 1) == nil)
    }

    @Test func slightlyFutureTimestampClampsAgeToZero() throws {
        let p = try #require(PayloadEncoder.encode(fix(age: -0.3), now: now, seq: 1))
        #expect(p.sampleAgeMs == 0)
    }
}
