import Foundation
import Testing
@testable import CairnProtocol

@Suite struct EnrichmentPayloadTests {
    @Test func baroSizes() {
        #expect(BaroAltPayload(relativeAltitudeMetres: 1).data.count == 4)
        #expect(UTCSyncPayload(unixMs: 1).data.count == 8)
    }

    @Test func baroNonFiniteIsInvalid() {
        #expect(BaroAltPayload(relativeAltitudeMetres: .nan).relativeAltitudeCm == BaroAltPayload.invalid)
        #expect(BaroAltPayload(relativeAltitudeMetres: .infinity).relativeAltitudeCm == BaroAltPayload.invalid)
    }

    @Test func baroClampsBelowSentinel() {
        #expect(BaroAltPayload(relativeAltitudeMetres: 1e12).relativeAltitudeCm == Int32.max - 1)
        #expect(BaroAltPayload(relativeAltitudeMetres: -1e12).relativeAltitudeCm == Int32.min)
    }

    @Test func baroRoundsToNearestCentimetre() {
        #expect(BaroAltPayload(relativeAltitudeMetres: 0.004).relativeAltitudeCm == 0)
        #expect(BaroAltPayload(relativeAltitudeMetres: 0.006).relativeAltitudeCm == 1)
        #expect(BaroAltPayload(relativeAltitudeMetres: -0.006).relativeAltitudeCm == -1)
    }

    @Test func utcFromDateKeepsMilliseconds() {
        let p = UTCSyncPayload(date: Date(timeIntervalSince1970: 1_800_000_000.123))
        #expect(p.unixMs == 1_800_000_000_123)
    }

    @Test func utcBeforeEpochClampsToZero() {
        #expect(UTCSyncPayload(date: Date(timeIntervalSince1970: -5)).unixMs == 0)
        #expect(UTCSyncPayload(date: Date(timeIntervalSince1970: .nan)).unixMs == 0)
    }

    @Test func decodeRejectsWrongLength() {
        #expect(BaroAltPayload(data: Data(count: 3)) == nil)
        #expect(UTCSyncPayload(data: Data(count: 4)) == nil)
    }
}
