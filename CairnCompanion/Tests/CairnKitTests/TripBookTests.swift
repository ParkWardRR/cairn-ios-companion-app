import CairnKit
import CairnProtocol
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let car = "303132333435363738393a3b3c3d3e3f"

private func trip(
    start: TimeInterval, length: TimeInterval, distance: Double = 5000,
    vehicle: String = car, sequence: Int64 = 1, driving: TimeInterval? = nil
) -> TripSummary {
    let began = t0.addingTimeInterval(start)
    return TripSummary(
        id: "\(vehicle):\(Int(began.timeIntervalSince1970 * 1000))",
        vehicleID: vehicle,
        startedAt: began,
        endedAt: began.addingTimeInterval(length),
        duration: length,
        driving: driving ?? length,
        distanceMetres: distance,
        sequence: sequence
    )
}

@Suite("TripBook: one outing, however it was published")
struct TripBookTests {
    @Test("a later record for the same id supersedes the earlier one")
    func supersede() {
        var book = TripBook()
        book.apply(trip(start: 0, length: 600, distance: 5000, sequence: 1))
        book.apply(trip(start: 0, length: 900, distance: 7000, sequence: 2))
        #expect(book.trips.count == 1)
        #expect(book.trips.first?.distanceMetres == 7000)
    }

    @Test("an older record arriving late does not undo a newer one")
    func outOfOrder() {
        // server_sequence decides, not arrival and not the clock: two records can carry the
        // same `at`.
        var book = TripBook()
        book.apply(trip(start: 0, length: 900, distance: 7000, sequence: 9))
        book.apply(trip(start: 0, length: 600, distance: 5000, sequence: 2))
        #expect(book.trips.first?.distanceMetres == 7000)
    }

    @Test("a re-keyed trip is one trip, not two")
    func reKeyed() {
        // A bundle covering an earlier part of the same outing arrives late. The start moves
        // earlier, the trip is republished under a new id, and the old id is left stale
        // rather than tombstoned. A consumer keyed on id alone shows the drive twice, the
        // second time with a start the car never had — which is why sync/v1 §12 says to
        // reconcile by overlapping span.
        var book = TripBook()
        book.apply(trip(start: 600, length: 900, distance: 7000, sequence: 1))
        book.apply(trip(start: 0, length: 1500, distance: 9000, sequence: 2))

        #expect(book.allRecords.count == 2, "both records are kept; neither was withdrawn")
        #expect(book.trips.count == 1, "but there was only ever one drive")
        #expect(book.trips.first?.distanceMetres == 9000, "and it is the newer account of it")
    }

    @Test("a trip that absorbed a later one is one trip")
    func absorbed() {
        // The gap between two published trips turns out to be shorter than the producer's
        // threshold once the data that fell in it arrives, so they become one under the
        // earlier id.
        var book = TripBook()
        book.apply(trip(start: 0, length: 600, sequence: 1))
        book.apply(trip(start: 1200, length: 600, sequence: 2))
        #expect(book.trips.count == 2, "two separate outings, for now")

        book.apply(trip(start: 0, length: 1800, distance: 14_000, sequence: 3))
        #expect(book.trips.count == 1, "and now one")
        #expect(book.trips.first?.distanceMetres == 14_000)
    }

    @Test("trips that do not overlap stay separate, even back to back")
    func adjacent() {
        var book = TripBook()
        book.apply(trip(start: 0, length: 600, sequence: 1))
        book.apply(trip(start: 601, length: 600, sequence: 2))
        #expect(book.trips.count == 2)
    }

    @Test("two cars' trips never merge, whatever their clocks say")
    func perVehicle() {
        var book = TripBook()
        book.apply(trip(start: 0, length: 900, vehicle: "aaaa", sequence: 1))
        book.apply(trip(start: 0, length: 900, vehicle: "bbbb", sequence: 2))
        #expect(book.trips.count == 2, "one dongle moves between two cars here; these are two drives")
    }

    @Test("a tombstone removes a trip")
    func tombstone() {
        var book = TripBook()
        let one = trip(start: 0, length: 600)
        book.apply(one)
        #expect(book.trips.count == 1)
        book.removeTrip(one.id)
        #expect(book.trips.isEmpty)
    }

    @Test("newest first, and grouped by day")
    func grouping() {
        var book = TripBook()
        book.apply(trip(start: 0, length: 600))
        book.apply(trip(start: 7200, length: 600))
        book.apply(trip(start: 48 * 3600, length: 600))
        #expect(book.trips.first?.startedAt == t0.addingTimeInterval(48 * 3600))

        let days = TripDay.group(book.trips)
        #expect(days.count == 2)
        #expect(days.first?.trips.count == 1)
        #expect(days.last?.trips.count == 2)
        #expect(days.last?.totalDistanceMetres == 10_000)
    }

    @Test("which car a dongle is in comes from its open assignment")
    func assignment() {
        // One dongle, two cars, and the VIN chooses — so "which car" is a question with a
        // time in it and the answer is whichever assignment is open.
        var book = TripBook()
        book.apply(Vehicle(id: "car428", displayName: "2014 BMW 428i"))
        book.apply(Vehicle(id: "car240", displayName: "2017 BMW M240i"))
        book.apply(Assignment(id: "a1", vehicleID: "car428", deviceID: "dongle",
                              open: false, startsAt: t0))
        book.apply(Assignment(id: "a2", vehicleID: "car240", deviceID: "dongle",
                              open: true, startsAt: t0.addingTimeInterval(86_400)))
        #expect(book.vehicle(forDevice: "dongle")?.displayName == "2017 BMW M240i")
        #expect(book.vehicle(forDevice: "other") == nil)
    }

    @Test("a reset clears everything the server gave and nothing else")
    func reset() {
        var book = TripBook()
        book.apply(trip(start: 0, length: 600))
        book.apply(Vehicle(id: car, displayName: "428i"))
        book.removeAll()
        #expect(book.trips.isEmpty)
        #expect(book.vehicles.isEmpty)
    }
}

@Suite("TripSummary from the wire")
struct TripSummaryDecodingTests {
    private func entity(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    @Test("the integer fields the spec names become the units a person reads")
    func units() {
        // Everything on the wire is an integer: epoch milliseconds, cm/s, whole metres.
        let data = entity([
            "boot_id": .string("b1"), "device_id": .string("d1"),
            "started_ms": .int(1_790_000_000_000), "ended_ms": .int(1_790_000_600_000),
            "duration_ms": .int(600_000), "driving_ms": .int(540_000), "leg_count": .int(3),
            "distance_m": .int(5230),
            "max_gnss_speed_cmps": .int(2410), "max_obd_speed_cmps": .int(2500),
            "max_rpm": .int(6100),
            "obd_samples": .int(300), "gnss_samples": .int(590), "boost_samples": .int(300),
            "gap_count": .int(1), "gap_duration_ms": .int(4000),
            "bundle_count": .int(1), "decoder_version": .int(3),
        ])
        guard let trip = TripSummary(entity: "\(car):1790000000000", vehicleID: car, data: data, sequence: 7) else {
            Issue.record("did not decode"); return
        }
        #expect(trip.startedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(trip.duration == 600)
        #expect(trip.driving == 540)
        #expect(trip.legCount == 3)
        #expect(trip.distanceMetres == 5230)
        // 2410 cm/s is 24.1 m/s is 86.76 km/h.
        #expect(abs((trip.maxGNSSSpeedKph ?? 0) - 86.76) < 0.01)
        #expect(abs((trip.maxOBDSpeedKph ?? 0) - 90.0) < 0.01)
        #expect(trip.topSpeedKph == trip.maxOBDSpeedKph, "the faster of the two sources")
        #expect(trip.maxRPM == 6100)
        #expect(trip.sequence == 7)
        // 5230 m in 540 s is 34.9 km/h, over the moving part and not the wall clock.
        #expect(abs((trip.averageDrivingSpeedKph ?? 0) - 34.87) < 0.1)
    }

    @Test("a trip with no start is not a trip")
    func needsAStart() {
        #expect(TripSummary(entity: "x", vehicleID: car, data: .object([:]), sequence: 1) == nil)
        #expect(TripSummary(entity: "x", vehicleID: car, data: .string("nope"), sequence: 1) == nil)
    }

    @Test("a float where the spec says integer is a producer this build does not understand")
    func rejectsFloats() {
        // sync/v1 §4.1: every value here is an integer. Rounding one would be guessing at
        // what a newer producer meant.
        let data = entity(["started_ms": .double(1_790_000_000_000.5)])
        #expect(TripSummary(entity: "x", vehicleID: car, data: data, sequence: 1) == nil)
    }

    @Test("an absent maximum is absent, not zero")
    func absentMaxima() {
        let data = entity(["started_ms": .int(1_790_000_000_000), "distance_m": .int(100)])
        let trip = TripSummary(entity: "x", vehicleID: car, data: data, sequence: 1)
        #expect(trip?.maxRPM == nil)
        #expect(trip?.topSpeedKph == nil)
    }

    @Test("a bench run is recognisable as one")
    func bench() {
        let data = entity([
            "started_ms": .int(1_790_000_000_000), "ended_ms": .int(1_790_000_060_000),
            "duration_ms": .int(60_000), "driving_ms": .int(40_000), "distance_m": .int(12),
        ])
        #expect(TripSummary(entity: "x", vehicleID: car, data: data, sequence: 1)?.isBench == true)
    }

    @Test("a vehicle and an assignment decode")
    func otherEntities() {
        let vehicle = Vehicle(entity: car, data: .object([
            "display_name": .string("2014 BMW 428i — N20"),
            "vin_last4": .string("3456"), "archived": .bool(false),
        ]))
        #expect(vehicle?.displayName == "2014 BMW 428i — N20")
        #expect(vehicle?.vinLast4 == "3456")
        #expect(vehicle?.archived == false)

        let assignment = Assignment(entity: "a1", vehicleID: car, data: .object([
            "device_id": .string("101112131415161718191a1b1c1d1e1f"),
            "open": .bool(true), "starts_at": .string("2026-09-21T14:11:50Z"),
        ]))
        #expect(assignment?.open == true)
        #expect(assignment?.deviceID == "101112131415161718191a1b1c1d1e1f")
        #expect(assignment?.startsAt != nil)
    }
}
