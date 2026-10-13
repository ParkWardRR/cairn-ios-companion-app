import XCTest

/// Launching the app the way a test wants it, and the few checks every test repeats.
///
/// Two seams make this possible without touching the app: `UserDefaults` reads the launch
/// arguments as a volatile domain, so `-cairn.hasSeenWelcome YES` skips onboarding without
/// writing to the simulator's disk; and `DemoMode` (DEBUG only) seeds a canned BLE scenario and
/// a few finished drives, since a simulator has no Bluetooth and no dongle.
@MainActor
struct CairnApp {
    let app = XCUIApplication()

    enum Tab: String, CaseIterable {
        case drive = "Drive", trips = "Trips", garage = "Garage", settings = "Settings"
    }

    /// - Parameters:
    ///   - demo: a `CAIRN_DEMO` scenario: streaming, waiting, syncing, failed, staleBond, dropped, silent.
    ///   - trips: seed finished drives, so the Trips tab has something in it.
    ///   - onboarded: false to get the welcome pages a first-time owner sees.
    ///   - tab: which tab to open on.
    ///   - link: a `cairn://configure?...` link, handed over directly (the simulator has no camera).
    @discardableResult
    init(demo: String? = nil, trips: Bool = false, onboarded: Bool = true, tab: Tab? = nil, link: String? = nil) {
        app.launchArguments = ["-cairn.hasSeenWelcome", onboarded ? "YES" : "NO"]
        var env = ["CAIRN_UITEST": "1"]
        if let demo { env["CAIRN_DEMO"] = demo }
        if trips { env["CAIRN_DEMO_TRIPS"] = "1" }
        if let tab { env["CAIRN_DEMO_TAB"] = String(Tab.allCases.firstIndex(of: tab)!) }
        if let link { env["CAIRN_TEST_LINK"] = link }
        app.launchEnvironment = env
        app.launch()
    }

    /// The app is up and showing its own UI, rather than a crash dialog or a blank window.
    func waitUntilReady(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not reach the foreground", file: file, line: line)
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 20) || app.staticTexts["Your driving log"].waitForExistence(timeout: 5),
            "neither the tab bar nor the welcome pages appeared",
            file: file, line: line
        )
    }

    func go(to tab: Tab, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.tabBars.buttons[tab.rawValue]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no \(tab.rawValue) tab", file: file, line: line)
        button.tap()
    }

    /// Still alive and still drawing. A SwiftUI view that traps takes the whole app with it, so
    /// this is the assertion that catches the worst class of bug.
    func assertAlive(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "\(what): the app is no longer in the foreground (it most likely crashed)", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).count < 3, "\(what): the screen is empty", file: file, line: line)
    }

    /// Every piece of text on screen, for assertions about what the owner can actually read.
    func visibleText() -> [String] {
        app.descendants(matching: .staticText).allElementsBoundByIndex.compactMap {
            $0.exists ? $0.label : nil
        }
    }

    func text(containing needle: String) -> Bool {
        visibleText().contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// The tappable drive cards on the Trips tab. Not `cells`: a `List` section header is a cell
    /// too, and tapping it does nothing, which looks exactly like a broken link.
    /// `matching`, not `containing`: a drive card is one combined accessibility element whose own
    /// label is the whole card ("7:04 PM, 41.5 km, Distance, 38 min, Duration, ..."), so it has no
    /// descendants to filter on.
    var driveCards: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Duration"))
    }
}
