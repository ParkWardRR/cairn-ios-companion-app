import CairnKit
import Foundation
import Testing

/// The decoder, against the worked example from the format's own description — the same one the
/// server's encoder is tested against, independently, in Go. Two implementations checked against
/// a third party's numbers is the only way either is worth trusting.
@Suite("Polyline")
struct PolylineTests {
    @Test("the worked example decodes to the three places it names")
    func workedExample() {
        guard let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@") else {
            Issue.record("did not decode"); return
        }
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 1e-5)
        #expect(abs(points[0].longitude - (-120.2)) < 1e-5)
        #expect(abs(points[1].latitude - 40.7) < 1e-5)
        #expect(abs(points[2].latitude - 43.252) < 1e-5)
        #expect(abs(points[2].longitude - (-126.453)) < 1e-5)
    }

    @Test("an empty string is an empty route, not a failure")
    func empty() {
        #expect(Polyline.decode("") == [])
    }

    @Test("a truncated string is refused rather than half-decoded")
    func truncated() {
        // A map drawn from half a polyline shows a drive that ended somewhere it did not,
        // which is worse than no map.
        #expect(Polyline.decode("_p~iF~ps|U_ulL") == nil, "a latitude with no longitude")
        #expect(Polyline.decode("_p~iF~ps|U_") == nil, "a value that never terminates")
    }

    @Test("a corrupt string is refused")
    func corrupt() {
        #expect(Polyline.decode("!!!") == nil, "bytes below the 63 offset")
        // Deltas that walk off the globe are a bad string, not a place.
        #expect(Polyline.decode(String(repeating: "_p~iF~ps|U", count: 40)) == nil)
    }

    @Test("a long route round-trips through the format")
    func longRoute() {
        // Built by the same rules the server encodes by, so what this checks is that the
        // decoder follows them: deltas, zig-zag, five bits at a time, offset 63.
        var encoded = ""
        var lastLat = 0, lastLon = 0
        var expected: [GeoPoint] = []
        for i in 0..<500 {
            let lat = 37.7749 + Double(i) * 0.0001
            let lon = -122.4194 - Double(i) * 0.00007
            expected.append(GeoPoint(latitude: lat, longitude: lon))
            let latE5 = Int((lat * 1e5).rounded()), lonE5 = Int((lon * 1e5).rounded())
            encoded += encodeValue(latE5 - lastLat) + encodeValue(lonE5 - lastLon)
            lastLat = latE5
            lastLon = lonE5
        }
        guard let decoded = Polyline.decode(encoded) else { Issue.record("did not decode"); return }
        #expect(decoded.count == expected.count)
        for (a, b) in zip(decoded, expected) {
            #expect(abs(a.latitude - b.latitude) < 1e-5)
            #expect(abs(a.longitude - b.longitude) < 1e-5)
        }
    }

    private func encodeValue(_ value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var out = ""
        while v >= 0x20 {
            out.append(Character(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63))))
            v >>= 5
        }
        out.append(Character(UnicodeScalar(UInt8(v + 63))))
        return out
    }
}
