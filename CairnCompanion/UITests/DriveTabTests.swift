import XCTest

/// The Drive tab in each state a link can be in. A simulator has no Bluetooth, so these come
/// from `DemoMode`'s canned scenarios — the same ones used for screenshots.
@MainActor
final class DriveTabTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Every scenario and the connection stage the owner should be told about.
    private static let scenarios: [(demo: String, stage: String)] = [
        ("streaming", "Streaming"),
        ("waiting", "Waiting for Cairn"),
        ("syncing", "Connecting"),
        ("dropped", "Connecting"),
        ("silent", "Connected, no data"),
        ("failed", "Unsupported protocol v2"),
        ("staleBond", "Stale pairing"),
    ]

    func testEveryLinkStateSaysWhatIsHappening() {
        for (demo, stage) in Self.scenarios {
            let cairn = CairnApp(demo: demo)
            cairn.waitUntilReady()
            XCTAssertTrue(
                cairn.app.staticTexts[stage].waitForExistence(timeout: 15),
                "CAIRN_DEMO=\(demo): the status card does not say \"\(stage)\" — it says \(cairn.visibleText().prefix(12))"
            )
            cairn.assertAlive("CAIRN_DEMO=\(demo)")
            cairn.app.terminate()
        }
    }

    func testWaitingTellsTheOwnerWhatToCheck() {
        let cairn = CairnApp(demo: "waiting")
        cairn.waitUntilReady()
        // A spinner with no advice is the worst version of this screen.
        XCTAssertTrue(
            cairn.text(containing: "powered on and nearby"),
            "waiting for the dongle gives no hint about what to check"
        )
    }

    func testAStalePairingOffersTheWayOut() {
        let cairn = CairnApp(demo: "staleBond")
        cairn.waitUntilReady()
        XCTAssertTrue(cairn.text(containing: "pairing keys changed"), "a stale pairing does not explain itself")
        XCTAssertTrue(
            cairn.app.buttons["Forget Dongle"].waitForExistence(timeout: 10),
            "a stale pairing offers no way to forget the dongle, which is the only fix"
        )
        // The three steps the owner has to follow are on screen, not hidden behind the button.
        XCTAssertTrue(cairn.text(containing: "Forget This Device"), "the re-pairing steps are not shown")
    }

    func testAFailedLinkSaysHowToRetry() {
        let cairn = CairnApp(demo: "failed")
        cairn.waitUntilReady()
        XCTAssertTrue(cairn.text(containing: "Unsupported protocol"), "the failure reason is not shown")
        XCTAssertTrue(cairn.text(containing: "auto-connect off and back on"), "a failed link does not say how to retry")
    }

    func testAutoConnectCanBeTurnedOffAndOn() {
        let cairn = CairnApp(demo: "streaming")
        cairn.waitUntilReady()
        let toggle = cairn.app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no auto-connect switch on the Drive tab")

        let before = toggle.value as? String
        toggle.tap()
        // The switch has to actually move: a toggle bound to a getter that ignores the setter
        // looks identical until you try it.
        XCTAssertNotEqual(toggle.value as? String, before, "the auto-connect switch did not change when tapped")
        cairn.assertAlive("after turning auto-connect off")

        toggle.tap()
        XCTAssertEqual(toggle.value as? String, before, "the auto-connect switch did not come back")
        cairn.assertAlive("after turning auto-connect back on")
    }

    func testTheHelpGuideOpensAndCloses() {
        let cairn = CairnApp(demo: "waiting")
        cairn.waitUntilReady()
        let help = cairn.app.buttons.matching(identifier: "questionmark.circle").firstMatch
        guard help.waitForExistence(timeout: 5) else {
            return XCTFail("no help button in the Drive header")
        }
        help.tap()
        cairn.assertAlive("the connection guide")
        // Whatever it is, there must be a way back to the app.
        let dismiss = cairn.app.buttons["Done"].exists ? cairn.app.buttons["Done"]
            : cairn.app.buttons["Close"].exists ? cairn.app.buttons["Close"]
            : cairn.app.navigationBars.buttons.firstMatch
        XCTAssertTrue(dismiss.exists, "the connection guide has no way out")
        dismiss.tap()
        XCTAssertTrue(cairn.app.tabBars.firstMatch.waitForExistence(timeout: 10), "closing the guide did not return to the app")
    }

    func testStreamingShowsLiveNumbers() {
        let cairn = CairnApp(demo: "streaming")
        cairn.waitUntilReady()
        XCTAssertTrue(cairn.app.staticTexts["Streaming"].waitForExistence(timeout: 15))
        // The demo feeds a fix every 500 ms; something on the screen has to be counting.
        let first = cairn.visibleText().joined(separator: "|")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertNotEqual(first, cairn.visibleText().joined(separator: "|"), "nothing on the Drive tab updates while streaming")
    }
}
