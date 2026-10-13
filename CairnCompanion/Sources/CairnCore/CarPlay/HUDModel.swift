import Foundation

// The CarPlay HUD's display model. A CarPlay driving-task app cannot draw its own views, so the only
// pixels Cairn controls are the images inside list rows. Everything that decides *what* those rows and
// images say lives here, in plain values with no UIKit or CarPlay import, so it can be tested.
//
// Two ideas run through the whole file:
//
//  1. The row set never changes. Every row has a stable `HUDRowID`, and a snapshot always carries the
//     same ids in the same order. The CarPlay layer builds the rows once and then only rewrites their
//     text and images, so a BLE dropout never reloads or collapses the list.
//
//  2. Nothing is ever blanked. A reading the dongle has stopped sending keeps its last value and gains
//     an age, and its gauge fades through `Freshness`. "No data" and "data from 14 seconds ago" are
//     different claims, and the driver gets told which one they are looking at.

// MARK: - Units

/// What the HUD renders in. Derived from the phone's locale at the CarPlay boundary so everything
/// below stays pure.
public struct HUDUnits: Sendable, Equatable {
    public enum Speed: Sendable, Equatable { case kph, mph }
    public enum Temperature: Sendable, Equatable { case celsius, fahrenheit }
    public enum Pressure: Sendable, Equatable { case kpa, psi }

    public var speed: Speed
    public var temperature: Temperature
    public var pressure: Pressure

    public init(speed: Speed, temperature: Temperature, pressure: Pressure) {
        self.speed = speed
        self.temperature = temperature
        self.pressure = pressure
    }

    public static let metric = HUDUnits(speed: .kph, temperature: .celsius, pressure: .kpa)
    public static let imperial = HUDUnits(speed: .mph, temperature: .fahrenheit, pressure: .psi)

    /// Units follow the phone's locale: a US driver reads mph, °F and psi without being asked, and
    /// a UK one reads mph and psi but still °C. The HUD, the Drive tab and the Trips tab all ask
    /// this, so a drive reads the same everywhere.
    public static func forLocale(_ locale: Locale) -> HUDUnits {
        switch locale.measurementSystem {
        case .us: .imperial
        case .uk: HUDUnits(speed: .mph, temperature: .celsius, pressure: .psi)
        default: .metric
        }
    }

    // MARK: Formatting
    //
    // The HUD and the Drive tab show the same live readings, so they convert them in one place:
    // a US owner was reading mph in the car and km/h on the phone.

    public func speedParts(kph: Double) -> (value: String, unit: String) {
        speed == .mph ? ("\(Int((kph / 1.609344).rounded()))", "mph") : ("\(Int(kph.rounded()))", "km/h")
    }

    public func temperatureParts(celsius: Double) -> (value: String, unit: String) {
        temperature == .fahrenheit ? ("\(Int((celsius * 9 / 5 + 32).rounded()))", "°F") : ("\(Int(celsius.rounded()))", "°C")
    }

    public func pressureParts(kpa: Double) -> (value: String, unit: String) {
        pressure == .psi ? (String(format: "%.1f", kpa * 0.1450377), "psi") : ("\(Int(kpa.rounded()))", "kPa")
    }

    /// Value and unit joined by a space, as a HUD caption wants them.
    public func caption(_ parts: (value: String, unit: String)) -> String { "\(parts.value) \(parts.unit)" }
}

// MARK: - Bands and freshness

/// How alarming a reading is. This is the HUD's only colour channel: CarPlay picks the text colour,
/// so a band only ever reaches the driver through an image Cairn drew.
public enum HUDBand: Sendable, Equatable {
    case nominal
    case caution
    case alarm
    /// No reading, or no band worth asserting for this metric.
    case unknown
}

extension Freshness {
    /// Higher is better. Used to pick the most recent of several channels.
    var rank: Int {
        switch self {
        case .live: 3
        case .stale: 2
        case .silent: 1
        case .never: 0
        }
    }

    /// The best of a set of channels. The dongle is "heard" if any of its 1 Hz notifies is fresh, so a
    /// quiet OBD channel on a car that answers no PIDs must not read as a dead dongle.
    public static func best(_ values: Freshness...) -> Freshness {
        values.max { $0.rank < $1.rank } ?? .never
    }
}

// MARK: - Gauges

/// One radial tile in the engine strip.
public struct HUDGauge: Sendable, Equatable {
    /// The metrics a tile can show, in the order they earn a slot.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case rpm, coolant, boost, volts, speed, load, oil, intake, throttle

        /// The short word above the tile.
        public var label: String {
            switch self {
            case .rpm: "RPM"
            case .coolant: "COOLANT"
            case .boost: "BOOST"
            case .volts: "VOLTS"
            case .speed: "SPEED"
            case .load: "LOAD"
            case .oil: "OIL"
            case .intake: "INTAKE"
            case .throttle: "THROTTLE"
            }
        }
    }

    public let kind: Kind
    /// `2,140 rpm`, or `—` when the car has never answered this PID.
    public let caption: String
    /// Needle position, 0…1. `nil` draws an empty dashed track: the metric exists but has no value.
    public let fraction: Double?
    public let band: HUDBand
    public let freshness: Freshness

    public init(kind: Kind, caption: String, fraction: Double?, band: HUDBand, freshness: Freshness) {
        self.kind = kind
        self.caption = caption
        self.fraction = fraction
        self.band = band
        self.freshness = freshness
    }

    /// How many distinct needle positions a tile is drawn at. Rendering is cached by bucket, so a
    /// steady needle costs nothing: `setImage` is only called when the bucket, band, or freshness moves.
    /// 48 steps is finer than the eye reads off a 60-point tile at arm's length.
    public static let buckets = 48

    /// The cache key for this tile's image. Two gauges with the same key draw identically.
    public var imageKey: HUDGaugeKey {
        HUDGaugeKey(
            bucket: fraction.map { Int((max(0, min(1, $0)) * Double(Self.buckets - 1)).rounded()) },
            band: band,
            freshness: freshness
        )
    }
}

/// Everything that affects a gauge's pixels, and nothing that does not.
public struct HUDGaugeKey: Sendable, Equatable, Hashable {
    public let bucket: Int?
    public let band: HUDBand
    public let freshness: Freshness

    public init(bucket: Int?, band: HUDBand, freshness: Freshness) {
        self.bucket = bucket
        self.band = band
        self.freshness = freshness
    }
}

extension HUDBand: Hashable {}
extension Freshness: Hashable {}

// MARK: - Keystone

/// One stone of the hero glyph. Cairn's mark is a stack of stones, so the dongle's four health bits
/// get drawn as four stones — the whole device verdict in one image.
public enum HUDStone: Sendable, Equatable {
    case ok
    case fault
    /// The dongle has never reported this subsystem.
    case unreported
}

/// The hero row at the top of every deck: a keystone glyph, a headline, and the evidence for it.
public struct HUDHero: Sendable, Equatable {
    public let headline: String
    public let detail: String
    /// Bottom to top: SD, IMU, GNSS, OBD.
    public let stones: [HUDStone]
    public let band: HUDBand
    public let freshness: Freshness

    public init(headline: String, detail: String, stones: [HUDStone], band: HUDBand, freshness: Freshness) {
        self.headline = headline
        self.detail = detail
        self.stones = stones
        self.band = band
        self.freshness = freshness
    }
}

// MARK: - Rows and decks

/// A row's identity, fixed for the life of a CarPlay session. The CarPlay layer keys its `CPListItem`s
/// on these, which is what lets it rewrite a row instead of rebuilding the list.
public enum HUDRowID: String, Sendable, Equatable, CaseIterable {
    case hero, strip
    case acceptance, phoneFix
    case trip, accepted, rejected, queueDrops, drops
    case battery, storage, firmware, bond
}

public struct HUDRow: Sendable, Equatable {
    public let id: HUDRowID
    public let title: String
    public let detail: String
    public let band: HUDBand
    public let freshness: Freshness
    /// 0…1 for the row's small leading bar. `nil` means the row carries no meter.
    public let meter: Double?

    public init(id: HUDRowID, title: String, detail: String, band: HUDBand, freshness: Freshness, meter: Double?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.band = band
        self.freshness = freshness
        self.meter = meter
    }

    /// The cache key for this row's bar glyph.
    public var imageKey: HUDGaugeKey {
        HUDGaugeKey(
            bucket: meter.map { Int((max(0, min(1, $0)) * 23).rounded()) },
            band: band,
            freshness: freshness
        )
    }
}

/// One CarPlay tab.
public struct HUDDeck: Sendable, Equatable {
    public let hero: HUDHero
    /// Header above the engine strip; carries the strip's age when the dongle has gone quiet.
    public let stripTitle: String?
    public let gauges: [HUDGauge]
    public let rows: [HUDRow]

    public init(hero: HUDHero, stripTitle: String?, gauges: [HUDGauge], rows: [HUDRow]) {
        self.hero = hero
        self.stripTitle = stripTitle
        self.gauges = gauges
        self.rows = rows
    }
}

public struct HUDSnapshot: Sendable, Equatable {
    public let now: HUDDeck
    public let drive: HUDDeck
    public let device: HUDDeck

    public init(now: HUDDeck, drive: HUDDeck, device: HUDDeck) {
        self.now = now
        self.drive = drive
        self.device = device
    }
}

// MARK: - Input

/// What the link is doing, reduced to the cases the HUD words differently. The phone's own screen owns
/// the fine-grained wording; `stage` and `linkDetail` are passed through so the two never disagree.
public enum HUDLink: Sendable, Equatable {
    /// Auto-connect is off. CarPlay never turns it on.
    case off
    case unavailable
    case waiting
    case ready
    case failed
}

/// A flat copy of everything the HUD reads, taken on the main actor and then used off it.
public struct HUDInput: Sendable {
    public var link: HUDLink
    /// `SessionState.stage`, reused verbatim so the car and the phone say the same thing.
    public var stage: String
    public var linkDetail: String?
    public var isStreaming: Bool
    public var connectedSince: Date?
    public var dropCount: Int
    public var lastDrop: Date?

    public var obd: OBDLiveSnapshot?
    public var lastOBDAt: Date?
    public var deviceStatus: DeviceStatus?
    public var lastDeviceStatusAt: Date?
    public var companionStatus: CompanionStatus?
    public var lastStatusAt: Date?
    public var quality: GNSSQuality?
    public var lastQualityAt: Date?
    public var phoneFix: PhoneGNSSFix?
    public var locationMessage: String?
    public var sentCount: Int
    public var droppedCount: Int
    public var deviceInfo: DeviceInfo?
    public var units: HUDUnits
    /// How many tiles the vehicle will show. Cars differ, so the strip is sized at connect.
    public var gaugeSlots: Int

    public init(
        link: HUDLink = .off,
        stage: String = "Off",
        linkDetail: String? = nil,
        isStreaming: Bool = false,
        connectedSince: Date? = nil,
        dropCount: Int = 0,
        lastDrop: Date? = nil,
        obd: OBDLiveSnapshot? = nil,
        lastOBDAt: Date? = nil,
        deviceStatus: DeviceStatus? = nil,
        lastDeviceStatusAt: Date? = nil,
        companionStatus: CompanionStatus? = nil,
        lastStatusAt: Date? = nil,
        quality: GNSSQuality? = nil,
        lastQualityAt: Date? = nil,
        phoneFix: PhoneGNSSFix? = nil,
        locationMessage: String? = nil,
        sentCount: Int = 0,
        droppedCount: Int = 0,
        deviceInfo: DeviceInfo? = nil,
        units: HUDUnits = .metric,
        gaugeSlots: Int = 5
    ) {
        self.link = link
        self.stage = stage
        self.linkDetail = linkDetail
        self.isStreaming = isStreaming
        self.connectedSince = connectedSince
        self.dropCount = dropCount
        self.lastDrop = lastDrop
        self.obd = obd
        self.lastOBDAt = lastOBDAt
        self.deviceStatus = deviceStatus
        self.lastDeviceStatusAt = lastDeviceStatusAt
        self.companionStatus = companionStatus
        self.lastStatusAt = lastStatusAt
        self.quality = quality
        self.lastQualityAt = lastQualityAt
        self.phoneFix = phoneFix
        self.locationMessage = locationMessage
        self.sentCount = sentCount
        self.droppedCount = droppedCount
        self.deviceInfo = deviceInfo
        self.units = units
        self.gaugeSlots = gaugeSlots
    }
}
