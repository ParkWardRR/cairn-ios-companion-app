import Foundation

/// What a drive reads as on the phone: miles or kilometres, mph or km/h, mpg or litres per 100 km.
///
/// The models hold one canonical set of values — metres, km/h, and US mpg out of `FuelEstimate` —
/// and everything the owner reads goes through here. CarPlay already followed the phone's locale
/// (`CairnCarPlayLink.units`); this is the same rule for the app, so one drive does not read as
/// mph in the car and km/h on the phone.
public struct DisplayUnits: Sendable, Equatable {
    public enum Distance: Sendable, Equatable { case kilometres, miles }
    public enum Speed: Sendable, Equatable { case kph, mph }
    /// Miles per gallon comes in two sizes; the metric world reads consumption, not economy.
    public enum Economy: Sendable, Equatable { case mpgUS, mpgImperial, litresPer100km }

    public var distance: Distance
    public var speed: Speed
    public var economy: Economy

    public init(distance: Distance, speed: Speed, economy: Economy) {
        self.distance = distance
        self.speed = speed
        self.economy = economy
    }

    public static let metric = DisplayUnits(distance: .kilometres, speed: .kph, economy: .litresPer100km)
    public static let us = DisplayUnits(distance: .miles, speed: .mph, economy: .mpgUS)
    /// Britain measures roads in miles and fuel in litres, but still quotes mpg — the larger gallon.
    public static let uk = DisplayUnits(distance: .miles, speed: .mph, economy: .mpgImperial)

    public static func forLocale(_ locale: Locale) -> DisplayUnits {
        switch locale.measurementSystem {
        case .us: .us
        case .uk: .uk
        default: .metric
        }
    }

    // MARK: Conversions

    static let metresPerMile = 1609.344
    static let kphPerMph = 1.609344
    /// An imperial gallon is 1.200950 US gallons, so it goes that much further.
    static let imperialPerUSGallon = 1.200950
    /// 235.214583 / mpg(US) = litres per 100 km.
    static let litresPer100kmNumerator = 235.214583

    // MARK: Formatting

    /// A trip's distance. Short distances get the small unit, so a one-minute bench test does not
    /// read as "0.0".
    public func distanceText(metres: Double) -> String {
        switch distance {
        case .kilometres:
            return metres < 1000 ? "\(Int(metres.rounded())) m" : String(format: "%.1f km", metres / 1000)
        case .miles:
            let miles = metres / Self.metresPerMile
            if miles < 0.1 { return "\(Int((metres * 3.280840).rounded())) ft" }
            return String(format: "%.1f mi", miles)
        }
    }

    public func speedText(kph: Double) -> String {
        "\(Int((speed == .kph ? kph : kph / Self.kphPerMph).rounded())) \(speedUnit)"
    }

    public var speedUnit: String { speed == .kph ? "km/h" : "mph" }

    /// Takes the US mpg that `FuelEstimate` computes, whatever it is going to be shown as.
    public func economyText(mpgUS: Double) -> String {
        guard mpgUS > 0 else { return "\u{2014}" }
        return String(format: "%.1f \(economyUnit)", economyValue(mpgUS: mpgUS))
    }

    public func economyValue(mpgUS: Double) -> Double {
        switch economy {
        case .mpgUS: mpgUS
        case .mpgImperial: mpgUS * Self.imperialPerUSGallon
        case .litresPer100km: Self.litresPer100kmNumerator / mpgUS
        }
    }

    public var economyUnit: String {
        switch economy {
        case .mpgUS, .mpgImperial: "mpg"
        case .litresPer100km: "L/100 km"
        }
    }

    /// Distance as a bare number plus its unit, for the views that lay the two out separately.
    public func distanceParts(metres: Double) -> (value: String, unit: String) {
        switch distance {
        case .kilometres: (String(format: "%.1f", metres / 1000), "km")
        case .miles: (String(format: "%.1f", metres / Self.metresPerMile), "mi")
        }
    }

    public func speedParts(kph: Double) -> (value: String, unit: String) {
        (String(Int((speed == .kph ? kph : kph / Self.kphPerMph).rounded())), speedUnit)
    }

    public func economyParts(mpgUS: Double) -> (value: String, unit: String) {
        (String(format: "%.1f", economyValue(mpgUS: mpgUS)), economyUnit)
    }

    static let litresPerUSGallon = 3.785412

    /// Fuel burned, from the US gallons `FuelEstimate` works in. Litres wherever economy is
    /// quoted metric — and in Britain too, which buys fuel in litres whatever it quotes mpg in.
    public func volumeParts(gallonsUS: Double) -> (value: String, unit: String) {
        switch economy {
        case .mpgUS: (String(format: "%.2f", gallonsUS), "gal")
        case .mpgImperial, .litresPer100km: (String(format: "%.2f", gallonsUS * Self.litresPerUSGallon), "L")
        }
    }
}
