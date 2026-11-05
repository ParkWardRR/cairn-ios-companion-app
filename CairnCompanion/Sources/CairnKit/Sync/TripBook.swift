import CairnProtocol
import Foundation

/// Everything the server has published, reconciled.
///
/// The reconciliation is the point and it is not optional. `sync/v1` §12 says a trip's identity
/// is `<vehicle_id>:<started_ms>` and that the identity moves:
///
/// - **A trip can be re-keyed.** A bundle covering an earlier part of the same outing arrives
///   late, the start moves earlier, and the trip is republished under a new id. The old id is
///   stale rather than contradicted — nothing tombstones it.
/// - **A trip can absorb a later one.** Two published trips turn out to be one outing once the
///   data that fell in the gap arrives, and they merge under the earlier id.
///
/// A consumer that keys on id alone shows the same drive twice, with the duplicate claiming a
/// start the car never had. So this keys on **(vehicle, overlapping span)**, which is what the
/// spec calls the safe read, and keeps the newest record of each outing.
public struct TripBook: Sendable, Equatable {
    public private(set) var vehicles: [String: Vehicle] = [:]
    public private(set) var assignments: [String: Assignment] = [:]
    /// By published id, newest record per id.
    private var byID: [String: TripSummary] = [:]

    public init() {}

    // MARK: - Applying what was pulled

    /// A later record for the same id supersedes the earlier one. `server_sequence` decides,
    /// not the clock: two records can carry the same `at`.
    public mutating func apply(_ trip: TripSummary) {
        if let existing = byID[trip.id], existing.sequence > trip.sequence { return }
        byID[trip.id] = trip
    }

    public mutating func apply(_ vehicle: Vehicle) { vehicles[vehicle.id] = vehicle }
    public mutating func apply(_ assignment: Assignment) { assignments[assignment.id] = assignment }

    public mutating func removeTrip(_ id: String) { byID[id] = nil }
    public mutating func removeVehicle(_ id: String) { vehicles[id] = nil }
    public mutating func removeAssignment(_ id: String) { assignments[id] = nil }

    /// Everything server-derived goes, which is what a `410 cursor_reset` demands. The outbox
    /// is somebody else's and is deliberately untouched.
    public mutating func removeAll() {
        byID = [:]
        vehicles = [:]
        assignments = [:]
    }

    // MARK: - Reading it

    /// Every record as published, including the stale ids. For a diagnostics view, not a list.
    public var allRecords: [TripSummary] { Array(byID.values) }

    /// The trips to show: one per outing, newest first.
    ///
    /// Two records of the same vehicle whose spans overlap are the same outing. The one kept is
    /// the one with the higher `server_sequence` — the server's own idea of which it published
    /// later — and failing that the longer one, because a trip that absorbed another is longer
    /// than either part.
    public var trips: [TripSummary] {
        var byVehicle: [String: [TripSummary]] = [:]
        for trip in byID.values { byVehicle[trip.vehicleID, default: []].append(trip) }

        var out: [TripSummary] = []
        for (_, records) in byVehicle {
            var kept: [TripSummary] = []
            for trip in records.sorted(by: { $0.startedAt < $1.startedAt }) {
                if let index = kept.firstIndex(where: { $0.span.overlaps(trip.span) }) {
                    kept[index] = Self.better(kept[index], trip)
                } else {
                    kept.append(trip)
                }
            }
            out += kept
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    /// Of two records of one outing, which to believe.
    static func better(_ a: TripSummary, _ b: TripSummary) -> TripSummary {
        if a.sequence != b.sequence { return a.sequence > b.sequence ? a : b }
        // Same sequence and overlapping: the one that covers more of the outing.
        return a.duration >= b.duration ? a : b
    }

    public func trip(id: String) -> TripSummary? { byID[id] }

    public func vehicleName(_ id: String) -> String {
        vehicles[id]?.displayName.isEmpty == false ? vehicles[id]!.displayName : "Unknown car"
    }

    /// Which car a dongle is in now, by its open assignment. One dongle moves between two cars
    /// here, so "which car" is a question with a time in it.
    public func vehicle(forDevice deviceID: String) -> Vehicle? {
        guard let assignment = assignments.values
            .filter({ $0.deviceID == deviceID && $0.open })
            .max(by: { ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast) })
        else { return nil }
        return vehicles[assignment.vehicleID]
    }
}

/// Trips under a day heading, newest first. What the list shows.
public struct TripDay: Identifiable, Sendable, Equatable {
    public let id: Date
    public let trips: [TripSummary]

    public var totalDistanceMetres: Double { trips.reduce(0) { $0 + $1.distanceMetres } }
    public var totalDuration: TimeInterval { trips.reduce(0) { $0 + $1.duration } }

    public static func group(_ trips: [TripSummary], calendar: Calendar = .current) -> [TripDay] {
        Dictionary(grouping: trips) { calendar.startOfDay(for: $0.startedAt) }
            .map { TripDay(id: $0.key, trips: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.id > $1.id }
    }
}
