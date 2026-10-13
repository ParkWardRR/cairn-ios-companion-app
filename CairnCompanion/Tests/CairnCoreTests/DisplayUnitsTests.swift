import Foundation
import Testing
@testable import CairnCore

@Suite("Display units")
struct DisplayUnitsTests {
    @Test("the locale picks the units, as CarPlay already did")
    func locales() {
        #expect(DisplayUnits.forLocale(Locale(identifier: "en_US")) == .us)
        #expect(DisplayUnits.forLocale(Locale(identifier: "en_GB")) == .uk)
        #expect(DisplayUnits.forLocale(Locale(identifier: "de_DE")) == .metric)
        #expect(DisplayUnits.forLocale(Locale(identifier: "ja_JP")) == .metric)
    }

    @Test("a trip's distance")
    func distance() {
        #expect(DisplayUnits.metric.distanceText(metres: 41_500) == "41.5 km")
        #expect(DisplayUnits.us.distanceText(metres: 41_500) == "25.8 mi")
        // Short enough that the big unit would read as 0.0.
        #expect(DisplayUnits.metric.distanceText(metres: 420) == "420 m")
        #expect(DisplayUnits.us.distanceText(metres: 120) == "394 ft")
    }

    @Test("speed")
    func speed() {
        #expect(DisplayUnits.metric.speedText(kph: 66) == "66 km/h")
        #expect(DisplayUnits.us.speedText(kph: 66) == "41 mph")
        #expect(DisplayUnits.uk.speedText(kph: 100) == "62 mph")
    }

    @Test("economy, from the US mpg the estimate works in")
    func economy() {
        #expect(DisplayUnits.us.economyText(mpgUS: 27.3) == "27.3 mpg")
        // An imperial gallon goes about 20% further.
        #expect(DisplayUnits.uk.economyText(mpgUS: 27.3) == "32.8 mpg")
        // 235.2 / 27.3 = 8.6 L/100 km.
        #expect(DisplayUnits.metric.economyText(mpgUS: 27.3) == "8.6 L/100 km")
    }

    @Test("an economy of zero has nothing to say rather than dividing by it")
    func zeroEconomy() {
        #expect(DisplayUnits.metric.economyText(mpgUS: 0) == "\u{2014}")
        #expect(DisplayUnits.us.economyText(mpgUS: 0) == "\u{2014}")
        #expect(DisplayUnits.metric.economyText(mpgUS: -1) == "\u{2014}")
    }

    @Test("fuel burned is litres wherever fuel is bought in litres")
    func volume() {
        #expect(DisplayUnits.us.volumeParts(gallonsUS: 1.5).unit == "gal")
        #expect(DisplayUnits.us.volumeParts(gallonsUS: 1.5).value == "1.50")
        // Britain quotes mpg but buys litres.
        #expect(DisplayUnits.uk.volumeParts(gallonsUS: 1.5).unit == "L")
        #expect(DisplayUnits.metric.volumeParts(gallonsUS: 1.5).value == "5.68")
    }

    @Test("one drive never mixes a mile with a kilometre")
    func noMixing() {
        for units in [DisplayUnits.us, .uk, .metric] {
            let distance = units.distanceParts(metres: 40_000).unit
            let speed = units.speedParts(kph: 60).unit
            let imperialDistance = distance == "mi"
            #expect(imperialDistance == (speed == "mph"), "\(units) shows \(distance) with \(speed)")
        }
    }
}

@Suite("Odometer units")
struct OdometerUnitsTests {
    private let reading = OdometerCorrection(vehicleID: "v", odometerKm: 180_000)

    @Test("an odometer reads in the unit asked for")
    func formatted() {
        #expect(reading.formatted(useMiles: false) == "180,000 km")
        #expect(reading.formatted(useMiles: true) == "111,846 mi")
    }

    @Test("which unit comes from the same locale rule as everything else")
    func followsTheLocale() {
        #expect(DisplayUnits.forLocale(Locale(identifier: "en_US")).distance == .miles)
        #expect(DisplayUnits.forLocale(Locale(identifier: "de_DE")).distance == .kilometres)
    }
}

@Suite("HUD units")
struct HUDUnitsFormattingTests {
    @Test("the HUD and the Drive tab convert a reading the same way")
    func shared() {
        #expect(HUDUnits.imperial.caption(HUDUnits.imperial.speedParts(kph: 100)) == "62 mph")
        #expect(HUDUnits.metric.caption(HUDUnits.metric.speedParts(kph: 100)) == "100 km/h")
        #expect(HUDUnits.imperial.caption(HUDUnits.imperial.temperatureParts(celsius: 90)) == "194 °F")
        #expect(HUDUnits.metric.caption(HUDUnits.metric.temperatureParts(celsius: 90)) == "90 °C")
        #expect(HUDUnits.imperial.caption(HUDUnits.imperial.pressureParts(kpa: 100)) == "14.5 psi")
        #expect(HUDUnits.metric.caption(HUDUnits.metric.pressureParts(kpa: 100)) == "100 kPa")
    }
}
