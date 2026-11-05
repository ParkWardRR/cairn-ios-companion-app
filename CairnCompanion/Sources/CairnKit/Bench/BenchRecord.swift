import CairnProtocol
import Foundation

/// One row of the plan's R1 bench matrix.
///
/// Verbatim from the front door's `docs/ios-rewrite-plan.md`, because a bench run that is
/// remembered differently from the plan it closes is a bench run that closes nothing.
public struct BenchRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let setup: String
    public let expectation: String

    public init(id: String, name: String, setup: String, expectation: String) {
        self.id = id
        self.name = name
        self.setup = setup
        self.expectation = expectation
    }
}

public enum BenchMatrix {
    /// R1's eight rows. Each one has a unit test against `FakeCentral` (`BenchMatrixTests`);
    /// these are the hardware halves of the same eight.
    public static let r1: [BenchRow] = [
        BenchRow(
            id: "fresh-pair", name: "Fresh pair",
            setup: "dongle `CLEAR bonds` via the prov console; phone has no bond",
            expectation: "ready in under 10 s, no dialog"
        ),
        BenchRow(
            id: "dongle-reboot", name: "Dongle reboot",
            setup: "power-cycle the dongle while ready",
            expectation: "ready again in under 5 s, no dialog"
        ),
        BenchRow(
            id: "app-killed", name: "App killed",
            setup: "swipe the app away; the dongle re-advertises",
            expectation: "relaunched by iOS, ready in under 10 s"
        ),
        BenchRow(
            id: "phone-stale", name: "Phone stale",
            setup: "phone forgets the device, dongle keeps its bond",
            expectation: "the firmware drops its bond on PINKEY_MISSING; ready after one retry"
        ),
        BenchRow(
            id: "dongle-stale", name: "Dongle stale",
            setup: "dongle `CLEAR bonds`, phone keeps its bond",
            expectation: "needsForget within 3 attempts, message names the fix"
        ),
        BenchRow(
            id: "wifi-slot", name: "Wi-Fi slot",
            setup: "dongle drops BLE for a Wi-Fi slot",
            expectation: "backoff, then ready when advertising returns, no user action"
        ),
        BenchRow(
            id: "locked-phone", name: "Locked phone",
            setup: "lock the phone while ready; reboot the dongle",
            expectation: "ready again with the screen off"
        ),
        BenchRow(
            id: "weak-link", name: "Weak link",
            setup: "dongle 10 m away behind a wall",
            expectation: "discovery fails, backoff with RSSI shown, never needsForget"
        ),
    ]

    /// The line dropped into the link log when a row is started, so an exported log is
    /// segmented by row instead of being one undifferentiated hour.
    public static func marker(_ row: BenchRow) -> String {
        "────── bench row: \(row.name) ──────"
    }

    public static func isMarker(_ detail: String) -> Bool {
        detail.hasPrefix("────── bench row: ")
    }

    public static func rowName(fromMarker detail: String) -> String? {
        guard isMarker(detail) else { return nil }
        return detail
            .replacingOccurrences(of: "────── bench row: ", with: "")
            .replacingOccurrences(of: " ──────", with: "")
    }
}

/// What the link actually did, read back out of its own log.
///
/// Derived rather than counted as it happens, because the log is the thing that gets exported
/// and a number that cannot be checked against it is a number nobody should trust. Everything
/// here can be found by hand in the same file.
public struct BenchObservations: Sendable, Equatable {
    /// One arrival at `ready`: which row was being run, and how long it took from the first
    /// scan or connect of that attempt.
    public struct Arrival: Sendable, Equatable {
        public let row: String?
        public let seconds: TimeInterval
        public let at: Date
    }

    public var arrivals: [Arrival] = []
    public var pairingFailures = 0
    public var needsForget = 0
    public var backoffs = 0
    public var connectTimeouts = 0
    public var subscriptionFailures = 0
    /// Every distinct failure seen, with its code, newest last.
    public var failures: [String] = []

    public var fastest: TimeInterval? { arrivals.map(\.seconds).min() }
    public var slowest: TimeInterval? { arrivals.map(\.seconds).max() }

    public init() {}

    /// Read a log back.
    ///
    /// An *attempt* starts at the first transition into `scanning` or `connecting` after the
    /// machine was idle, off, backing off or asking for help, and ends when it reaches `ready`.
    /// That is the interval the matrix's "ready in under 10 s" is about: not the time since
    /// launch, and not the time since the last packet.
    public init(from log: LinkLog) {
        var currentRow: String?
        var attemptStartedAt: Date?

        for entry in log.entries {
            if let row = BenchMatrix.rowName(fromMarker: entry.detail) {
                currentRow = row
                attemptStartedAt = nil
                continue
            }
            if entry.kind == .failure {
                failures.append(entry.detail)
                if entry.detail.contains("did not complete in 15 s") { connectTimeouts += 1 }
                continue
            }
            if entry.kind == .event, entry.detail.hasPrefix("subscribe "), entry.detail.contains("failed") {
                subscriptionFailures += 1
                continue
            }
            guard entry.kind == .transition else { continue }

            switch entry.state {
            case "scanning", "connecting":
                if attemptStartedAt == nil { attemptStartedAt = entry.at }
            case "securing":
                break // part of the same attempt
            case "backoff":
                backoffs += 1
                attemptStartedAt = nil
            case "needsForget":
                needsForget += 1
                attemptStartedAt = nil
            case "ready":
                if let started = attemptStartedAt {
                    arrivals.append(Arrival(
                        row: currentRow, seconds: entry.at.timeIntervalSince(started), at: entry.at
                    ))
                    attemptStartedAt = nil
                }
            case "idle", "off":
                attemptStartedAt = nil
            default:
                break
            }
        }

        // A pairing failure is not a state of its own: it is a disconnect inside `securing`
        // within the window, and the machine says so in the line it writes next.
        pairingFailures = log.entries.filter {
            $0.state == "securing" && $0.detail.hasPrefix("disconnected")
        }.count
    }
}

/// The bench record, as the markdown file that closes a phase.
///
/// The plan is explicit that **Built is not Proven**, and that a phase closes only when a file
/// under `docs/bench/` carries the date, the firmware commit, the app build number and the
/// numbers the phase asks for. Producing that by hand after an hour on a bench is how a figure
/// gets remembered rather than recorded, so the app writes everything it already knows and
/// leaves blanks only where a person is the only source.
public enum BenchRecord {
    public static func markdown(
        subject: String = "ble-pairing",
        at now: Date,
        build: BuildIdentity,
        state: LinkState,
        ready: LinkReady?,
        lastRSSI: Int?,
        timeline: ReceiverTimeline,
        offload: OffloadSummary?,
        log: LinkLog
    ) -> String {
        let observations = BenchObservations(from: log)
        var out = ""

        out += "# Bench: \(subject), \(Self.day(now))\n\n"
        out += "> Written by the app on the bench. Anything in **[ ]** is a blank only a person\n"
        out += "> can fill: which row was being run, what the dongle's serial log said, and\n"
        out += "> whether the row passed. Everything else the phone observed itself.\n\n"

        out += "## What was running\n\n"
        out += "| | |\n|---|---|\n"
        out += "| Date | \(Self.day(now)) |\n"
        out += "| App | `\(build.fullDescription)` |\n"
        out += "| Firmware commit | **[ fill in: the commit flashed ]** |\n"
        if let info = ready?.deviceInfo, let firmware = info.firmware {
            out += "| Firmware version | \(firmware.major).\(firmware.minor).\(firmware.patch) (from `DEVICE_INFO`) |\n"
        } else {
            out += "| Firmware version | not read — `DEVICE_INFO` did not arrive |\n"
        }
        out += "| Dongle | \(ready?.peripheral.description ?? state.peripheral?.description ?? "never seen") |\n"
        if let ready {
            out += "| Protocol | \(ready.version.shortDescription) |\n"
            out += "| Write length | \(ready.writeLength) B |\n"
            out += "| Characteristics | \(ready.present.map(\.title).sorted().joined(separator: ", ")) |\n"
        }
        if let lastRSSI { out += "| Last signal | \(lastRSSI) dBm |\n" }
        out += "| Car | **[ fill in: which car, or a bench ]** |\n"
        out += "| Ended in | `\(state.name)`\(state.failure.map { " · \($0)" } ?? "") |\n\n"

        out += Self.matrixSection(observations)
        out += Self.observationsSection(observations)

        if timeline.linkReadyAt != nil {
            out += "## Receiver\n\n"
            out += "The phone's own time-to-first-fix line, in seconds since the link came up.\n"
            out += "Set it beside the dongle's `TTFF` line for the same receiver start.\n\n"
            out += "```\n\(timeline.line)\n```\n\n"
            out += "| | |\n|---|---|\n"
            out += "| Position hint sent | \(timeline.sentPositionHint ? "yes" : "no") |\n"
            out += "| TTFF 2D | \(Self.seconds(timeline.ttff2D)) |\n"
            out += "| TTFF 3D | \(Self.seconds(timeline.ttff3D)) |\n"
            out += "| Dongle's own TTFF line | **[ paste from the serial log ]** |\n\n"
        }

        if let offload, offload.delivered > 0 || offload.waiting > 0 || offload.stopped != nil {
            out += "## Offload\n\n| | |\n|---|---|\n"
            out += "| Trips carried | \(offload.delivered) |\n"
            out += "| Waiting on the dongle | \(offload.waiting) |\n"
            out += "| Bytes | \(offload.bytesUploaded) |\n"
            if let stopped = offload.stopped {
                out += "| Stopped | `\(stopped.code)` — \(stopped.sentence) |\n"
            }
            out += "\n"
        }

        out += "## The link log\n\n"
        out += "Every transition, with the state it happened in and, for a failure, the number\n"
        out += "the radio gave. Seconds are relative to the first line.\n\n"
        out += "```\n"
        out += log.export(header: ["app \(build.fullDescription)"])
        out += "```\n"
        return out
    }

    private static func matrixSection(_ observations: BenchObservations) -> String {
        var out = "## The matrix\n\n"
        out += "Each row runs twice. A row passes only when both runs do.\n\n"
        out += "| Row | Setup | Expect | Run 1 | Run 2 |\n|---|---|---|---|---|\n"
        for row in BenchMatrix.r1 {
            let seen = observations.arrivals.filter { $0.row == row.name }
            func cell(_ index: Int) -> String {
                guard index < seen.count else { return "[ ]" }
                return String(format: "%.1f s", seen[index].seconds)
            }
            out += "| **\(row.name)** | \(row.setup) | \(row.expectation) | \(cell(0)) | \(cell(1)) |\n"
        }
        out += "\nA figure in a Run column is what the phone measured from the first scan or\n"
        out += "connect of that attempt to `ready`, for an attempt made after that row's marker\n"
        out += "was tapped. `[ ]` means the row has not been run under a marker yet.\n\n"
        return out
    }

    private static func observationsSection(_ observations: BenchObservations) -> String {
        var out = "## What the phone saw\n\n| | |\n|---|---|\n"
        out += "| Times it reached ready | \(observations.arrivals.count) |\n"
        out += "| Fastest | \(Self.seconds(observations.fastest)) |\n"
        out += "| Slowest | \(Self.seconds(observations.slowest)) |\n"
        out += "| Pairing failures | \(observations.pairingFailures) |\n"
        out += "| Times it asked to be forgotten | \(observations.needsForget) |\n"
        out += "| Backoffs | \(observations.backoffs) |\n"
        out += "| Connect timeouts | \(observations.connectTimeouts) |\n"
        out += "| Subscriptions that failed | \(observations.subscriptionFailures) |\n\n"

        if !observations.failures.isEmpty {
            out += "Failures, in order:\n\n"
            for failure in observations.failures.suffix(30) { out += "- `\(failure)`\n" }
            out += "\n"
        }
        return out
    }

    private static func seconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.1f s", $0) } ?? "—"
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `ble-pairing-2026-11-05.md` — the file name the plan asks for under `docs/bench/`.
    public static func filename(subject: String, at date: Date) -> String {
        "\(subject)-\(day(date)).md"
    }
}
