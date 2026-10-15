import XCTest

/// One drive, read in one set of units. The app used to hard-code kilometres and km/h for
/// distance and speed while hard-coding mpg for economy, so a single card said "41.5 km … 27.3
/// mpg … 66 km/h" — and CarPlay, which follows the locale, disagreed with all of it.
///
/// The simulator runs in whatever locale the Mac is in, so these tests read the units off the
/// screen and check they belong to the same system rather than asserting one of them.
@MainActor
final class UnitsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let imperial = ["mi", "ft", "mph", "mpg", "gal", "°F", "psi"]
    private static let metric = ["km", "m", "km/h", "L/100 km", "L", "°C", "kPa"]

    func testATripCardDoesNotMixMilesWithKilometres() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "no drives listed")

        // The card's label is its whole contents: "7:04 PM, 41.5 km, Distance, 38 min, …".
        let label = cairn.driveCards.firstMatch.label
        let distanceIsImperial = label.contains(" mi,") || label.contains(" ft,")
        let distanceIsMetric = label.contains(" km,") || label.contains(" m,")
        XCTAssertTrue(distanceIsImperial || distanceIsMetric, "the card shows no distance at all: \(label)")

        if label.contains("mpg") {
            XCTAssertTrue(distanceIsImperial, "the card quotes mpg next to a metric distance: \(label)")
            XCTAssertTrue(label.contains("mph"), "the card quotes mpg but not mph: \(label)")
        }
        if label.contains("L/100 km") {
            XCTAssertTrue(distanceIsMetric, "the card quotes L/100 km next to an imperial distance: \(label)")
        }
        if label.contains("km/h") {
            XCTAssertTrue(distanceIsMetric, "the card quotes km/h next to an imperial distance: \(label)")
        }
    }

    func testATripsDetailUsesOneSystemThroughout() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "no drives listed")
        cairn.driveCards.firstMatch.tap()
        XCTAssertTrue(cairn.app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 15), "the drive did not open")

        let text = cairn.visibleText()
        let imperial = Self.imperial.filter { unit in text.contains { $0 == unit } }
        let metric = Self.metric.filter { unit in text.contains { $0 == unit } }
        // "m" and "min" and the like are too easy to confuse, so only count exact unit labels —
        // which is how `Metric` lays them out.
        XCTAssertTrue(
            imperial.isEmpty || metric.isEmpty,
            "the trip detail mixes \(imperial) with \(metric)"
        )
    }

    func testTheDriveTabAgreesWithTheRestOfTheApp() {
        let cairn = CairnApp(demo: "streaming", trips: true)
        cairn.waitUntilReady()

        // Whatever the live readings use, the trip list must use the same. The readings that
        // carry the owner's units (speed, temperatures, boost) are in the Live Telemetry card,
        // below the fold, so read the tab as it scrolls rather than only its first screen.
        var live = Set(cairn.visibleText())
        for _ in 0..<3 {
            cairn.app.swipeUp()
            live.formUnion(cairn.visibleText())
        }
        let liveImperial = Self.imperial.contains { unit in live.contains { $0 == unit } }
        let liveMetric = Self.metric.contains { unit in live.contains { $0 == unit } }
        XCTAssertTrue(
            liveImperial || liveMetric,
            "the Drive tab shows no unit to compare: \(live.sorted().prefix(20))"
        )

        cairn.go(to: .trips)
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "no drives listed")
        let card = cairn.driveCards.firstMatch.label
        let cardImperial = card.contains("mph") || card.contains(" mi,") || card.contains("mpg")

        if liveImperial || cardImperial {
            XCTAssertEqual(
                liveImperial, cardImperial,
                "the Drive tab and the Trips tab disagree about units (live imperial: \(liveImperial), card: \(card))"
            )
        }
    }
}
