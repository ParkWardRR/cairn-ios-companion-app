# Cairn Companion iOS App

BLE companion app for the Cairn ESP32 OBD-II/GPS logger dongle. **Being rebuilt from scratch**
since 2026-11-04: the design and the audit that prompted it are in the front door's
`docs/ios-rewrite-plan.md`, the schedule is Phase 37 of the one roadmap. The first app is at tag
`legacy-v1` and on branch `legacy`.

## Build & Test

```bash
scripts/fetch-contracts.sh         # run first; fetches the pinned contracts into .contracts/
cd CairnCompanion && swift build   # macOS debug build
cd CairnCompanion && swift test    # CairnProtocolTests + CairnKitTests
cd CairnCompanion && xcodegen generate   # regenerate the Xcode project after a project.yml change
```

For iOS builds, use Xcode (`CairnCompanion/CairnCompanion.xcodeproj`), regenerated from
`project.yml` — never hand-edit the pbxproj.

## Architecture

Four SPM targets inside `CairnCompanion/`, plus the app target. The rule: anything with a
decision in it builds and tests on macOS; anything that needs a radio, a receiver, the Keychain
or the network is a thin adapter behind a protocol.

- **CairnProtocol** — wire bytes and the vectors that pin them. No I/O, not even a URLSession
  type: GATT payloads, offload framing, `Cairn-Sig`, the enrolment proof, `ContractVectors`.
- **CairnKit** — every decision, pure and event-driven: `LinkMachine`, `PrimingPolicy`,
  `OffloadMachine`, the sync engine, `CairnServerClient`, `HUDBuilder`, the display models.
- **CairnRuntime** — Apple frameworks behind `CairnKit` protocols: `CoreBluetoothCentral`,
  the location source, `SecureEnclaveIdentity`, `PinnedCA`, `URLSessionTransport`, the GRDB store.
- **App** — SwiftUI screens and one `AppModel`.

### Rules that came out of the audit

- The link is a **value type driven by events**. Every CoreBluetooth delegate call becomes one
  event with its error code preserved, so a pairing failure is never just "disconnected".
- **One `AppModel`** (`@MainActor @Observable`) owns the machines. No two objects write the same
  state. The old app had five objects mutating overlapping fields.
- Every machine **writes a log line on each transition**; the log is a ring buffer the Dongle
  screen can export. Firmware #44 could not be settled from the Mac, so the phone must be able
  to say what it saw.
- Characteristics are discovered with a **`nil` filter** and features are gated on presence
  **and** the `PROTOCOL_VERSION` capability bits. A filtered discovery list that omitted `0030`
  and `0031` is why bundle offload was dead code for a month.
- **Built is not Proven.** A phase closes on a bench record in `docs/bench/` with the date, the
  firmware commit, the app build number and the numbers the plan asks for — never on a green CI
  run.
- **Decisions live in `CairnKit`, adapters hold none.** `CoreBluetoothCentral` translates and
  nothing else; `OffloadRunner` talks and `OffloadMachine` decides. When a bench row behaves
  differently on hardware than in CI, that split is what says where to look.
- **A receipt is written before the dongle is asked to take it.** Between the server committing
  and the dongle verifying, a trip exists in two places and is owned by neither. A phone that
  dies in that window and forgets the receipt makes the dongle keep the trip forever.

### Screens

`Dongle` (link state, signal, write length, firmware version, capability bits, the receiver
timeline, what is waiting for the server, the last error with its own numeric code, Retry /
Forget / Export Log), `Trips` (grouped by day, with a route map on the detail screen) and
`Settings` (build identity, channel, export log). Garage, CarPlay and the in-app dashboard
arrive in R5.

### Where the phases got to

R0–R4 are **built**; **nothing is Proven** and `docs/bench/` is empty, because there is no
dongle and no server on this Mac. Three things wait on the owner: a contracts tag (three
additive changes sit on the front door's `main` untagged), the firmware flash for R2
([firmware #67](https://github.com/ParkWardRR/cairn-esp32-device-firmware/pull/67)), and
accepting the Apple Program License Agreement so a TestFlight export can be signed.

## Contracts

`contracts.lock` pins a contracts release by tag **and** commit, so a moved tag cannot change
what this app builds against. `scripts/fetch-contracts.sh` fetches it into `.contracts/`
(git-ignored); run it before `swift test`. `CAIRN_CONTRACTS=<dir>` points the tests at a local
checkout instead, which `--release` refuses. Nothing is vendored: the BLE golden vectors, the
offload vectors and the `sync/v1` exchange vectors are read from there through
`ContractVectors`. Bumping the pin is the only way to change them, and a contract change goes to
the contracts repository first, additive, with vectors and the owner's go-ahead for the tag.

## Security constraints

- **Never commit the server URL**, the team id or the dashboard's host name. They live in
  UserDefaults and `Config/Local.xcconfig`. Use `cairn.example.lan` as the placeholder.
- The SPKI pin is enforced on the LAN URL; the Tailnet URL validates normally (`sync/v1` §9).
- Sensitive data directories use `.completeUntilFirstUserAuthentication` file protection and
  `isExcludedFromBackup`.

## Release

The build number is `git rev-list --count HEAD`, computed by `scripts/release-testflight.sh`,
passed to `xcodebuild` and read back out of the archive. Never type it into `project.yml`: the
old app carried 12 there and 13 in its pbxproj at the same time.

## CI

- GitHub Actions workflows must use `runs-on: self-hosted`. Never GitHub-hosted runners.
- This repo's runner is a **macOS** LaunchAgent on the author's Mac (`cairn-mac-ios`), not the
  Podman host the other repos use: a Linux runner cannot build `CairnRuntime` (CoreBluetooth,
  Core Location, CryptoKit, UIKit). If CI sits queued, check the LaunchAgent is up.

## Plan

The project keeps **one** roadmap, in the front door repo (`ROADMAP.md`). Do not start one here.
This app's work is Phase 37, sub-phases R0–R6, designed in the front door's
`docs/ios-rewrite-plan.md`.

## Related repos

- Front door + the one roadmap + the contracts: `ParkWardRR/cairn-driving-log-selfhosted`
- Server: `ParkWardRR/cairn-vehicle-server` (enrolment, sync, relay, revocation APIs). Its
  `cmd/cairn-phone` and `internal/offloadclient/` are the reference this app's BLE offload
  matches.
- Firmware: `ParkWardRR/cairn-esp32-device-firmware`
- Web dashboard: `ParkWardRR/cairn-vehicle-web-dashboard`
- Modules: `ParkWardRR/cairn-modules`
