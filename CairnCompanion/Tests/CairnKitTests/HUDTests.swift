import Foundation
import Testing
@testable import CairnKit
@testable import CairnProtocol

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func obd(
    rpm: UInt16 = OBDLiveSnapshot.invalidU16,
    speedKphE1: UInt16 = OBDLiveSnapshot.invalidU16,
    throttlePct: UInt8 = 0xFF,
    engineLoadPct: UInt8 = 0xFF,
    coolantTempC: Int16 = OBDLiveSnapshot.invalidI16,
    intakeTempC: Int16 = OBDLiveSnapshot.invalidI16,
    boostKpaE1: Int16 = OBDLiveSnapshot.invalidI16,
    oilTempC: Int16 = OBDLiveSnapshot.invalidI16,
    voltageMv: UInt16 = OBDLiveSnapshot.invalidU16
) -> OBDLiveSnapshot {
    OBDLiveSnapshot(
        rpm: rpm, speedKphE1: speedKphE1, throttlePct: throttlePct, engineLoadPct: engineLoadPct,
        coolantTempC: coolantTempC, intakeTempC: intakeTempC, boostKpaE1: boostKpaE1,
        mafE2: OBDLiveSnapshot.invalidU16, fuelPressureKpa: 0,
        timingAdvE2: OBDLiveSnapshot.invalidI16,
        stft1E2: OBDLiveSnapshot.invalidI16, ltft1E2: OBDLiveSnapshot.invalidI16,
        stft2E2: OBDLiveSnapshot.invalidI16, ltft2E2: OBDLiveSnapshot.invalidI16,
        oilTempC: oilTempC, voltageMv: voltageMv, pidBitmap: 0, ageMs: 0
    )
}

private func status(
    trip: UInt8 = 1, health: UInt16 = 0x0F, batteryMv: UInt16 = 12_400,
    sdFreeMb: UInt16 = 7_300, uptimeS: UInt32 = 1_080
) -> DeviceStatus {
    DeviceStatus(
        tripState: trip, flags: 0, healthBitmap: health,
        batteryMv: batteryMv, sdFreeMb: sdFreeMb, uptimeS: uptimeS
    )
}

/// A link that is up and has been heard from a moment ago.
private func driving(
    obd snapshot: OBDLiveSnapshot? = nil,
    heard: TimeInterval = 1,
    deviceStatus: DeviceStatus? = status()
) -> HUDInput {
    HUDInput(
        link: .ready, stage: "Streaming", isStreaming: true,
        connectedSince: now.addingTimeInterval(-600),
        obd: snapshot, lastOBDAt: snapshot == nil ? nil : now.addingTimeInterval(-heard),
        deviceStatus: deviceStatus,
        lastDeviceStatusAt: deviceStatus == nil ? nil : now.addingTimeInterval(-heard),
        companionStatus: CompanionStatus(
            lastAcceptedSeq: 1_121, acceptedCount: 1_118, rejectedCount: 3, queueDropCount: 0
        ),
        lastStatusAt: now.addingTimeInterval(-heard),
        sentCount: 1_121
    )
}

// MARK: - Freshness

@Test func bestFreshnessTakesTheMostRecentChannel() {
    #expect(Freshness.best(.never, .silent, .live) == .live)
    #expect(Freshness.best(.never, .silent) == .silent)
    #expect(Freshness.best(.never, .never) == .never)
    #expect(Freshness.best(.stale, .silent) == .stale)
}

@Test func aQuietOBDChannelDoesNotReadAsADeadDongle() {
    // A car that answers no OBD PIDs still notifies COMPANION_STATUS at 1 Hz. The dongle is alive.
    var input = driving(obd: nil)
    input.lastStatusAt = now.addingTimeInterval(-1)
    #expect(HUDBuilder.heard(input, now: now).freshness == .live)
    #expect(HUDBuilder.hero(input, now: now).headline == "Recording")
}

// MARK: - Choosing the strip

@Test func theStripOnlyShowsPIDsTheCarAnswers() {
    // Naturally aspirated: no boost tile, ever.
    let kinds = HUDBuilder.gaugeSlots(
        for: obd(rpm: 2_140, speedKphE1: 640, engineLoadPct: 32, coolantTempC: 91, voltageMv: 14_100),
        limit: 5
    )
    #expect(kinds == [.rpm, .coolant, .volts, .speed, .load])
    #expect(!kinds.contains(.boost))
}

@Test func theStripKeepsPriorityOrderAndRespectsTheVehicleLimit() {
    let full = obd(
        rpm: 2_140, speedKphE1: 640, throttlePct: 20, engineLoadPct: 32,
        coolantTempC: 91, intakeTempC: 30, boostKpaE1: 180, oilTempC: 100, voltageMv: 14_100
    )
    #expect(HUDBuilder.gaugeSlots(for: full, limit: 3) == [.rpm, .coolant, .boost])
    #expect(HUDBuilder.gaugeSlots(for: full, limit: 5) == [.rpm, .coolant, .boost, .volts, .speed])
}

@Test func withNoOBDAtAllTheStripFallsBackRatherThanEmptying() {
    #expect(HUDBuilder.gaugeSlots(for: nil, limit: 5) == [.rpm, .coolant, .volts, .speed, .load])
    // A snapshot where the car answered nothing is the same case.
    #expect(HUDBuilder.gaugeSlots(for: obd(), limit: 5) == [.rpm, .coolant, .volts, .speed, .load])
    #expect(HUDBuilder.gaugeSlots(for: nil, limit: 0).count == 1)
}

// MARK: - Holding last-known

@Test func aSilentChannelKeepsItsValueAndStartsAging() {
    let snapshot = obd(rpm: 2_140, coolantTempC: 91)
    let live = HUDBuilder.snapshot(driving(obd: snapshot, heard: 1), now: now, slots: [.rpm, .coolant])
    let held = HUDBuilder.snapshot(driving(obd: snapshot, heard: 14), now: now, slots: [.rpm, .coolant])

    // Same readings, same captions, same needles — only the freshness moved.
    #expect(live.now.gauges.map(\.caption) == held.now.gauges.map(\.caption))
    #expect(live.now.gauges.map(\.fraction) == held.now.gauges.map(\.fraction))
    #expect(live.now.gauges.allSatisfy { $0.freshness == .live })
    #expect(held.now.gauges.allSatisfy { $0.freshness == .silent })
    // Nothing is ever blanked.
    #expect(held.now.gauges.allSatisfy { $0.fraction != nil && $0.caption != "—" })
    // And the strip header says how old it is, so the fade is never ambiguous.
    #expect(held.now.stripTitle == "Live engine — held 14 s")
}

@Test func aPIDTheCarHasNeverAnsweredIsEmptyNotZero() {
    let snapshot = HUDBuilder.snapshot(driving(obd: obd(rpm: 2_140)), now: now, slots: [.rpm, .boost])
    let boost = snapshot.now.gauges[1]
    // An empty dashed track, not a needle resting on zero: those are different claims.
    #expect(boost.fraction == nil)
    #expect(boost.caption == "—")
    #expect(boost.freshness == .never)
    #expect(boost.band == .unknown)
}

// MARK: - The fixed row skeleton

@Test func everySnapshotCarriesTheSameRowsInTheSameOrder() {
    // The CarPlay layer builds rows once and only rewrites them, so the ids a snapshot carries must
    // never depend on the data. If this test fails, a BLE dropout can reload the car's list.
    let cases: [HUDInput] = [
        HUDInput(),
        HUDInput(link: .unavailable, stage: "Bluetooth is off"),
        HUDInput(link: .waiting, stage: "Waiting for Cairn"),
        HUDInput(link: .failed, stage: "Pairing failed"),
        driving(obd: obd(rpm: 2_140, coolantTempC: 91)),
        driving(obd: nil, heard: 40, deviceStatus: nil),
        driving(obd: obd(rpm: 0), heard: 90, deviceStatus: status(trip: 0, health: 0)),
    ]
    for input in cases {
        let snapshot = HUDBuilder.snapshot(input, now: now, slots: [.rpm, .coolant])
        #expect(snapshot.now.rows.map(\.id) == [.acceptance, .phoneFix])
        #expect(snapshot.drive.rows.map(\.id) == [.accepted, .rejected, .queueDrops, .drops])
        #expect(snapshot.device.rows.map(\.id) == [.battery, .storage, .firmware, .bond])
        #expect(snapshot.now.gauges.map(\.kind) == [.rpm, .coolant])
        // Every row and tile always has something to draw, so no row is ever ragged.
        #expect(snapshot.now.rows.allSatisfy { !$0.title.isEmpty })
        #expect(snapshot.device.rows.allSatisfy { !$0.title.isEmpty })
    }
}

// MARK: - Honest status

@Test func recordingIsClaimedOnlyOnTheDongleSOwnFreshWord() {
    #expect(HUDBuilder.hero(driving(), now: now).headline == "Recording")

    // Link up and fixes flowing, but the dongle has not said whether it is logging.
    var mute = driving(deviceStatus: nil)
    mute.isStreaming = true
    #expect(HUDBuilder.hero(mute, now: now).headline == "Recording unknown")

    // It said "driving" fourteen seconds ago. That is no longer evidence of anything.
    let stale = driving(heard: 14)
    #expect(HUDBuilder.hero(stale, now: now).headline == "Dongle silent 14 s")

    // The channel is merely slow, not gone: the claim stands but the age is shown.
    var slow = driving(heard: 5)
    slow.lastStatusAt = now.addingTimeInterval(-5)
    #expect(HUDBuilder.hero(slow, now: now).headline == "Recording")
    #expect(HUDBuilder.hero(slow, now: now).freshness == .stale)
}

@Test func theDeviceSOwnTripPhaseIsReportedVerbatim() {
    #expect(HUDBuilder.hero(driving(deviceStatus: status(trip: 0)), now: now).headline == "Device idle")
    #expect(HUDBuilder.hero(driving(deviceStatus: status(trip: 2)), now: now).headline == "Device paused")
    #expect(HUDBuilder.hero(driving(deviceStatus: status(trip: 0xFF)), now: now).headline == "Recording unknown")
}

@Test func carPlayNeverPresentsItselfAsTheReasonRecordingStopped() {
    // Auto-connect off is the user's choice on the phone; the car screen says so and nothing more.
    let hero = HUDBuilder.hero(HUDInput(link: .off, stage: "Off"), now: now)
    #expect(hero.headline == "Auto-connect off")
    #expect(hero.band == .unknown)
    #expect(hero.stones == Array(repeating: .unreported, count: 4))
}

@Test func silenceIsNamedWithItsAgeAndSaysTheReadingsAreHeld() {
    let hero = HUDBuilder.hero(driving(obd: obd(rpm: 2_140), heard: 74), now: now)
    #expect(hero.headline == "Dongle silent 1 m 14 s")
    #expect(hero.band == .alarm)
    #expect(hero.freshness == .silent)
    #expect(hero.detail.contains("Holding"))
}

// MARK: - The keystone

@Test func theKeystoneStacksTheDongleSFourHealthBits() {
    // Bottom to top: SD, IMU, GNSS, OBD.
    #expect(HUDBuilder.stones(status(health: 0x0F)) == [.ok, .ok, .ok, .ok])
    #expect(HUDBuilder.stones(status(health: 0x0F ^ 0x08)) == [.ok, .fault, .ok, .ok])
    #expect(HUDBuilder.stones(nil) == [.unreported, .unreported, .unreported, .unreported])
}

@Test func aDongleThatIsUpButLoggingNothingUsefulAlarms() {
    // OBD and GPS both down: the link is perfect and the trip is worthless.
    let blind = driving(deviceStatus: status(health: 0x0C))
    #expect(HUDBuilder.hero(blind, now: now).band == .alarm)
    // One subsystem down is a caution, not an alarm.
    let noIMU = driving(deviceStatus: status(health: 0x07))
    #expect(HUDBuilder.hero(noIMU, now: now).band == .caution)
    #expect(HUDBuilder.snapshot(noIMU, now: now).device.hero.headline == "IMU not reporting")
    #expect(HUDBuilder.snapshot(driving(), now: now).device.hero.headline == "All systems good")
}

// MARK: - Bands

@Test func bandsFlagTheThingsWorthLookingUpFor() {
    func band(_ snapshot: OBDLiveSnapshot, _ kind: HUDGauge.Kind) -> HUDBand {
        HUDBuilder.snapshot(driving(obd: snapshot), now: now, slots: [kind]).now.gauges[0].band
    }
    #expect(band(obd(coolantTempC: 91), .coolant) == .nominal)
    #expect(band(obd(coolantTempC: 108), .coolant) == .caution)
    #expect(band(obd(coolantTempC: 118), .coolant) == .alarm)
    #expect(band(obd(coolantTempC: 20), .coolant) == .caution)   // stone cold is worth knowing too
    #expect(band(obd(rpm: 2_140), .rpm) == .nominal)
    #expect(band(obd(rpm: 5_800), .rpm) == .caution)
    #expect(band(obd(rpm: 6_800), .rpm) == .alarm)
    #expect(band(obd(voltageMv: 14_100), .volts) == .nominal)
    #expect(band(obd(voltageMv: 11_900), .volts) == .caution)
    #expect(band(obd(voltageMv: 11_200), .volts) == .alarm)
    #expect(band(obd(voltageMv: 15_400), .volts) == .alarm)
    // Cairn does not know which engine this is, so it asserts no safe boost ceiling.
    #expect(band(obd(boostKpaE1: 1_800), .boost) == .nominal)
}

// MARK: - Units

@Test func unitsFollowTheDriverSLocale() {
    func caption(_ units: HUDUnits, _ kind: HUDGauge.Kind, _ snapshot: OBDLiveSnapshot) -> String {
        var input = driving(obd: snapshot)
        input.units = units
        return HUDBuilder.snapshot(input, now: now, slots: [kind]).now.gauges[0].caption
    }
    #expect(caption(.metric, .speed, obd(speedKphE1: 1_000)) == "100 km/h")
    #expect(caption(.imperial, .speed, obd(speedKphE1: 1_000)) == "62 mph")
    #expect(caption(.metric, .coolant, obd(coolantTempC: 91)) == "91 °C")
    #expect(caption(.imperial, .coolant, obd(coolantTempC: 91)) == "196 °F")
    #expect(caption(.metric, .boost, obd(boostKpaE1: 180)) == "18 kPa")
    #expect(caption(.imperial, .boost, obd(boostKpaE1: 180)) == "2.6 psi")
    // Gauge faces carry no thousands separator: the caption is drawn inside the ring and every
    // character it does not need is a point of font size it keeps.
    #expect(caption(.metric, .rpm, obd(rpm: 2_140)) == "2140")
    #expect(caption(.imperial, .rpm, obd(rpm: 2_140)) == "2140")
}

// MARK: - Image keys

@Test func anUnmovedNeedleDoesNotAskForANewImage() {
    // This is what keeps `setImage` off the main thread's back: identical keys mean no redraw.
    let snapshot = obd(rpm: 2_140, coolantTempC: 91)
    let first = HUDBuilder.snapshot(driving(obd: snapshot), now: now, slots: [.rpm, .coolant])
    let second = HUDBuilder.snapshot(driving(obd: snapshot), now: now, slots: [.rpm, .coolant])
    #expect(first.now.gauges.map(\.imageKey) == second.now.gauges.map(\.imageKey))
    #expect(first.now.rows.map(\.imageKey) == second.now.rows.map(\.imageKey))

    // A needle that has actually moved does.
    let moved = HUDBuilder.snapshot(
        driving(obd: obd(rpm: 4_200, coolantTempC: 91)), now: now, slots: [.rpm, .coolant]
    )
    #expect(moved.now.gauges[0].imageKey != first.now.gauges[0].imageKey)
    #expect(moved.now.gauges[1].imageKey == first.now.gauges[1].imageKey)

    // Going silent changes the pixels even though the reading has not.
    let silent = HUDBuilder.snapshot(driving(obd: snapshot, heard: 14), now: now, slots: [.rpm, .coolant])
    #expect(silent.now.gauges[0].imageKey != first.now.gauges[0].imageKey)
}

@Test func needlesQuantiseToABoundedNumberOfImages() {
    // 1 rpm of movement must not redraw; a visible move must.
    func key(_ rpm: UInt16) -> HUDGaugeKey {
        HUDBuilder.snapshot(driving(obd: obd(rpm: rpm)), now: now, slots: [.rpm]).now.gauges[0].imageKey
    }
    #expect(key(2_140) == key(2_141))
    #expect(key(2_140) != key(2_400))
    #expect(HUDGauge.buckets == 48)
}

// MARK: - Rows

@Test func acceptanceRowShowsTheReceiptsAndFlagsBacklog() {
    let row = HUDBuilder.snapshot(driving(), now: now).now.rows[0]
    #expect(row.title == "Accepted 1,118 fixes")
    #expect(row.detail.contains("3 rejected"))
    #expect(row.detail.contains("1 s ago"))
    #expect(row.band == .caution)   // three rejected is worth a look

    var backlog = driving()
    backlog.companionStatus = CompanionStatus(
        lastAcceptedSeq: 10, acceptedCount: 10, rejectedCount: 0, queueDropCount: 0
    )
    backlog.sentCount = 40
    let flagged = HUDBuilder.snapshot(backlog, now: now).now.rows[0]
    #expect(flagged.detail.contains("30 in flight"))
    #expect(flagged.band == .caution)
}

@Test func withNoDongleTheRowsSayWhyRatherThanShowingZero() {
    let snapshot = HUDBuilder.snapshot(HUDInput(link: .waiting, stage: "Waiting for Cairn"), now: now)
    #expect(snapshot.now.rows[0].title == "No fixes accepted yet")
    #expect(snapshot.now.rows[0].freshness == .never)
    #expect(snapshot.device.rows[0].title == "Supply not reported")
    #expect(snapshot.device.rows[2].title == "Firmware not reported")
}

@Test func locationTroubleIsReportedAsTheHUDSOwnProblem() {
    var denied = driving()
    denied.locationMessage = "Location access is off for Cairn"
    let row = HUDBuilder.snapshot(denied, now: now).now.rows[1]
    #expect(row.title == "Location unavailable")
    #expect(row.detail == "Location access is off for Cairn")
    #expect(row.band == .alarm)
}

@Test func deviceDeckReportsCardPressure() {
    let tight = driving(deviceStatus: status(sdFreeMb: 180))
    let row = HUDBuilder.snapshot(tight, now: now).device.rows[1]
    #expect(row.title == "Card 180 MB free")
    #expect(row.band == .alarm)
    #expect(HUDBuilder.snapshot(driving(), now: now).device.rows[1].title == "Card 7.1 GB free")
}

@Test func tripDeckLeadsWithTheTripRatherThanTheLink() {
    let hero = HUDBuilder.snapshot(driving(), now: now).drive.hero
    #expect(hero.headline == "Trip running 10 m 00 s")
    #expect(hero.detail == "1,118 fixes accepted · no link drops")
}

@Test func linkDropsAreCountedAndAged() {
    var flaky = driving()
    flaky.dropCount = 2
    flaky.lastDrop = now.addingTimeInterval(-72)
    let row = HUDBuilder.snapshot(flaky, now: now).drive.rows[3]
    #expect(row.title == "2 link drops")
    #expect(row.detail == "last 1 m 12 s ago")
    #expect(row.band == .caution)
    #expect(HUDBuilder.snapshot(driving(), now: now).drive.rows[3].title == "No link drops")
}

// MARK: - Formatting

@Test func formattingHelpers() {
    #expect(HUDBuilder.grouped(0) == "0")
    #expect(HUDBuilder.grouped(999) == "999")
    #expect(HUDBuilder.grouped(1_118) == "1,118")
    #expect(HUDBuilder.grouped(1_234_567) == "1,234,567")
    #expect(HUDBuilder.grouped(-2_140) == "-2,140")

    #expect(HUDBuilder.list([]) == "")
    #expect(HUDBuilder.list(["OBD"]) == "OBD")
    #expect(HUDBuilder.list(["OBD", "GPS"]) == "OBD and GPS")
    #expect(HUDBuilder.list(["OBD", "GPS", "SD"]) == "OBD, GPS and SD")

    #expect(HUDBuilder.span(5, 0, 10) == 0.5)
    #expect(HUDBuilder.span(-4, 0, 10) == 0)
    #expect(HUDBuilder.span(40, 0, 10) == 1)
    #expect(HUDBuilder.span(.nan, 0, 10) == 0)
    #expect(HUDBuilder.span(5, 10, 10) == 0)
}
