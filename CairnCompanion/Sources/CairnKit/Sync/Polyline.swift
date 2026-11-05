import Foundation

/// One place on a route.
public struct GeoPoint: Sendable, Equatable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The encoded-polyline format at precision 5, decoded.
///
/// Deltas from the previous point, scaled by 1e5, zig-zag encoded, five bits at a time with a
/// continuation bit, offset by 63 so the result is printable ASCII. The server encodes a trip's
/// runs this way because it is about a tenth the size of the same points as JSON numbers — a
/// two-hour drive at 1 Hz is seven thousand points.
///
/// Decoding is strict. A truncated or corrupt string returns nil rather than a short route: a
/// map drawn from half a polyline shows a drive that ended somewhere it did not, and that is
/// worse than no map.
public enum Polyline {
    public static func decode(_ encoded: String) -> [GeoPoint]? {
        var points: [GeoPoint] = []
        var latE5 = 0, lonE5 = 0
        var index = encoded.startIndex

        while index < encoded.endIndex {
            guard let dLat = next(&index, in: encoded) else { return nil }
            guard let dLon = next(&index, in: encoded) else { return nil }
            latE5 += dLat
            lonE5 += dLon
            let latitude = Double(latE5) / 1e5
            let longitude = Double(lonE5) / 1e5
            // A delta sequence that walks off the globe is a corrupt string, not a place.
            guard abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
            points.append(GeoPoint(latitude: latitude, longitude: longitude))
        }
        return points
    }

    /// One zig-zag value, advancing the index. Nil on a truncated or malformed group.
    private static func next(_ index: inout String.Index, in encoded: String) -> Int? {
        var result = 0
        var shift = 0
        while index < encoded.endIndex {
            guard let ascii = encoded[index].asciiValue, ascii >= 63 else { return nil }
            let chunk = Int(ascii) - 63
            index = encoded.index(after: index)
            result |= (chunk & 0x1F) << shift
            shift += 5
            // Six groups is 30 bits, which covers ±180e5 with room; more is a bad string.
            if shift > 35 { return nil }
            if chunk < 0x20 {
                return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }
        }
        return nil // ran out mid-value
    }
}

public extension TripTrack {
    /// Each run as its places, in order. A run that will not decode is dropped and the rest are
    /// kept: losing one stretch of a route is better than losing the route.
    var decodedRuns: [[GeoPoint]] {
        runs.compactMap { Polyline.decode($0.polyline) }.filter { $0.count >= 2 }
    }

    /// Every place, for a bounding box. Not for drawing: drawing these as one line would put a
    /// stroke across each gap, which is the thing the runs exist to prevent.
    var allPoints: [GeoPoint] { decodedRuns.flatMap { $0 } }

    /// The box the whole route fits in, for framing a map.
    var bounds: (southWest: GeoPoint, northEast: GeoPoint)? {
        let points = allPoints
        guard !points.isEmpty else { return nil }
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        return (
            GeoPoint(latitude: latitudes.min()!, longitude: longitudes.min()!),
            GeoPoint(latitude: latitudes.max()!, longitude: longitudes.max()!)
        )
    }

    var totalGap: TimeInterval { Double(gaps.reduce(0) { $0 + $1.durationMS }) / 1000 }
}
