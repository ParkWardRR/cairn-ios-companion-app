import XCTest

/// The first minute of owning the app: the welcome pages, the four tabs, and whether each one
/// survives being opened.
@MainActor
final class LaunchAndTabsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAFirstLaunchShowsTheWelcomePagesAndEndsOnDrive() {
        let cairn = CairnApp(onboarded: false)
        let app = cairn.app

        XCTAssertTrue(app.staticTexts["Your driving log"].waitForExistence(timeout: 20), "the first page of the welcome did not appear")

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["This app connects to it"].waitForExistence(timeout: 5), "the second welcome page did not appear")

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Your data stays yours"].waitForExistence(timeout: 5), "the third welcome page did not appear")

        // The last page offers to finish rather than to go on.
        XCTAssertTrue(app.buttons["Get Started"].exists, "the last welcome page has no way to finish")
        XCTAssertFalse(app.buttons["Next"].exists, "the last welcome page still offers Next")

        app.buttons["Get Started"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "finishing the welcome did not land on the app")
    }

    func testTheWelcomeIsNotShownAgain() {
        let cairn = CairnApp(onboarded: true)
        cairn.waitUntilReady()
        XCTAssertFalse(cairn.app.staticTexts["Your driving log"].exists, "the welcome came back for an owner who has seen it")
        XCTAssertTrue(cairn.app.tabBars.firstMatch.exists, "no tab bar")
    }

    func testEveryTabOpensAndStaysUp() {
        let cairn = CairnApp(demo: "streaming", trips: true)
        cairn.waitUntilReady()

        for tab in CairnApp.Tab.allCases {
            cairn.go(to: tab)
            cairn.assertAlive(tab.rawValue)
            XCTAssertTrue(
                cairn.app.tabBars.buttons[tab.rawValue].isSelected,
                "tapping \(tab.rawValue) did not select it"
            )
        }
    }

    func testEachTabNamesItself() {
        let cairn = CairnApp(demo: "streaming", trips: true)
        cairn.waitUntilReady()

        // Drive is the one screen with no navigation title; it says "Cairn" in its own header.
        let expected: [CairnApp.Tab: String] = [.drive: "Cairn", .trips: "Trips", .garage: "Garage", .settings: "Settings"]
        for (tab, heading) in expected {
            cairn.go(to: tab)
            XCTAssertTrue(
                cairn.app.staticTexts[heading].waitForExistence(timeout: 10) || cairn.app.navigationBars[heading].waitForExistence(timeout: 2),
                "the \(tab.rawValue) tab does not show \"\(heading)\" anywhere"
            )
        }
    }

    func testGoingRoundTheTabsRepeatedlyDoesNotBreakIt() {
        let cairn = CairnApp(demo: "streaming", trips: true)
        cairn.waitUntilReady()
        for _ in 0..<3 {
            for tab in CairnApp.Tab.allCases { cairn.go(to: tab) }
        }
        cairn.assertAlive("after three laps of the tab bar")
    }
}
