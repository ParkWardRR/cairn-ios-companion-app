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

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // The build has to be able to say what it is, on every channel.
        XCTAssertTrue(app.staticTexts["Version"].exists)
        XCTAssertTrue(app.staticTexts["Channel"].exists)

        app.tabBars.buttons["Dongle"].tap()
        XCTAssertTrue(app.navigationBars["Dongle"].waitForExistence(timeout: 5))
    }
}
