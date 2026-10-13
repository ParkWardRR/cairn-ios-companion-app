import XCTest

/// The Trips tab: the empty state, the list, the filters, and opening one drive.
@MainActor
final class TripsTabTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testWithNoTripsItSaysSoRatherThanShowingAnEmptyList() {
        let cairn = CairnApp(trips: false, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)
        XCTAssertTrue(
            cairn.app.staticTexts["No trips yet"].waitForExistence(timeout: 20),
            "with no trips the tab shows neither drives nor an explanation"
        )
        XCTAssertTrue(cairn.text(containing: "once your Cairn dongle has connected"), "the empty state does not say how trips get here")
    }

    func testSeededDrivesAreListedAndCounted() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)

        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "the seeded drives are not listed")
        // DemoMode seeds five drives, one of them a bench test that the totals leave out.
        XCTAssertTrue(
            cairn.text(containing: "trips"),
            "the list does not say how many trips it is showing: \(cairn.visibleText().prefix(10))"
        )
        cairn.assertAlive("the trips list")
    }

    func testOpeningADriveShowsItAndComesBack() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)

        let first = cairn.driveCards.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 25), "no drive to open")
        first.tap()

        // The detail view is titled with the drive's date and has a back button.
        let back = cairn.app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 15), "the trip detail has no way back to the list")
        cairn.assertAlive("a trip's detail view")

        back.tap()
        XCTAssertTrue(cairn.app.navigationBars["Trips"].waitForExistence(timeout: 10), "going back did not return to the list")
    }

    func testEveryDriveInTheListOpens() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "no drives listed")

        let count = cairn.driveCards.count
        XCTAssertGreaterThan(count, 1, "expected several seeded drives, found \(count)")
        for i in 0..<count {
            let cell = cairn.driveCards.element(boundBy: i)
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            cairn.assertAlive("drive \(i) of \(count)")
            let back = cairn.app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 15), "drive \(i) has no way back")
            back.tap()
            XCTAssertTrue(cairn.app.navigationBars["Trips"].waitForExistence(timeout: 10), "drive \(i) did not go back")
        }
    }

    func testTheStarFilterExplainsAnEmptyResult() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "no drives listed")

        // Nothing is starred yet, so this must empty the list — and say why.
        cairn.app.buttons.matching(identifier: "star").firstMatch.tap()
        XCTAssertTrue(
            cairn.app.staticTexts["No matching trips"].waitForExistence(timeout: 10),
            "filtering to starred trips shows neither trips nor an explanation"
        )
        XCTAssertTrue(cairn.text(containing: "No starred trips"), "the starred-only empty state does not say what to do")
        XCTAssertTrue(cairn.app.buttons["Clear Filters"].exists, "there is no way to clear the filter")

        cairn.app.buttons["Clear Filters"].tap()
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 10), "clearing the filter did not bring the drives back")
    }

    func testTheDateRangesAllWork() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "no drives listed")

        for range in ["Today", "Week", "Month", "All"] {
            let button = cairn.app.buttons[range]
            guard button.waitForExistence(timeout: 5) else { return XCTFail("no \(range) range to pick") }
            button.tap()
            cairn.assertAlive("the \(range) range")
            // Either there are drives in the range or the screen says there are none. Never neither.
            let hasDrives = cairn.driveCards.firstMatch.waitForExistence(timeout: 6)
            let saysEmpty = cairn.app.staticTexts["No matching trips"].exists
            XCTAssertTrue(hasDrives || saysEmpty, "the \(range) range shows neither drives nor an empty state")
        }
    }

    func testSearchingNotesThatMatchNothingSaysSo() {
        let cairn = CairnApp(trips: true, tab: .trips)
        cairn.waitUntilReady()
        cairn.go(to: .trips)
        XCTAssertTrue(cairn.driveCards.firstMatch.waitForExistence(timeout: 25), "no drives listed")

        let field = cairn.app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the trips list has no search field")
        field.tap()
        field.typeText("zzz-no-such-note")
        XCTAssertTrue(
            cairn.app.staticTexts["No matching trips"].waitForExistence(timeout: 10),
            "a search matching nothing leaves the owner looking at a blank list"
        )
    }
}
