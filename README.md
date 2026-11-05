<!-- cairn-nav:start -->
<p align="center"><b>Cairn is a family of six repositories.</b> Each builds, tests and releases on its own; they agree through the shared <a href="https://github.com/ParkWardRR/cairn-driving-log-selfhosted/tree/main/contracts">contracts</a>, and they share one <a href="https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/ROADMAP.md">roadmap</a>.</p>

| Part | Repository | What it does | Stack | Docs | Issues | CI |
|---|---|---|---|---|---|---|
| Front door | [cairn-driving-log-selfhosted](https://github.com/ParkWardRR/cairn-driving-log-selfhosted) | Docs, roadmap, shared protocol contracts | Markdown · Go tools | [docs](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/tree/main/docs) | [issues](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/issues) | [CI](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/actions) |
| Dongle | [cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware) | In-car recorder: OBD-II, GNSS, IMU to encrypted SD bundles | C++ · C · Rust | [docs](https://github.com/ParkWardRR/cairn-esp32-device-firmware/tree/main/docs) | [issues](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues) | [CI](https://github.com/ParkWardRR/cairn-esp32-device-firmware/actions) |
| Phone | **[cairn-ios-companion-app](https://github.com/ParkWardRR/cairn-ios-companion-app)** ◀ you are here | BLE relay, GPS assist, server client | Swift · SwiftUI | [docs](https://github.com/ParkWardRR/cairn-ios-companion-app/tree/main/docs) | [issues](https://github.com/ParkWardRR/cairn-ios-companion-app/issues) | [CI](https://github.com/ParkWardRR/cairn-ios-companion-app/actions) |
| Server | [cairn-vehicle-server](https://github.com/ParkWardRR/cairn-vehicle-server) | Verifies, decrypts, stores; serves app and dashboard | Go | [docs](https://github.com/ParkWardRR/cairn-vehicle-server/tree/main/docs) | [issues](https://github.com/ParkWardRR/cairn-vehicle-server/issues) | [CI](https://github.com/ParkWardRR/cairn-vehicle-server/actions) |
| Dashboard | [cairn-vehicle-web-dashboard](https://github.com/ParkWardRR/cairn-vehicle-web-dashboard) | Browser UI: trips, places, engine, health | Nuxt · TypeScript | [docs](https://github.com/ParkWardRR/cairn-vehicle-web-dashboard/tree/main/docs) | [issues](https://github.com/ParkWardRR/cairn-vehicle-web-dashboard/issues) | [CI](https://github.com/ParkWardRR/cairn-vehicle-web-dashboard/actions) |
| Modules | [cairn-modules](https://github.com/ParkWardRR/cairn-modules) | Interpretation, separated from the logging core: one package per module | YAML · Rust | [readme](https://github.com/ParkWardRR/cairn-modules#readme) | [issues](https://github.com/ParkWardRR/cairn-modules/issues) | [CI](https://github.com/ParkWardRR/cairn-modules/actions) |

<sub>Shared: [Roadmap](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/ROADMAP.md) · [Install](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/INSTALL.md) · [Architecture](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/docs/architecture.md) · [Threat model](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/docs/threat-model.md) · [Trust model](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/docs/trust-model-v3.md) · [Contracts](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/tree/main/contracts) · [Archive of the original monorepo](https://github.com/ParkWardRR/cairn-original-monorepo-archive)</sub>
<!-- cairn-nav:end -->
<p align="center"><img src="docs/images/app-icon.png" width="112" alt="Cairn Companion app icon"></p>
<h1 align="center">Cairn Companion</h1>
<p align="center"><strong>The iPhone app for Cairn, a self-hosted car driving log. It lends the dongle its GPS, carries the dongle's trips to your own server, and shows you the drive.</strong></p>

<p align="center">
  <a href="https://github.com/ParkWardRR/cairn-ios-companion-app/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/ParkWardRR/cairn-ios-companion-app/test.yml?style=flat-square&label=tests" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Blue_Oak_1.0.0-2E86C1?style=flat-square" alt="Blue Oak Model License 1.0.0"></a>
  <img src="https://img.shields.io/badge/platform-iOS_18+-2E86C1?style=flat-square" alt="iOS 18 and later">
  <img src="https://img.shields.io/badge/rewrite-R4_built-E67E22?style=flat-square" alt="Rewrite phases R0 to R4 built">
</p>

> **This app is being rebuilt from scratch.** The first one is kept at tag
> [`legacy-v1`](https://github.com/ParkWardRR/cairn-ios-companion-app/tree/legacy-v1) and on branch
> `legacy`: 21,000 lines, 333 tests, four tabs, CarPlay and DuckDB — and a Bluetooth link that
> never reliably paired and a GPS assist that was never wired end to end. The design, the audit
> that prompted it and the phases are in the front door's
> [docs/ios-rewrite-plan.md](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/docs/ios-rewrite-plan.md);
> the schedule is Phase 37 of the one
> [roadmap](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/ROADMAP.md).
> Same repository, same bundle id, same entitlements (decision D1).

## What it is for

A small ESP32 dongle in the car's OBD-II port records every drive to an SD card, encrypted. Your
own server holds the history and a web dashboard shows it. This app does three jobs between them:

1. **Prime the dongle's GPS.** The dongle sits low under the dash with a poor view of the sky. The
   phone on the windshield has a better one, so the app hands the receiver the phone's clock and
   the phone's position as hints, and then streams live fixes. The measure is time-to-first-fix,
   recorded with and without the phone.
2. **Carry finished trips.** After a drive the phone pulls the dongle's sealed bundles over
   Bluetooth, uploads them to the server, and hands the server's signed receipt back so the dongle
   can free space. It moves bundles it cannot read or alter.
3. **Show the drive.** Trips come from the server's sync log, with the route from a track endpoint.

## Where the rewrite is

| Phase | What it adds | State |
|---|---|---|
| **R0** | Four targets, the kept codecs with their tests, two screens, build number from the commit count | Built |
| **R1** | `LinkMachine`: a BLE link that pairs every time, and a Dongle screen that can say what it saw | Built |
| **R2** | GPS priming — time and position hints — and streaming that survives a locked phone | Built (app); firmware waiting on a flash |
| **R3** | Enrol with the server, relay bundles, carry the receipt back | Built |
| **R4** | Sync engine, trips list and detail, the route map | Built |
| R5 | Garage, CarPlay, the in-app dashboard, several dongles | — |
| R6 | The enrolled-challenge handshake, once firmware #5 lands | — |

**Built** means it compiles and its tests pass. **Proven** means the dongle and the phone did it
and a bench record under [`docs/bench/`](docs/bench) says so, with the date, the firmware commit,
the app build number and the numbers. A green CI run is not a proof of anything that involves a
radio — and **nothing here is Proven yet**: `docs/bench/` is empty.

## The three screens

**Dongle.** What the link is doing and why it is not doing better: state with time-in-state,
signal, write length, protocol version, capability bits, the firmware version, which
characteristics this firmware actually exposes and when each was last heard, the receiver
timeline (link ready → clock hint → position hint → first 2D → first 3D, in seconds), what is
waiting to be carried to the server, the last error **with the number the radio gave it**, and
Retry / Forget / Export Log. Diagnostics are the first interface on purpose: firmware
[#44](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/44) has been open since
2026-10-10 waiting for a second central to say what it saw.

**Trips.** Every drive the server has published, grouped by day, with a route map on the detail
screen. One row per *outing*, not one per published record — a trip's identity moves, and a list
keyed on it alone shows the same drive twice.

**Settings.** What this build is, and the log it wrote.

## How it is put together

Four targets, because every failure the audit found was in glue no test could reach.

| Target | Holds | Depends on |
|---|---|---|
| `CairnProtocol` | Wire bytes and the vectors that pin them: GATT payloads, offload framing, `Cairn-Sig`, the enrolment proof | Foundation, CryptoKit |
| `CairnKit` | Every decision: `LinkMachine`, `PrimingPolicy`, `OffloadMachine`, the sync engine, the server client, the display models | `CairnProtocol` |
| `CairnRuntime` | Apple frameworks, each behind a `CairnKit` protocol: CoreBluetooth, Core Location, the Secure Enclave, URLSession, GRDB | `CairnKit`, GRDB |
| `App` | SwiftUI screens, and one `AppModel` that owns the machines | `CairnRuntime` |

The rules that follow from the audit: the link is a value type driven by events, and every
CoreBluetooth delegate call becomes one event with its error code preserved; one `AppModel` owns
the state and no two objects write the same field; every transition writes a log line the Dongle
screen can export; characteristics are discovered with a `nil` filter and features are gated on
presence *and* the `PROTOCOL_VERSION` capability bits, so a firmware that adds a characteristic
needs no change here.

## Build and test

```sh
scripts/fetch-contracts.sh          # the pinned contracts into .contracts/ (git-ignored)
cd CairnCompanion && swift test     # CairnProtocolTests + CairnKitTests, on macOS, no device
xcodegen generate                   # the Xcode project, from project.yml
```

Then open `CairnCompanion/CairnCompanion.xcodeproj` for an iOS build. Signing needs
`Config/Local.xcconfig` (copy `Local.xcconfig.example`): it holds your team id, your bundle id and
your dashboard's host name, and it is never committed.

iOS builds and tests run on a Mac — a Linux runner cannot build `CairnRuntime`. CI is a macOS
LaunchAgent runner (`cairn-mac-ios`); if a job sits queued, check the agent is up.

### Contracts

`contracts.lock` pins a contracts release by **tag and commit**, so a moved tag cannot change what
this app is built against. `scripts/fetch-contracts.sh` fetches it into `.contracts/`; nothing is
vendored, so there is no copy to drift. `CAIRN_CONTRACTS=<dir>` points the tests at a local
checkout instead, which `--release` refuses. Bumping the pin is the only way to change the
vectors, and a contract change goes to the contracts repository first, additive, with vectors.

### Releasing

```sh
scripts/release-testflight.sh beta --export-only   # signs and exports, uploads nothing
scripts/release-testflight.sh beta                 # and uploads
```

The build number is `git rev-list --count HEAD`, passed to `xcodebuild` by that script and read
back out of the archive. It is never typed into `project.yml` — the old app carried 12 there and
13 in its pbxproj at the same time.

## Privacy

Your position goes to your dongle over an encrypted, authenticated Bluetooth link and to your own
server, and nowhere else. There is no analytics, no third-party SDK and no telemetry. The server
URL, the team id and the dashboard's host name are never committed to this repository.

## License

[Blue Oak Model License 1.0.0](LICENSE).
