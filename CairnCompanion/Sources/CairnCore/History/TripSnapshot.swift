import Foundation

/// A trip record from the server's `cairn-tsdb`. This is the dongle's authoritative view of a trip,
/// as opposed to `DriveSession` which is what the phone observed.
public struct TripSnapshot: Codable, Identifiable, Sendable, Equatable {
    /// boot_id from the dongle — one power cycle = one trip.
    public let id: String
    /// The `vehicle_id:started_ms` format id from `trip_summary`; nil when read from the older
    /// `drive_summary` table.
    public var tripId: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: TimeInterval
    /// Seconds the dongle reported as driving (leg transitions); nil when not available.
    public var drivingSeconds: TimeInterval?

    /// Top GNSS-derived speed (from the `position` table or `max_gnss_speed_mps`).
    public var maxSpeedKph: Int?
    /// Top OBD-reported speed (from `max_obd_speed_kph` in `trip_summary`).
    public var maxObdSpeedKph: Int?
    public var maxRpm: Int?
    public var obdSamples: Int
    public var gnssSamples: Int
    public var fixSamples: Int
    public var phoneSamples: Int
    public var boostSamples: Int
    public var gapCount: Int
    public var gapDurationMs: Int
    /// Longest single GNSS gap in milliseconds.
    public var maxGapMs: Int?
    /// How many legs the dongle recorded (nil when unknown).
    public var legCount: Int?
    public var warnings: String?

    public var startLat: Double?
    public var startLon: Double?

    /// Metres along the dongle's GNSS track (fixes no more than 5 s apart), when the snapshot holds positions.
    public var distanceMeters: Double?
    /// The dongle's track, thinned for drawing. Empty when the snapshot has no positions for this trip.
    public var route: [RoutePoint] = []
    /// MAF and lambda moments for a fuel estimate; empty when the dongle caught none.
    public var fuelSamples: [FuelSample] = []

    public var vehicleID: String?
    public var deviceID: String?

    /// When this snapshot was exported by the server.
    public var snapshotAt: Date

    public init(
        id: String, tripId: String? = nil,
        startedAt: Date, endedAt: Date? = nil,
        durationSeconds: TimeInterval,
        drivingSeconds: TimeInterval? = nil,
        maxSpeedKph: Int? = nil, maxObdSpeedKph: Int? = nil,
        maxRpm: Int? = nil,
        obdSamples: Int = 0, gnssSamples: Int = 0,
        fixSamples: Int = 0, phoneSamples: Int = 0,
        boostSamples: Int = 0,
        gapCount: Int = 0, gapDurationMs: Int = 0,
        maxGapMs: Int? = nil, legCount: Int? = nil,
        warnings: String? = nil,
        startLat: Double? = nil, startLon: Double? = nil,
        vehicleID: String? = nil, deviceID: String? = nil,
        snapshotAt: Date = Date()
    ) {
        self.id = id
        self.tripId = tripId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.drivingSeconds = drivingSeconds
        self.maxSpeedKph = maxSpeedKph
        self.maxObdSpeedKph = maxObdSpeedKph
        self.maxRpm = maxRpm
        self.obdSamples = obdSamples
        self.gnssSamples = gnssSamples
        self.fixSamples = fixSamples
        self.phoneSamples = phoneSamples
        self.boostSamples = boostSamples
        self.gapCount = gapCount
        self.gapDurationMs = gapDurationMs
        self.maxGapMs = maxGapMs
        self.legCount = legCount
        self.warnings = warnings
        self.startLat = startLat
        self.startLon = startLon
        self.vehicleID = vehicleID
        self.deviceID = deviceID
        self.snapshotAt = snapshotAt
    }

    public var gnssGapSeconds: TimeInterval {
        Double(gapDurationMs) / 1000.0
    }

    public var hasLocation: Bool {
        startLat != nil && startLon != nil
    }
}

/// One place along a track, for drawing a route.
public struct RoutePoint: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Combined view for the History tab: a phone-observed session optionally matched with a server trip.
public struct HistoryEntry: Identifiable, Sendable {
    public let id: String
    public var phoneSession: DriveSession?
    public var serverTrip: TripSnapshot?

    public init(phoneSession: DriveSession? = nil, serverTrip: TripSnapshot? = nil) {
        if let s = phoneSession { self.id = s.id.uuidString }
        else if let t = serverTrip { self.id = t.id }
        else { self.id = UUID().uuidString }
        self.phoneSession = phoneSession
        self.serverTrip = serverTrip
    }

    public var startedAt: Date {
        phoneSession?.startedAt ?? serverTrip?.startedAt ?? .distantPast
    }

    public var isOnPhoneOnly: Bool { phoneSession != nil && serverTrip == nil }
    public var isOnServerOnly: Bool { phoneSession == nil && serverTrip != nil }
    public var isMatched: Bool { phoneSession != nil && serverTrip != nil }

    public var syncLabel: String? {
        if serverTrip != nil { return nil }
        if let session = phoneSession {
            switch session.serverState {
            case .unknown: return nil
            case .pendingSync: return "Waiting to sync"
            case .uploaded: return "Uploaded, processing"
            case .consumed: return nil
            }
        }
        return nil
    }
}
