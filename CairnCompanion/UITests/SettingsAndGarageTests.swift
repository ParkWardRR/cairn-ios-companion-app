import XCTest

/// Settings and Garage: the screens where the owner changes something, plus the setup link a QR
/// code carries. Nothing here touches a real server — the point is that the controls work and
/// that a destructive one asks first.
@MainActor
final class SettingsAndGarageTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSettingsShowsItsSections() {
        let cairn = CairnApp(tab: .settings)
        cairn.waitUntilReady()
        cairn.go(to: .settings)
        XCTAssertTrue(cairn.app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings has no title")

        // Only the sections that do not depend on a server being configured. Dashboard, sync and
        // diagnostics are behind `syncClient.hasServer` by design, and this app has no server set.
        for section in ["Identity", "Fuel", "Bluetooth"] {
            XCTAssertTrue(
                cairn.text(containing: section),
                "Settings is missing its \(section) section: \(cairn.visibleText().prefix(20))"
            )
        }
        XCTAssertFalse(
            cairn.text(containing: "Dashboard"),
            "the Dashboard section is offered with no server configured, so it cannot work"
        )
        cairn.assertAlive("Settings")
    }

    func testTheEthanolBlendCanBeChangedAndSticks() {
        let cairn = CairnApp(tab: .settings)
        cairn.waitUntilReady()
        cairn.go(to: .settings)
        XCTAssertTrue(cairn.text(containing: "Ethanol blend"), "no ethanol blend control in Settings")

        let stepper = cairn.app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 10), "the ethanol blend has no stepper")
        let before = cairn.visibleText().first { $0.hasPrefix("E") && $0.count <= 4 }
        stepper.buttons.element(boundBy: 1).tap()
        let after = cairn.visibleText().first { $0.hasPrefix("E") && $0.count <= 4 }
        XCTAssertNotEqual(before, after, "the ethanol blend did not change when stepped (was \(before ?? "nil"))")

        // It feeds every trip's economy estimate, so it has to survive a relaunch.
        cairn.app.terminate()
        let again = CairnApp(tab: .settings)
        again.waitUntilReady()
        again.go(to: .settings)
        XCTAssertTrue(again.text(containing: "Ethanol blend"), "Settings did not come back")
        XCTAssertEqual(
            again.visibleText().first { $0.hasPrefix("E") && $0.count <= 4 }, after,
            "the ethanol blend was forgotten when the app restarted"
        )
    }

    func testResettingTheIdentityAsksFirst() {
        let cairn = CairnApp(tab: .settings)
        cairn.waitUntilReady()
        cairn.go(to: .settings)

        let reset = cairn.app.buttons["Reset Identity"]
        guard reset.waitForExistence(timeout: 15) else {
            // Not enrolled, so there is nothing to reset. That is a valid state, not a failure.
            return XCTAssertTrue(cairn.text(containing: "Identity"), "Settings shows no identity section at all")
        }
        reset.tap()
        // Throwing away the enrolment key means a new QR code to get back in; it must confirm.
        XCTAssertTrue(
            cairn.app.alerts.firstMatch.waitForExistence(timeout: 10) || cairn.app.sheets.firstMatch.exists,
            "Reset Identity threw away the enrolment without asking"
        )
        XCTAssertTrue(cairn.text(containing: "forgets this phone's sign-in key"), "the confirmation does not say what is lost")
        (cairn.app.buttons["Cancel"].exists ? cairn.app.buttons["Cancel"] : cairn.app.alerts.buttons.element(boundBy: 0)).tap()
        cairn.assertAlive("after cancelling the identity reset")
    }

    func testGarageOpensAndOffersAVehicle() {
        let cairn = CairnApp(tab: .garage)
        cairn.waitUntilReady()
        cairn.go(to: .garage)
        cairn.assertAlive("Garage")
        // With no vehicles yet there must still be a way to add one.
        let addable = cairn.app.buttons.allElementsBoundByIndex.contains {
            $0.exists && ($0.label.localizedCaseInsensitiveContains("add") || $0.label.localizedCaseInsensitiveContains("vehicle"))
        }
        XCTAssertTrue(
            addable || cairn.app.cells.firstMatch.exists,
            "Garage has neither a vehicle nor a way to add one: \(cairn.visibleText().prefix(20))"
        )
    }

    func testAGarbledSetupLinkIsRefusedWithAnExplanation() {
        let cairn = CairnApp(link: "cairn://configure?nonsense=1")
        cairn.waitUntilReady()
        // Either the alert, or the link is silently dropped — the second is the bug.
        let alert = cairn.app.alerts["Can't use this code"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: 15),
            "a garbled setup link was swallowed without telling the owner"
        )
        XCTAssertTrue(cairn.text(containing: "Ask for a new QR code"), "the refusal does not say what to do next")
        alert.buttons["OK"].tap()
        XCTAssertTrue(cairn.app.tabBars.firstMatch.waitForExistence(timeout: 10), "dismissing the refusal did not return to the app")
    }

    func testSettingsScrollsToTheBottomWithoutBreaking() {
        let cairn = CairnApp(tab: .settings)
        cairn.waitUntilReady()
        cairn.go(to: .settings)
        let table = cairn.app.tables.firstMatch.exists ? cairn.app.tables.firstMatch : cairn.app.collectionViews.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15), "Settings has no scrollable list")
        for _ in 0..<6 { table.swipeUp() }
        cairn.assertAlive("the bottom of Settings")
        for _ in 0..<8 { table.swipeDown() }
        cairn.assertAlive("back at the top of Settings")
    }
}
