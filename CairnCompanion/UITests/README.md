# The UI suite

XCUITest driving the real app in a simulator. `swift test` covers CairnCore's logic — 333 tests
and none of them launches the app — so nothing else in this repo notices a view that traps on
appear, a screen with no way back, a toggle bound to a getter that ignores its setter, or a
preference that does not survive a relaunch.

XCUITest rather than Appium or Maestro: the app is native Swift and iOS-only, so XCUITest needs
no extra server to run and goes through the same `xcodebuild` the repo already uses on its
macOS runner. Appium would be the pick if these tests had to share a language with the
dashboard's Playwright suite.

## Running it

```sh
cd CairnCompanion
xcodegen generate                       # the UI test target lives in project.yml
xcodebuild test -project CairnCompanion.xcodeproj -scheme CairnCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

`CODE_SIGN_IDENTITY=-` matters: an unsigned build dies in the Keychain with `-34018` the moment
it tries to read its own key.

One test at a time with `-only-testing:CairnCompanionUITests/DriveTabTests/testWaitingTellsTheOwnerWhatToCheck`.

## How a test gets the app into a state

A simulator has no Bluetooth, no dongle and no camera, so the suite leans on three seams that
already existed for screenshots. `CairnApp` in `CairnApp.swift` wraps all of them:

| Seam | What it does |
| --- | --- |
| `-cairn.hasSeenWelcome YES` (launch argument) | skips onboarding. `UserDefaults` reads launch arguments as a volatile domain, so this writes nothing to disk and leaves no state behind for the next test |
| `CAIRN_DEMO=<scenario>` | a canned BLE link state: streaming, waiting, syncing, failed, staleBond, dropped, silent |
| `CAIRN_DEMO_TRIPS=1` | five finished drives with tracks, one of them a bench test |
| `CAIRN_DEMO_TAB=<n>` | opens on that tab |
| `CAIRN_TEST_LINK=cairn://configure?...` | hands over a setup link as though it were scanned |

All of them are `#if DEBUG`, so none reaches a release build.

## What each file covers

| File | What it holds to account |
| --- | --- |
| `LaunchAndTabsTests` | the welcome pages, that they are not shown twice, and that all four tabs open and stay open |
| `DriveTabTests` | every link state says what is happening and what to do about it; auto-connect toggles; the guide opens and closes |
| `TripsTabTests` | the empty state, the list, every drive opens and comes back, the filters and search explain an empty result |
| `SettingsAndGarageTests` | the sections that do not need a server, the ethanol blend surviving a relaunch, a destructive action asking first, a bad setup link being refused |
| `UnitsTests` | one drive reads in one system of units, on the card, in its detail, and on the Drive tab |

`assertAlive` is in every test that taps something: a SwiftUI view that traps takes the whole app
with it, and that is the worst thing these tests can catch.
