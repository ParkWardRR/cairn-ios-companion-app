import CairnCore
import DuckDB
import Foundation
import os

actor SnapshotStore {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "store")
    private var database: Database?
    private var connection: Connection?

    func load(parquetDir: URL, tables: [String]) throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()

        for table in tables {
            let path = parquetDir.appendingPathComponent("\(table).parquet").path
            guard FileManager.default.fileExists(atPath: path) else {
                Self.log.warning("parquet file missing: \(table)")
                continue
            }
            try conn.execute("""
                CREATE TABLE \(table) AS SELECT * FROM read_parquet('\(path)')
            """)
        }

        self.database = db
        self.connection = conn
        Self.log.notice("loaded \(tables.count) tables from snapshot")
    }

    func trips() throws -> [TripSnapshot] {
        guard let conn = connection else { return [] }

        let hasTripSummary = (try? conn.query("SELECT 1 FROM trip_summary LIMIT 1")) != nil
        if hasTripSummary {
            return try tripsFromTripSummary(conn)
        }

        let hasDriveSummary = (try? conn.query("SELECT 1 FROM drive_summary LIMIT 1")) != nil
        guard hasDriveSummary else { return [] }
        return try tripsFromDriveSummary(conn)
    }

    /// Read trips from the newer `trip_summary` materialized view.
    private func tripsFromTripSummary(_ conn: Connection) throws -> [TripSnapshot] {
        let sql = """
            SELECT
                boot_id,
                trip_id,
                started_at,
                ended_at,
                duration_ms,
                driving_ms,
                leg_count,
                distance_m,
                max_gnss_speed_mps,
                max_obd_speed_kph,
                max_rpm,
                obd_samples,
                gnss_samples,
                fix_samples,
                boost_samples,
                gap_count,
                gap_duration_ms,
                max_gap_ms,
                vehicle_id,
                device_id
            FROM trip_summary
            ORDER BY started_at DESC
        """

        let result = try conn.query(sql)
        var snapshots: [TripSnapshot] = []

        for i: DBInt in 0..<result.rowCount {
            guard let bootId = strVal(result, col: 0, row: i) else { continue }
            let tripId = strVal(result, col: 1, row: i)
            let startDate = tsVal(result, col: 2, row: i) ?? .distantPast
            let endDate = tsVal(result, col: 3, row: i)
            let durationMs = dblVal(result, col: 4, row: i) ?? 0
            let durationS = durationMs / 1000.0
            let drivingMs = dblVal(result, col: 5, row: i)
            let drivingS = drivingMs.map { $0 / 1000.0 }
            let legCount = i64Val(result, col: 6, row: i)
            let distanceM = dblVal(result, col: 7, row: i)
            let maxGnssMps = dblVal(result, col: 8, row: i)
            let maxGnssKph = maxGnssMps.map { Int(($0 * 3.6).rounded()) }
            let maxObdKph = i64Val(result, col: 9, row: i)
            let maxRpm = i64Val(result, col: 10, row: i)
            let obdSamples = i64Val(result, col: 11, row: i) ?? 0
            let gnssSamples = i64Val(result, col: 12, row: i) ?? 0
            let fixSamples = i64Val(result, col: 13, row: i) ?? 0
            let boostSamples = i64Val(result, col: 14, row: i) ?? 0
            let gapCount = i64Val(result, col: 15, row: i) ?? 0
            let gapDurationMs = i64Val(result, col: 16, row: i) ?? 0
            let maxGapMs = i64Val(result, col: 17, row: i)
            let vehicleID = strVal(result, col: 18, row: i)
            let deviceID = strVal(result, col: 19, row: i)

            var snapshot = TripSnapshot(
                id: bootId,
                tripId: tripId,
                startedAt: startDate,
                endedAt: endDate ?? startDate.addingTimeInterval(durationS),
                durationSeconds: durationS,
                drivingSeconds: drivingS,
                maxSpeedKph: maxGnssKph,
                maxObdSpeedKph: maxObdKph,
                maxRpm: maxRpm,
                obdSamples: obdSamples,
                gnssSamples: gnssSamples,
                fixSamples: fixSamples,
                boostSamples: boostSamples,
                gapCount: gapCount,
                gapDurationMs: gapDurationMs,
                maxGapMs: maxGapMs,
                legCount: legCount,
                vehicleID: vehicleID,
                deviceID: deviceID,
                snapshotAt: Foundation.Date()
            )
            if let d = distanceM, d > 0 { snapshot.distanceMeters = d }
            snapshots.append(snapshot)
        }
        enrich(&snapshots, conn)
        return snapshots
    }

    /// Read trips from the older `drive_summary` table (backwards compat).
    private func tripsFromDriveSummary(_ conn: Connection) throws -> [TripSnapshot] {
        let hasPosition = (try? conn.query("SELECT 1 FROM position LIMIT 1")) != nil
        let hasVehicle = hasColumn(conn, table: "drive_summary", column: "vehicle_id")
        let hasDevice = hasColumn(conn, table: "drive_summary", column: "device_id")

        let vehicleCol = hasVehicle ? "d.vehicle_id" : "NULL::VARCHAR AS vehicle_id"
        let deviceCol = hasDevice ? "d.device_id" : "NULL::VARCHAR AS device_id"

        let sql: String
        if hasPosition {
            sql = """
                SELECT
                    d.boot_id,
                    d.duration_s,
                    d.max_speed_kph,
                    d.max_rpm,
                    d.obd_samples,
                    d.gnss_samples,
                    d.fix_samples,
                    d.phone_samples,
                    d.gap_count,
                    d.gap_duration_ms,
                    d.warnings,
                    p.observed_at,
                    p.lat,
                    p.lon,
                    \(vehicleCol),
                    \(deviceCol)
                FROM drive_summary d
                LEFT JOIN (
                    SELECT boot_id, observed_at, lat, lon
                    FROM (
                        SELECT *, row_number() OVER (
                            PARTITION BY boot_id ORDER BY mono_ms
                        ) AS rn
                        FROM position
                        WHERE coalesce(source_flags, 0) & 32 = 0
                    )
                    WHERE rn = 1
                ) p USING (boot_id)
                ORDER BY p.observed_at DESC NULLS LAST
            """
        } else {
            sql = """
                SELECT
                    boot_id,
                    duration_s,
                    max_speed_kph,
                    max_rpm,
                    obd_samples,
                    gnss_samples,
                    fix_samples,
                    phone_samples,
                    gap_count,
                    gap_duration_ms,
                    warnings,
                    NULL::TIMESTAMP AS observed_at,
                    NULL::DOUBLE AS lat,
                    NULL::DOUBLE AS lon,
                    \(hasVehicle ? "vehicle_id" : "NULL::VARCHAR AS vehicle_id"),
                    \(hasDevice ? "device_id" : "NULL::VARCHAR AS device_id")
                FROM drive_summary
            """
        }

        let result = try conn.query(sql)
        var snapshots: [TripSnapshot] = []

        for i: DBInt in 0..<result.rowCount {
            guard let bootId = strVal(result, col: 0, row: i) else { continue }
            let durationS = dblVal(result, col: 1, row: i) ?? 0

            let startDate: Foundation.Date
            if let ts = tsVal(result, col: 11, row: i) {
                startDate = ts
            } else {
                startDate = .distantPast
            }

            snapshots.append(TripSnapshot(
                id: bootId,
                startedAt: startDate,
                endedAt: startDate.addingTimeInterval(durationS),
                durationSeconds: durationS,
                maxSpeedKph: i16Val(result, col: 2, row: i),
                maxRpm: i16Val(result, col: 3, row: i),
                obdSamples: i64Val(result, col: 4, row: i) ?? 0,
                gnssSamples: i64Val(result, col: 5, row: i) ?? 0,
                fixSamples: i64Val(result, col: 6, row: i) ?? 0,
                phoneSamples: i64Val(result, col: 7, row: i) ?? 0,
                gapCount: i64Val(result, col: 8, row: i) ?? 0,
                gapDurationMs: i64Val(result, col: 9, row: i) ?? 0,
                warnings: strVal(result, col: 10, row: i),
                startLat: dblVal(result, col: 12, row: i),
                startLon: dblVal(result, col: 13, row: i),
                vehicleID: strVal(result, col: 14, row: i),
                deviceID: strVal(result, col: 15, row: i),
                snapshotAt: Foundation.Date()
            ))
        }
        enrich(&snapshots, conn)
        return snapshots
    }

    /// Distance, a route to draw and the MAF samples behind a fuel estimate, per trip. Each is optional:
    /// a snapshot without the table or column just leaves the trip without it.
    private nonisolated func enrich(_ snapshots: inout [TripSnapshot], _ conn: Connection) {
        var index: [String: Int] = [:]
        for (i, snapshot) in snapshots.enumerated() { index[snapshot.id] = i }

        // Metres from the dongle's own GNSS speed over each interval (a gap over 10 s counts as 10 s), the
        // way the dashboard's trip page does; position jitter while parked would add distance that was not driven.
        if let r = try? conn.query("""
            SELECT boot_id, coalesce(sum(speed_mps * least(lead_ms - mono_ms, 10000) / 1000.0), 0) AS distance_m
            FROM (
                SELECT boot_id, mono_ms, speed_mps,
                       lead(mono_ms) OVER (PARTITION BY boot_id ORDER BY mono_ms) AS lead_ms
                FROM position
                WHERE speed_mps IS NOT NULL AND coalesce(source_flags, 0) & 32 = 0
            ) WHERE lead_ms IS NOT NULL
            GROUP BY boot_id
        """) {
            for row in 0..<r.rowCount {
                if let id = strVal(r, col: 0, row: row), let i = index[id], let metres = dblVal(r, col: 1, row: row), metres > 0 {
                    snapshots[i].distanceMeters = metres
                }
            }
        }

        // about 120 places per trip is plenty for a thumbnail
        if let r = try? conn.query("""
            SELECT boot_id, lat, lon FROM (
                SELECT boot_id, lat, lon,
                       row_number() OVER (PARTITION BY boot_id ORDER BY mono_ms) AS rn,
                       count(*) OVER (PARTITION BY boot_id) AS n
                FROM position
                WHERE lat != 0 AND lon != 0 AND fix_type > 0 AND coalesce(source_flags, 0) & 32 = 0
            ) WHERE rn % greatest(1, n // 120) = 0 OR rn = 1 OR rn = n
            ORDER BY boot_id, rn
        """) {
            for row in 0..<r.rowCount {
                if let id = strVal(r, col: 0, row: row), let i = index[id],
                   let lat = dblVal(r, col: 1, row: row), let lon = dblVal(r, col: 2, row: row) {
                    snapshots[i].route.append(RoutePoint(latitude: lat, longitude: lon))
                }
            }
        }

        // MAF is only polled on some rounds, so each airflow reading is paired with the speed just before it
        if let r = try? conn.query("""
            SELECT b.boot_id, o.speed_kph, b.maf_cgps, b.lambda_ratio
            FROM boost b
            ASOF JOIN obd o ON b.boot_id = o.boot_id AND b.mono_ms >= o.mono_ms
            WHERE b.maf_cgps IS NOT NULL AND b.lambda_ratio IS NOT NULL AND o.speed_kph IS NOT NULL
            ORDER BY b.boot_id, b.mono_ms
        """) {
            for row in 0..<r.rowCount {
                if let id = strVal(r, col: 0, row: row), let i = index[id],
                   let kph = dblVal(r, col: 1, row: row), let maf = dblVal(r, col: 2, row: row), let lambda = dblVal(r, col: 3, row: row) {
                    snapshots[i].fuelSamples.append(FuelSample(speedKph: kph, mafCgps: maf, lambda: lambda))
                }
            }
        }
    }

    func close() {
        connection = nil
        database = nil
    }

    // MARK: - Schema helpers

    private nonisolated func hasColumn(_ conn: Connection, table: String, column: String) -> Bool {
        guard let r = try? conn.query("SELECT \(column) FROM \(table) LIMIT 0") else { return false }
        return true
    }

    // MARK: - Column helpers

    private nonisolated func strVal(_ r: ResultSet, col: Int, row: DBInt) -> String? {
        (try? r[DBInt(col)].cast(to: String.self)[row])
    }

    private nonisolated func dblVal(_ r: ResultSet, col: Int, row: DBInt) -> Double? {
        (try? r[DBInt(col)].cast(to: Double.self)[row])
    }

    private nonisolated func i16Val(_ r: ResultSet, col: Int, row: DBInt) -> Int? {
        guard let v = try? r[DBInt(col)].cast(to: Int16.self)[row] else { return nil }
        return Int(v)
    }

    private nonisolated func i64Val(_ r: ResultSet, col: Int, row: DBInt) -> Int? {
        guard let v = try? r[DBInt(col)].cast(to: Int64.self)[row] else { return nil }
        return Int(v)
    }

    private nonisolated func tsVal(_ r: ResultSet, col: Int, row: DBInt) -> Foundation.Date? {
        guard let ts = try? r[DBInt(col)].cast(to: Timestamp.self)[row] else { return nil }
        return Foundation.Date(timeIntervalSince1970: Double(ts.microseconds) / 1_000_000)
    }
}
