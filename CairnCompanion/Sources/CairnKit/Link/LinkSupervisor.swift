import CairnProtocol
import Foundation

/// Joins the machine to a central and to a clock, and nothing else.
///
/// It is deliberately small. Every decision is in `LinkMachine`; this pumps events into it,
/// performs what comes back, schedules the one wake-up the machine asks for, and mirrors the log
/// so the Dongle screen can export it. If a bench row behaves differently on hardware than in
/// CI, the difference is in `CoreBluetoothCentral` or in the radio — not here.
@MainActor
@Observable
public final class LinkSupervisor {
    public private(set) var machine: LinkMachine
    private let central: any Central
    private let clock: any LinkClock
    /// Where transitions are mirrored for export. Nil in a test.
    private let sink: ((LinkLogEntry) -> Void)?

    /// Called on every state change. The priming policy is the only listener today: the
    /// background location session starts when the link is ready and at no other time.
    public var onTransition: (@MainActor (_ from: LinkState, _ to: LinkState) -> Void)?
    /// Every notification, with its bytes. The machine itself only remembers *when* each
    /// channel was last heard; what `GNSS_QUALITY` actually said is R2's whole measurement.
    public var onNotify: (@MainActor (CairnGATT.Characteristic, Data) -> Void)?

    private var inbox: [LinkEvent] = []
    private var isPumping = false
    private var mirroredUpTo = -1

    public init(
        machine: LinkMachine = LinkMachine(),
        central: any Central,
        clock: any LinkClock = SystemLinkClock(),
        sink: ((LinkLogEntry) -> Void)? = nil
    ) {
        self.machine = machine
        self.central = central
        self.clock = clock
        self.sink = sink
        central.onEvent = { [weak self] event in self?.deliver(event) }
    }

    // MARK: - What the screens read

    public var state: LinkState { machine.state }
    public var ready: LinkReady? { machine.ready }
    public var log: LinkLog { machine.log }
    public var advice: String? { machine.advice }
    public var lastRSSI: Int? { machine.lastRSSI }
    public var attempt: Int { machine.attempt }
    public var subscriptionFailures: [CairnGATT.Characteristic: LinkFailure] { machine.subscriptionFailures }

    /// How long the link has been in this state. The Dongle screen shows it, because "connecting"
    /// for two seconds and "connecting" for four minutes are different problems.
    public func timeInState(now: Date? = nil) -> TimeInterval? {
        guard let since = stateEntered else { return nil }
        return (now ?? clock.now).timeIntervalSince(since)
    }

    private var stateEntered: Date?

    // MARK: - What the buttons call

    public func start() { deliver(.startRequested) }
    public func stop() { deliver(.stopRequested) }
    public func retry() { deliver(.retryRequested) }
    public func forget() { deliver(.forgetRequested) }

    /// Ask the dongle to describe itself again.
    ///
    /// `DEVICE_INFO` is built when it is read, so it reports the state at that moment rather
    /// than at connect: a card that has since mounted, bundles that have since sealed, and —
    /// the one that matters for R2 — `boot_to_first_fix_ms`, which is unknown at link-ready
    /// and known a minute later. Re-reading it once the receiver reports a fix is how the
    /// phone learns the dongle's own time to first fix without anybody reading a serial log.
    public func refreshDeviceInfo() {
        guard let ready = machine.ready,
              ready.version.hasDeviceInformation, ready.has(.deviceInfo) else { return }
        central.perform(.read(.deviceInfo))
    }

    /// Write to the dongle. Returns `.notAvailable` unless the link is ready and this firmware
    /// exposes the characteristic — both halves, always.
    @discardableResult
    public func write(_ data: Data, to characteristic: CairnGATT.Characteristic) -> WriteOutcome {
        guard let ready = machine.ready, ready.has(characteristic) else { return .notAvailable }
        // The link reports `ready` before `maximumWriteValueLength` has settled, so a write can
        // be asked for in the half-second while the machine is still re-measuring. Refuse it
        // rather than hand CoreBluetooth a payload it will truncate.
        guard data.count <= ready.writeLength else { return .notAvailable }
        return central.write(data, to: characteristic)
    }

    // MARK: - The pump

    /// One event in, its effects out, and whatever those effects provoke after that.
    ///
    /// Queued rather than recursive: an effect can make the central produce an event
    /// immediately, and a machine re-entered mid-transition is a machine whose state nobody can
    /// reason about.
    public func deliver(_ event: LinkEvent) {
        inbox.append(event)
        guard !isPumping else { return }
        isPumping = true
        defer { isPumping = false }

        while !inbox.isEmpty {
            let next = inbox.removeFirst()
            let before = machine.state
            let effects = machine.handle(next, now: clock.now)
            if before != machine.state {
                stateEntered = clock.now
                onTransition?(before, machine.state)
            }
            if case .notified(let characteristic, let data) = next {
                onNotify?(characteristic, data)
            }
            mirror()
            for effect in effects { central.perform(effect) }
        }
        clock.wake("link", at: machine.nextDeadline) { [weak self] in self?.deliver(.tick) }
    }

    /// Write a line into the link log from outside the machine — the receiver timeline, say.
    /// The log is the record of what the phone saw, and the receiver is part of that.
    public func note(_ detail: String) {
        machine.note(detail, at: clock.now)
        mirror()
    }

    private func mirror() {
        guard let sink else { return }
        for entry in machine.log.entries where entry.id > mirroredUpTo {
            sink(entry)
            mirroredUpTo = entry.id
        }
    }

    /// The log as text, with a header naming the build and the dongle, ready to paste into a
    /// bench record or an issue. This is the thing firmware #44 has been waiting for.
    public func exportLog(build: BuildIdentity? = nil) -> String {
        var header = ["Cairn link log"]
        if let build { header.append("app \(build.fullDescription)") }
        if let ready = machine.ready {
            header.append("dongle \(ready.peripheral) · \(ready.version.shortDescription) · \(ready.writeLength) B writes")
            if let info = ready.deviceInfo, let firmware = info.firmware {
                header.append("firmware \(firmware.major).\(firmware.minor).\(firmware.patch)")
            }
        } else if let peripheral = machine.state.peripheral {
            header.append("dongle \(peripheral)")
        }
        header.append("state \(machine.state.name)" + (machine.state.failure.map { " · \($0)" } ?? ""))
        if let rssi = machine.lastRSSI { header.append("last signal \(rssi) dBm") }
        for (characteristic, failure) in machine.subscriptionFailures.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            header.append("subscribe \(characteristic.title) failed: \(failure)")
        }
        return machine.log.export(header: header)
    }
}
