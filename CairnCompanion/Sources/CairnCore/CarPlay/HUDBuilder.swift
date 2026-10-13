import Foundation

/// Turns a `HUDInput` into the three decks the CarPlay screen shows. Pure, so every wording and
/// band decision in here is testable without a car.
public enum HUDBuilder {
    public static func snapshot(_ input: HUDInput, now: Date, slots: [HUDGauge.Kind]? = nil) -> HUDSnapshot {
        let kinds = slots ?? gaugeSlots(for: input.obd, limit: input.gaugeSlots)
        let obdFresh = LinkHealth.freshness(lastHeard: input.lastOBDAt, now: now)
        let gauges = kinds.map { gauge($0, input: input, freshness: obdFresh) }

        return HUDSnapshot(
            now: HUDDeck(
                hero: hero(input, now: now),
                stripTitle: stripTitle(input, freshness: obdFresh, now: now),
                gauges: gauges,
                rows: [acceptanceRow(input, now: now), phoneFixRow(input, now: now)]
            ),
            drive: HUDDeck(
                hero: driveHero(input, now: now),
                stripTitle: nil,
                gauges: [],
                rows: [
                    acceptedRow(input, now: now), rejectedRow(input, now: now),
                    queueDropRow(input, now: now), dropRow(input, now: now),
                ]
            ),
            device: HUDDeck(
                hero: deviceHero(input, now: now),
                stripTitle: nil,
                gauges: [],
                rows: [
                    batteryRow(input, now: now), storageRow(input, now: now),
                    firmwareRow(input), identityRow(input, now: now),
                ]
            )
        )
    }

    // MARK: - Choosing the strip

    /// The tiles the strip shows, in priority order, limited to what the vehicle will display.
    ///
    /// The caller freezes this once per CarPlay session: a naturally-aspirated car must not grow a
    /// boost tile halfway through a drive, and a tile must never move once the driver has learnt
    /// where it is. When the car has answered nothing yet, a sensible default set is shown ghosted
    /// rather than an empty strip.
    public static func gaugeSlots(for obd: OBDLiveSnapshot?, limit: Int) -> [HUDGauge.Kind] {
        let priority: [HUDGauge.Kind] = [.rpm, .coolant, .boost, .volts, .speed, .load, .oil, .intake, .throttle]
        let cap = max(1, limit)
        guard let obd else { return Array([.rpm, .coolant, .volts, .speed, .load].prefix(cap)) }
        let answered = priority.filter { has($0, in: obd) }
        guard !answered.isEmpty else { return Array([.rpm, .coolant, .volts, .speed, .load].prefix(cap)) }
        return Array(answered.prefix(cap))
    }

    private static func has(_ kind: HUDGauge.Kind, in obd: OBDLiveSnapshot) -> Bool {
        switch kind {
        case .rpm: obd.hasRPM
        case .coolant: obd.hasCoolant
        case .boost: obd.hasBoost
        case .volts: obd.voltage != nil
        case .speed: obd.hasSpeed
        case .load: obd.engineLoadPct != 0xFF
        case .oil: obd.hasOilTemp
        case .intake: obd.hasIntakeTemp
        case .throttle: obd.hasThrottle
        }
    }

    private static func stripTitle(_ input: HUDInput, freshness: Freshness, now: Date) -> String {
        switch freshness {
        case .live: return "Live engine"
        case .stale, .silent:
            guard let last = input.lastOBDAt else { return "Engine" }
            return "Live engine — held \(LinkHealth.ageLabel(now.timeIntervalSince(last)))"
        case .never:
            return input.link == .ready ? "Engine — waiting for OBD" : "Engine — no OBD data"
        }
    }

    // MARK: - Gauges

    private static func gauge(_ kind: HUDGauge.Kind, input: HUDInput, freshness: Freshness) -> HUDGauge {
        guard let obd = input.obd, let reading = read(kind, from: obd, units: input.units) else {
            return HUDGauge(kind: kind, caption: "—", fraction: nil, band: .unknown, freshness: .never)
        }
        return HUDGauge(
            kind: kind, caption: reading.caption, fraction: reading.fraction,
            band: reading.band, freshness: freshness
        )
    }

    private struct Reading {
        let caption: String
        let fraction: Double
        let band: HUDBand
    }

    private static func read(_ kind: HUDGauge.Kind, from obd: OBDLiveSnapshot, units: HUDUnits) -> Reading? {
        switch kind {
        case .rpm:
            guard obd.hasRPM else { return nil }
            let v = Double(obd.rpm)
            // No thousands separator: the caption is drawn inside the ring, and a comma costs a
            // character's width that the font-fitting would have to pay for by shrinking.
            return Reading(
                caption: "\(obd.rpm)",
                fraction: span(v, 0, 7000),
                band: v >= 6500 ? .alarm : v >= 5500 ? .caution : .nominal
            )
        case .speed:
            guard let kph = obd.speedKph else { return nil }
            return Reading(
                caption: units.caption(units.speedParts(kph: kph)),
                fraction: span(kph, 0, 200), band: .nominal
            )
        case .coolant:
            guard obd.hasCoolant else { return nil }
            return temperature(Double(obd.coolantTempC), units: units, scale: (0, 130), cold: 50, warm: 105, hot: 115)
        case .oil:
            guard obd.hasOilTemp else { return nil }
            return temperature(Double(obd.oilTempC), units: units, scale: (0, 150), cold: 50, warm: 120, hot: 135)
        case .intake:
            guard obd.hasIntakeTemp else { return nil }
            return temperature(Double(obd.intakeTempC), units: units, scale: (-20, 90), cold: -100, warm: 70, hot: 85)
        case .boost:
            guard let kpa = obd.boostKpa else { return nil }
            let caption = units.caption(units.pressureParts(kpa: kpa))
            // The dongle reports gauge pressure, so vacuum is negative. No band: a safe ceiling
            // depends on the engine, and Cairn does not know which engine this is.
            return Reading(caption: caption, fraction: span(kpa, -100, 200), band: .nominal)
        case .volts:
            guard let v = obd.voltage else { return nil }
            return Reading(caption: String(format: "%.1f V", v), fraction: span(v, 10, 16), band: voltBand(v))
        case .load:
            guard obd.engineLoadPct != 0xFF else { return nil }
            let v = Double(obd.engineLoadPct)
            return Reading(caption: "\(Int(v)) %", fraction: span(v, 0, 100), band: .nominal)
        case .throttle:
            guard obd.hasThrottle else { return nil }
            let v = Double(obd.throttlePct)
            return Reading(caption: "\(Int(v)) %", fraction: span(v, 0, 100), band: .nominal)
        }
    }

    private static func temperature(
        _ celsius: Double, units: HUDUnits,
        scale: (Double, Double), cold: Double, warm: Double, hot: Double
    ) -> Reading {
        let caption = units.caption(units.temperatureParts(celsius: celsius))
        let band: HUDBand = celsius >= hot ? .alarm : (celsius >= warm || celsius < cold) ? .caution : .nominal
        return Reading(caption: caption, fraction: span(celsius, scale.0, scale.1), band: band)
    }

    /// A healthy charging system sits near 14 V running and 12.4 V at rest. Outside 11.5–15.2 V
    /// something is wrong either way round, so both ends alarm.
    private static func voltBand(_ v: Double) -> HUDBand {
        if v < 11.5 || v > 15.2 { return .alarm }
        if v < 12.0 || v > 14.9 { return .caution }
        return .nominal
    }

    // MARK: - Hero

    static func stones(_ status: DeviceStatus?) -> [HUDStone] {
        guard let status else { return Array(repeating: .unreported, count: 4) }
        let h = status.health
        // Bottom to top: SD, IMU, GNSS, OBD.
        return [h.contains(.sdOk), h.contains(.imuOk), h.contains(.gnssOk), h.contains(.obdOk)]
            .map { $0 ? .ok : .fault }
    }

    /// How recently anything at all was heard from the dongle. Any of its 1 Hz notifies counts: a car
    /// that answers no OBD PIDs must not read as a dead dongle.
    static func heard(_ input: HUDInput, now: Date) -> (freshness: Freshness, last: Date?) {
        let stamps = [input.lastStatusAt, input.lastDeviceStatusAt, input.lastOBDAt, input.lastQualityAt]
        let last = stamps.compactMap { $0 }.max()
        return (LinkHealth.freshness(lastHeard: last, now: now), last)
    }

    public static func hero(_ input: HUDInput, now: Date) -> HUDHero {
        let stones = stones(input.deviceStatus)

        switch input.link {
        case .off:
            return HUDHero(
                headline: "Auto-connect off",
                detail: "Cairn is not following the dongle. Turn it back on from the phone.",
                stones: stones, band: .unknown, freshness: .never
            )
        case .unavailable:
            return HUDHero(
                headline: input.stage,
                detail: "Bluetooth has to be on for Cairn to reach the dongle.",
                stones: stones, band: .alarm, freshness: .never
            )
        case .failed:
            return HUDHero(
                headline: input.stage,
                detail: input.linkDetail ?? "Open Cairn on the phone to pair again.",
                stones: stones, band: .alarm, freshness: .never
            )
        case .waiting:
            return HUDHero(
                headline: input.stage,
                detail: input.linkDetail ?? "Checking the dongle has power and is in range.",
                stones: stones, band: .caution, freshness: .never
            )
        case .ready:
            break
        }

        let (fresh, last) = heard(input, now: now)
        switch fresh {
        case .never:
            return HUDHero(
                headline: "Bonded",
                detail: "Waiting for the dongle's first report.",
                stones: stones, band: .caution, freshness: .never
            )
        case .silent:
            let age = last.map { LinkHealth.ageLabel(now.timeIntervalSince($0)) } ?? "a while"
            return HUDHero(
                headline: "Dongle silent \(age)",
                detail: input.linkDetail ?? "Holding the last readings. Nothing below is current.",
                stones: stones, band: .alarm, freshness: .silent
            )
        case .live, .stale:
            break
        }

        // The dongle is talking. Only it can say whether it is recording, and only while that
        // particular report is still fresh — "BLE connected" is not "recording".
        let statusFresh = LinkHealth.freshness(lastHeard: input.lastDeviceStatusAt, now: now)
        let phase = (statusFresh == .live || statusFresh == .stale) ? input.deviceStatus?.tripPhase : nil
        let evidence = evidenceLine(input, now: now)

        switch phase {
        case .driving:
            return HUDHero(headline: "Recording", detail: evidence, stones: stones, band: healthBand(input), freshness: fresh)
        case .idle:
            return HUDHero(
                headline: "Device idle",
                detail: "The dongle is connected but not logging a trip. " + evidence,
                stones: stones, band: .caution, freshness: fresh
            )
        case .paused:
            return HUDHero(headline: "Device paused", detail: evidence, stones: stones, band: .caution, freshness: fresh)
        case .unknown, .none:
            return HUDHero(
                headline: "Recording unknown",
                detail: "The dongle has not said whether it is logging. " + evidence,
                stones: stones, band: .caution, freshness: fresh
            )
        }
    }

    /// `1,118 fixes accepted · connected 18 m 04 s · 1 s ago` — the receipts behind the headline.
    private static func evidenceLine(_ input: HUDInput, now: Date) -> String {
        var parts: [String] = []
        if let status = input.companionStatus {
            parts.append("\(grouped(Int(status.acceptedCount))) fixes accepted")
        } else if input.isStreaming {
            parts.append("streaming")
        }
        if let since = input.connectedSince {
            parts.append("connected \(LinkHealth.ageLabel(now.timeIntervalSince(since)))")
        }
        let (_, last) = heard(input, now: now)
        if let last { parts.append("\(LinkHealth.ageLabel(now.timeIntervalSince(last))) ago") }
        return parts.joined(separator: " · ")
    }

    /// The dongle's own verdict on itself. OBD and GPS both down means it is running but logging
    /// nothing useful, which is worth an alarm even though the link is fine.
    private static func healthBand(_ input: HUDInput) -> HUDBand {
        guard let status = input.deviceStatus else { return .unknown }
        let h = status.health
        if !h.contains(.obdOk) && !h.contains(.gnssOk) { return .alarm }
        if !h.contains(.sdOk) { return .alarm }
        if !h.contains(.obdOk) || !h.contains(.gnssOk) || !h.contains(.imuOk) { return .caution }
        return .nominal
    }

    private static func driveHero(_ input: HUDInput, now: Date) -> HUDHero {
        let base = hero(input, now: now)
        guard base.headline == "Recording", let since = input.connectedSince else { return base }
        var parts = ["\(grouped(Int(input.companionStatus?.acceptedCount ?? 0))) fixes accepted"]
        parts.append(input.dropCount == 0 ? "no link drops" : "\(input.dropCount) link drops")
        return HUDHero(
            headline: "Trip running \(LinkHealth.ageLabel(now.timeIntervalSince(since)))",
            detail: parts.joined(separator: " · "),
            stones: base.stones, band: base.band, freshness: base.freshness
        )
    }

    private static func deviceHero(_ input: HUDInput, now: Date) -> HUDHero {
        let stones = stones(input.deviceStatus)
        let (fresh, _) = heard(input, now: now)
        guard let status = input.deviceStatus else {
            return HUDHero(
                headline: "Dongle health unknown",
                detail: "The dongle has not reported its subsystems yet.",
                stones: stones, band: .unknown, freshness: .never
            )
        }
        let names: [(DeviceStatus.Health, String)] = [
            (.obdOk, "OBD"), (.gnssOk, "GPS"), (.sdOk, "SD"), (.imuOk, "IMU"),
        ]
        let faults = names.filter { !status.health.contains($0.0) }.map(\.1)
        let good = names.filter { status.health.contains($0.0) }.map(\.1)
        if faults.isEmpty {
            return HUDHero(
                headline: "All systems good",
                detail: "OBD, GPS, SD and IMU all reporting.",
                stones: stones, band: .nominal, freshness: fresh
            )
        }
        return HUDHero(
            headline: faults.count == 1 ? "\(faults[0]) not reporting" : "\(list(faults)) not reporting",
            detail: good.isEmpty ? "Nothing on the dongle is reporting." : "\(list(good)) still good.",
            stones: stones, band: healthBand(input), freshness: fresh
        )
    }

    // MARK: - Now deck rows

    private static func acceptanceRow(_ input: HUDInput, now: Date) -> HUDRow {
        let fresh = LinkHealth.freshness(lastHeard: input.lastStatusAt, now: now)
        guard let status = input.companionStatus else {
            return HUDRow(
                id: .acceptance, title: "No fixes accepted yet",
                detail: input.link == .ready ? "Waiting for the dongle to acknowledge" : "The dongle is not connected",
                band: .unknown, freshness: .never, meter: nil
            )
        }
        let accepted = Int(status.acceptedCount), rejected = Int(status.rejectedCount)
        let queueDrops = Int(status.queueDropCount)
        let unacked = LinkHealth.unacked(sent: input.sentCount, status: status)
        let total = accepted + rejected + queueDrops
        var detail = ["\(rejected) rejected", "\(queueDrops) dongle drops"]
        if unacked > 0 { detail.append("\(unacked) in flight") }
        if let last = input.lastStatusAt { detail.append("\(LinkHealth.ageLabel(now.timeIntervalSince(last))) ago") }
        let band: HUDBand = unacked > LinkHealth.unackedWarning || queueDrops > 0
            ? .caution : (rejected > 0 ? .caution : .nominal)
        return HUDRow(
            id: .acceptance, title: "Accepted \(grouped(accepted)) fixes",
            detail: detail.joined(separator: " · "), band: band, freshness: fresh,
            meter: total > 0 ? Double(accepted) / Double(total) : nil
        )
    }

    private static func phoneFixRow(_ input: HUDInput, now: Date) -> HUDRow {
        if let message = input.locationMessage {
            return HUDRow(
                id: .phoneFix, title: "Location unavailable", detail: message,
                band: .alarm, freshness: .never, meter: nil
            )
        }
        guard let fix = input.phoneFix else {
            return HUDRow(
                id: .phoneFix, title: "Waiting for a phone fix",
                detail: "Cairn needs location permission and a view of the sky",
                band: .caution, freshness: .never, meter: nil
            )
        }
        let accuracy = input.units.speed == .mph
            ? "±\(Int((fix.horizontalAccuracy * 3.28084).rounded())) ft"
            : "±\(Int(fix.horizontalAccuracy.rounded())) m"
        var detail: [String] = []
        if let quality = input.quality {
            detail.append("\(quality.satsUsed) sats")
            if let hdop = quality.hdop { detail.append(String(format: "HDOP %.1f", hdop)) }
        }
        detail.append("sent \(grouped(input.sentCount))")
        if input.droppedCount > 0 { detail.append("\(input.droppedCount) dropped") }
        return HUDRow(
            id: .phoneFix, title: "Phone fix \(accuracy)",
            detail: detail.joined(separator: " · "),
            band: fix.horizontalAccuracy > 50 ? .caution : .nominal,
            freshness: LinkHealth.freshness(lastHeard: fix.timestamp, now: now),
            // 5 m or better reads full; 60 m reads empty.
            meter: 1 - span(fix.horizontalAccuracy, 5, 60)
        )
    }

    // MARK: - Drive deck rows

    private static func acceptedRow(_ input: HUDInput, now: Date) -> HUDRow {
        let fresh = LinkHealth.freshness(lastHeard: input.lastStatusAt, now: now)
        guard let status = input.companionStatus else {
            return HUDRow(
                id: .accepted, title: "Accepted 0", detail: "Nothing acknowledged yet",
                band: .unknown, freshness: .never, meter: nil
            )
        }
        let total = Int(status.acceptedCount) + Int(status.rejectedCount) + Int(status.queueDropCount)
        return HUDRow(
            id: .accepted, title: "Accepted \(grouped(Int(status.acceptedCount)))",
            detail: "last sequence \(status.lastAcceptedSeq) · sent \(grouped(input.sentCount))",
            band: .nominal, freshness: fresh,
            meter: total > 0 ? Double(status.acceptedCount) / Double(total) : nil
        )
    }

    private static func rejectedRow(_ input: HUDInput, now: Date) -> HUDRow {
        let fresh = LinkHealth.freshness(lastHeard: input.lastStatusAt, now: now)
        let rejected = Int(input.companionStatus?.rejectedCount ?? 0)
        let total = input.companionStatus.map {
            Int($0.acceptedCount) + Int($0.rejectedCount) + Int($0.queueDropCount)
        } ?? 0
        return HUDRow(
            id: .rejected, title: "Rejected \(grouped(rejected))",
            detail: rejected == 0
                ? "The dongle has taken every fix the phone sent"
                : "Stale or out of order by the time they arrived",
            band: rejected > 0 ? .caution : .nominal,
            freshness: input.companionStatus == nil ? .never : fresh,
            meter: total > 0 ? Double(rejected) / Double(total) : nil
        )
    }

    private static func queueDropRow(_ input: HUDInput, now: Date) -> HUDRow {
        let fresh = LinkHealth.freshness(lastHeard: input.lastStatusAt, now: now)
        let drops = Int(input.companionStatus?.queueDropCount ?? 0)
        return HUDRow(
            id: .queueDrops, title: "Dongle queue drops \(grouped(drops))",
            detail: drops == 0 ? "The dongle has kept up" : "The dongle's queue overflowed",
            band: drops > 0 ? .caution : .nominal,
            freshness: input.companionStatus == nil ? .never : fresh,
            meter: nil
        )
    }

    private static func dropRow(_ input: HUDInput, now: Date) -> HUDRow {
        guard input.dropCount > 0 else {
            return HUDRow(
                id: .drops, title: "No link drops",
                detail: "Bluetooth has held since Cairn armed", band: .nominal, freshness: .live, meter: nil
            )
        }
        let last = input.lastDrop.map { "last \(LinkHealth.ageLabel(now.timeIntervalSince($0))) ago" } ?? ""
        return HUDRow(
            id: .drops, title: "\(input.dropCount) link \(input.dropCount == 1 ? "drop" : "drops")",
            detail: last, band: .caution, freshness: .live,
            // Six drops fills the bar; that is `ReconnectPolicy.maxConsecutiveFailures`.
            meter: span(Double(input.dropCount), 0, 6)
        )
    }

    // MARK: - Device deck rows

    private static func batteryRow(_ input: HUDInput, now: Date) -> HUDRow {
        let fresh = LinkHealth.freshness(lastHeard: input.lastDeviceStatusAt, now: now)
        guard let volts = input.deviceStatus?.batteryV else {
            return HUDRow(
                id: .battery, title: "Supply not reported",
                detail: "The dongle did not include a voltage", band: .unknown, freshness: .never, meter: nil
            )
        }
        let band = voltBand(volts)
        return HUDRow(
            id: .battery, title: String(format: "Supply %.1f V", volts),
            detail: band == .nominal ? "Charging system looks healthy" : "Outside the usual 12.0–14.9 V",
            band: band, freshness: fresh, meter: span(volts, 10, 16)
        )
    }

    private static func storageRow(_ input: HUDInput, now: Date) -> HUDRow {
        let fresh = LinkHealth.freshness(lastHeard: input.lastDeviceStatusAt, now: now)
        let freeMiB = input.deviceInfo?.storage?.freeMiB.map { Int($0) } ?? input.deviceStatus?.sdFree.map { Int($0) }
        guard let freeMiB else {
            return HUDRow(
                id: .storage, title: "Card space not reported",
                detail: "The dongle did not include free space", band: .unknown, freshness: .never, meter: nil
            )
        }
        var detail: [String] = []
        if let storage = input.deviceInfo?.storage {
            detail.append("\(storage.pendingBundles) \(storage.pendingBundles == 1 ? "bundle" : "bundles") waiting")
            switch storage.state {
            case .noCard: detail.append("no card")
            case .readOnly: detail.append("card is read-only")
            case .error: detail.append("card error")
            case .ok: break
            }
        }
        let band: HUDBand = freeMiB < 256 ? .alarm : freeMiB < 1024 ? .caution : .nominal
        let size = freeMiB >= 1024
            ? String(format: "%.1f GB", Double(freeMiB) / 1024)
            : "\(freeMiB) MB"
        return HUDRow(
            id: .storage, title: "Card \(size) free",
            detail: detail.isEmpty ? "Room for more trips" : detail.joined(separator: " · "),
            band: band, freshness: fresh, meter: nil
        )
    }

    private static func firmwareRow(_ input: HUDInput) -> HUDRow {
        guard let firmware = input.deviceInfo?.firmware else {
            return HUDRow(
                id: .firmware, title: "Firmware not reported",
                detail: "This dongle does not expose DEVICE_INFO", band: .unknown, freshness: .never, meter: nil
            )
        }
        var detail: [String] = []
        if firmware.isDirtyBuild { detail.append("dirty build") }
        if !firmware.isReleaseBuild { detail.append("debug build") }
        if firmware.secureBootOn { detail.append("secure boot") }
        if input.deviceInfo?.truncated == true { detail.append("info truncated") }
        return HUDRow(
            id: .firmware,
            title: "Firmware \(firmware.major).\(firmware.minor).\(firmware.patch)",
            detail: detail.isEmpty ? "Signed release build" : detail.joined(separator: " · "),
            band: firmware.isDirtyBuild ? .caution : .nominal, freshness: .live, meter: nil
        )
    }

    private static func identityRow(_ input: HUDInput, now: Date) -> HUDRow {
        let fresh = LinkHealth.freshness(lastHeard: input.lastDeviceStatusAt, now: now)
        let uptime = input.deviceStatus.map { "Dongle up \(LinkHealth.ageLabel(TimeInterval($0.uptimeS)))" }
        guard let identity = input.deviceInfo?.identity else {
            return HUDRow(
                id: .bond, title: uptime ?? "Uptime not reported",
                detail: "Identity not reported", band: .unknown,
                freshness: input.deviceStatus == nil ? .never : fresh, meter: nil
            )
        }
        let fingerprint = identity.fingerprint.map { String(format: "%02X", $0) }.joined()
        let enrolment: String
        switch identity.enrolState {
        case .notEnrolled: enrolment = "not enrolled"
        case .enrolled: enrolment = "enrolled"
        case .assigned: enrolment = "assigned to a vehicle"
        }
        return HUDRow(
            id: .bond, title: uptime ?? "Dongle \(fingerprint)",
            detail: "device \(fingerprint) · \(enrolment)",
            band: identity.enrolState == .notEnrolled ? .caution : .nominal,
            freshness: input.deviceStatus == nil ? .never : fresh, meter: nil
        )
    }

    // MARK: - Formatting

    /// `0` at `lo`, `1` at `hi`, clamped. Keeps every needle inside its arc.
    static func span(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo, value.isFinite else { return 0 }
        return max(0, min(1, (value - lo) / (hi - lo)))
    }

    /// `2,140`. Grouping is fixed rather than locale-driven so the tests read the same everywhere.
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { out.append(",") }
            out.append(character)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// `OBD`, `OBD and GPS`, `OBD, GPS and SD`.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")) and \(items.last!)"
        }
    }
}
