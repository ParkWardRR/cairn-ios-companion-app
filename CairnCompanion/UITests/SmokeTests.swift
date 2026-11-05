import XCTest

/// The app launches and every screen opens.
///
/// This is all a simulator can say about an app whose subject is a radio: there is no
/// CoreBluetooth in the simulator, so the link can never be more than `off` here. Every rule
/// about what the link does is tested in `CairnKitTests` against `FakeCentral`, and on hardware
/// against the dongle, with the run written down under `docs/bench/`. What this catches is a view
/// that crashes on appear or a screen with no way out — which the unit suites cannot see.
final class SmokeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Swipe until the element is both present and on screen, or give up. A `List` builds only
    /// the rows it is showing, so an element below the fold does not merely fail `isHittable`:
    /// it does not exist in the tree at all.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement, swipes: Int = 8) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    func testEveryScreenOpens() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Dongle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Dongle"].waitForExistence(timeout: 5))

        // The Dongle screen's controls must be reachable even with no radio: a simulator's
        // central never leaves `off`, and a diagnostics screen you cannot use when nothing works
        // is a diagnostics screen for nothing. They are below the fold, and a list only builds
        // the rows it is showing, so these scroll rather than assuming a layout.
        XCTAssertTrue(scroll(app, to: app.buttons["Retry"]), "Retry")
        XCTAssertTrue(scroll(app, to: app.buttons["Forget This Dongle"]), "Forget This Dongle")

        // The bench controls have to be reachable on the bench, which is a place with no
        // server and often no link either.
        let disclosure = app.staticTexts["bench.disclosure"]
        XCTAssertTrue(scroll(app, to: disclosure), "bench disclosure")
        disclosure.tap()

        let freshPair = app.buttons["bench.row.fresh-pair"]
        XCTAssertTrue(scroll(app, to: freshPair), "the Fresh pair row")
        freshPair.tap()
        XCTAssertTrue(scroll(app, to: app.buttons["bench.report"]), "Bench Report")

        app.tabBars.buttons["Trips"].tap()
        XCTAssertTrue(app.navigationBars["Trips"].waitForExistence(timeout: 5))
        // With no server set up there are no trips, and the screen has to say which of the two
        // reasons it is rather than showing an empty list.
        XCTAssertTrue(app.staticTexts["No server yet"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // The build has to be able to say what it is, on every channel.
        XCTAssertTrue(app.staticTexts["Version"].exists)
        XCTAssertTrue(app.staticTexts["Channel"].exists)

        app.tabBars.buttons["Dongle"].tap()
        XCTAssertTrue(app.navigationBars["Dongle"].waitForExistence(timeout: 5))
    }
}
