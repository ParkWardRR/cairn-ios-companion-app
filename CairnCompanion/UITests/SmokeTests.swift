import XCTest

/// The app launches and both screens open.
///
/// This is all a simulator can say about an app whose subject is a radio: there is no
/// CoreBluetooth in the simulator, so the link can never be more than `off` here. Every rule
/// about what the link does is tested in `CairnKitTests` against `FakeCentral`, and on hardware
/// against the dongle, with the run written down under `docs/bench/`. What this catches is a view
/// that crashes on appear or a screen with no way out — which the unit suites cannot see.
final class SmokeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testBothScreensOpen() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Dongle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Dongle"].waitForExistence(timeout: 5))

        // The Dongle screen's controls must be reachable even with no radio: a simulator's
        // central never leaves `off`, and a diagnostics screen you cannot use when nothing works
        // is a diagnostics screen for nothing.
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Forget This Dongle"].exists)
        XCTAssertTrue(app.buttons["Export Log"].firstMatch.exists)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // The build has to be able to say what it is, on every channel.
        XCTAssertTrue(app.staticTexts["Version"].exists)
        XCTAssertTrue(app.staticTexts["Channel"].exists)

        app.tabBars.buttons["Dongle"].tap()
        XCTAssertTrue(app.navigationBars["Dongle"].waitForExistence(timeout: 5))
    }
}
