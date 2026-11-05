import CairnProtocol
import Foundation

/// One outing, as the server publishes it (`sync/v1` §12).
///
/// All values on the wire are integers: timestamps in epoch milliseconds, speeds in cm/s,
/// distance in whole metres. They are converted once, here, so nothing downstream has to
/// remember which unit a number is in.
///
/// **A trip is an outing, not a boot.** The identity is `<vehicle_id>:<started_ms>`, and the
/// spec is explicit about what that costs a consumer: a trip can be re-keyed when a bundle
/// covering an earlier part of the same outing arrives late, and a trip can absorb a later one
/// when the gap between them turns out to be shorter than the producer's threshold. Both leave
/// a stale id behind rather than contradicting it, so **reconciling by id alone shows one trip
/// twice**. `TripBook` reconciles by overlapping span, which is what the spec asks for.
public struct TripSummary: Identifiable, Sendable, Equatable, Hashable, Codable {
    public let id: String
    public let vehicleID: String
    public let bootID: String
    public let deviceID: String
    public let startedAt: Date
    public let endedAt: Date
    /// Wall clock from first observation to last, including the stops inside the outing.
    public let duration: TimeInterval
    /// Only the moving parts.
    public let driving: TimeInterval
    /// How many drives the outing contains.
    public let legCount: Int
    public let distanceMetres: Double
    public let maxGNSSSpeedKph: Double?
    public let maxOBDSpeedKph: Double?
    public let maxRPM: Int?
    public let obdSamples: Int
    public let gnssSamples: Int
    public let boostSamples: Int
    public let gapCount: Int
    public let gapDuration: TimeInterval
    public let bundleCount: Int
    public let decoderVersion: Int
    /// The `server_sequence` this arrived at, so a later record supersedes an earlier one even
    /// when the clocks disagree.
    public let sequence: Int64

    public var span: ClosedRange<Date> { startedAt...max(startedAt, endedAt) }

    /// Metres per second over the moving part, which is the honest average: dividing by the
    /// wall clock would call a trip with a twenty-minute stop in it slow.
    public var averageDrivingSpeedKph: Double? {
        guard driving >= 30, distanceMetres > 0 else { return nil }
        return distanceMetres / driving * 3.6
    }

    /// The fastest the car went, from whichever source saw it. The OBD figure comes from the
    /// car's own speedometer and the GNSS one from the receiver; they disagree by a few per
    /// cent and the larger is the one worth showing.
    public var topSpeedKph: Double? {
        [maxGNSSSpeedKph, maxOBDSpeedKph].compactMap { $0 }.max()
    }

    /// Whether this looks like a drive at all. A dongle powered on a bench publishes outings
    /// of a few metres.
    public var isBench: Bool { distanceMetres < 100 && driving < 120 }

    public init(
        id: String, vehicleID: String, bootID: String = "", deviceID: String = "",
        startedAt: Date, endedAt: Date, duration: TimeInterval, driving: TimeInterval,
        legCount: Int = 1, distanceMetres: Double,
        maxGNSSSpeedKph: Double? = nil, maxOBDSpeedKph: Double? = nil, maxRPM: Int? = nil,
        obdSamples: Int = 0, gnssSamples: Int = 0, boostSamples: Int = 0,
        gapCount: Int = 0, gapDuration: TimeInterval = 0,
        bundleCount: Int = 1, decoderVersion: Int = 3, sequence: Int64 = 0
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.bootID = bootID
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.driving = driving
        self.legCount = legCount
        self.distanceMetres = distanceMetres
        self.maxGNSSSpeedKph = maxGNSSSpeedKph
        self.maxOBDSpeedKph = maxOBDSpeedKph
        self.maxRPM = maxRPM
        self.obdSamples = obdSamples
        self.gnssSamples = gnssSamples
        self.boostSamples = boostSamples
        self.gapCount = gapCount
        self.gapDuration = gapDuration
        self.bundleCount = bundleCount
        self.decoderVersion = decoderVersion
        self.sequence = sequence
    }

    /// From a pulled `trip_summary` entity. Returns nil when a required integer is missing or
    /// is not an integer: a trip with no start is not a trip, and the spec says every value
    /// here is an integer, so a float is a producer this build does not understand.
    public init?(entity id: String, vehicleID: String, data: JSONValue, sequence: Int64) {
        guard case .object(let fields) = data else { return nil }

        /// `JSONValue` keeps an integer an integer, which matters here: `sync/v1` §4.1 says
        /// every value in this entity is one, so a float is a producer this build does not
        /// understand rather than a number to round.
        func integer(_ key: String) -> Int64? {
            guard case .int(let value)? = fields[key] else { return nil }
            return value
        }
        func text(_ key: String) -> String {
            if case .string(let value)? = fields[key] { return value }
            return ""
        }
        /// `0xFFFF`-style "unknown" does not appear here; the producer omits what it has not
        /// got, so an absent maximum is an absent maximum and not a zero.
        func optionalInteger(_ key: String) -> Int64? {
            guard let value = integer(key), value > 0 else { return nil }
            return value
        }

        guard let started = integer("started_ms") else { return nil }
        let ended = integer("ended_ms") ?? started
        self.init(
            id: id,
            vehicleID: vehicleID,
            bootID: text("boot_id"),
            deviceID: text("device_id"),
            startedAt: Date(timeIntervalSince1970: Double(started) / 1000),
            endedAt: Date(timeIntervalSince1970: Double(ended) / 1000),
            duration: Double(integer("duration_ms") ?? (ended - started)) / 1000,
            driving: Double(integer("driving_ms") ?? 0) / 1000,
            legCount: Int(integer("leg_count") ?? 1),
            distanceMetres: Double(integer("distance_m") ?? 0),
            maxGNSSSpeedKph: optionalInteger("max_gnss_speed_cmps").map { Double($0) * 0.036 },
            maxOBDSpeedKph: optionalInteger("max_obd_speed_cmps").map { Double($0) * 0.036 },
            maxRPM: optionalInteger("max_rpm").map(Int.init),
            obdSamples: Int(integer("obd_samples") ?? 0),
            gnssSamples: Int(integer("gnss_samples") ?? 0),
            boostSamples: Int(integer("boost_samples") ?? 0),
            gapCount: Int(integer("gap_count") ?? 0),
            gapDuration: Double(integer("gap_duration_ms") ?? 0) / 1000,
            bundleCount: Int(integer("bundle_count") ?? 1),
            decoderVersion: Int(integer("decoder_version") ?? 0),
            sequence: sequence
        )
    }
}

/// A car, as the server publishes it.
public struct Vehicle: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let vinLast4: String
    public let engineCode: String
    public let archived: Bool

    public init(id: String, displayName: String, vinLast4: String = "", engineCode: String = "", archived: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.vinLast4 = vinLast4
        self.engineCode = engineCode
        self.archived = archived
    }

    public init?(entity id: String, data: JSONValue) {
        guard case .object(let fields) = data else { return nil }
        func text(_ key: String) -> String {
            if case .string(let value)? = fields[key] { return value }
            return ""
        }
        var archived = false
        if case .bool(let value)? = fields["archived"] { archived = value }
        self.init(
            id: id,
            displayName: text("display_name"),
            vinLast4: text("vin_last4"),
            engineCode: text("engine_code"),
            archived: archived
        )
    }
}

/// Which dongle is in which car, and when. One dongle moves between two cars here, so this is
/// how a trip gets attributed.
public struct Assignment: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let vehicleID: String
    public let deviceID: String
    public let open: Bool
    public let startsAt: Date?

    public init(id: String, vehicleID: String, deviceID: String, open: Bool, startsAt: Date?) {
        self.id = id
        self.vehicleID = vehicleID
        self.deviceID = deviceID
        self.open = open
        self.startsAt = startsAt
    }

    public init?(entity id: String, vehicleID: String, data: JSONValue) {
        guard case .object(let fields) = data else { return nil }
        func text(_ key: String) -> String {
            if case .string(let value)? = fields[key] { return value }
            return ""
        }
        var open = false
        if case .bool(let value)? = fields["open"] { open = value }
        self.init(
            id: id,
            vehicleID: vehicleID.isEmpty ? text("vehicle_id") : vehicleID,
            deviceID: text("device_id"),
            open: open,
            startsAt: ServerTimestamp.parse(text("starts_at"))
        )
    }
}
