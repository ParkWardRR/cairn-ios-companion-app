import CairnProtocol
import Foundation

/// The link, as a value.
///
/// Feed it events, read its state, perform its effects. It owns no object, starts no task, reads
/// no clock and touches no radio, so every row of the plan's bench matrix is a unit test — which
/// is the point: the old app had 333 tests and none of them touched the layer that failed.
///
/// The rules here are R1 of the front door's `docs/ios-rewrite-plan.md`. Each one exists because
/// of something the audit found, and the comment says which.
public struct LinkMachine: Sendable {
    // MARK: - Rules, as numbers

    /// A pending `connect` never times out on its own, which is how the old app could sit
    /// "connecting" to a saved identifier forever with nothing on screen.
    public static let connectDeadline: TimeInterval = 15
    /// How long to scan before admitting the dongle is not answering. The weak-link bench row
    /// ends here: `backoff` with the last signal shown, never `needsForget`.
    public static let scanWindow: TimeInterval = 20
    /// Where the signal is worth mentioning beside a failure. Measured on this dongle: it joins
    /// an access point at −66..−68 dBm and fails at −71..−72, and BLE held a ready link at
    /// −77..−81, so this is "worth saying", not "the cause".
    public static let weakRSSI = -70
    /// Discovery that never answers is a failure, not a state to live in.
    public static let discoveryDeadline: TimeInterval = 15
    /// How long the `PROTOCOL_VERSION` read may stay in flight. iOS pairs during this read, and
    /// a dialog the owner ignores should become a retry, not a hang.
    public static let securingDeadline: TimeInterval = 30
    /// A disconnect this soon after connecting, while securing, is the dongle's own
    /// "pairing failed, disconnecting" (firmware `src/ble_companion.cpp`
    /// `onAuthenticationComplete`), which reaches a central as a plain link drop.
    public static let pairingFailureWindow: TimeInterval = 60
    /// Three in a row and only the owner can fix it: the app cannot delete an iOS bond.
    public static let pairingFailureLimit = 3
    /// How many encryption failures with no success in between before the advice stops blaming
    /// the signal and starts naming the bond.
    ///
    /// `CBErrorDomain#15` is genuinely ambiguous, and both readings of it were seen on the same
    /// dongle within one hour on 2026-11-05. First a bad link: the phone logged `#15` while the
    /// dongle logged `paired: encrypted=1 bonded=1` on every one of those attempts, so the bond
    /// was perfect and the encryption was merely timing out on sessions lasting 1.7 s. Then a
    /// genuinely stale bond: the dongle dropped its half, so iOS was offering a key that no
    /// longer existed and `#15` was permanent.
    ///
    /// What separates them is not the code, it is whether anything ever succeeds. A bad link
    /// succeeds intermittently — five times, that hour — and a stale bond never succeeds at all.
    /// So this counts *consecutive* failures and `becomeReady` resets it. Reaching the limit
    /// changes what the advice says; it deliberately does **not** go to `needsForget`, because
    /// that is terminal and a radio that is merely struggling must keep retrying.
    public static let encryptionFailureLimit = 3
    /// An ATT authentication error on the version read is retried once. Twice means iOS holds no
    /// key the dongle will accept.
    public static let authRetryLimit = 1
    /// `maximumWriteValueLength` is not settled the instant a link comes up. Re-read and
    /// re-measure before calling it an error — the old app treated the first small number as
    /// fatal and gave up on a link that would have been fine a half-second later.
    public static let writeRemeasureDelay: TimeInterval = 0.5
    public static let writeRemeasureLimit = 3
    /// After this many failures, stop trusting the stored identifier and scan instead.
    public static let directAttemptLimit = 2

    // MARK: - State

    public private(set) var state: LinkState = .off(.unknown)
    public private(set) var log: LinkLog

    /// Whether anyone wants a link. Separate from the state, so leaving `needsForget` or
    /// `backoff` cannot silently disarm the app — the old app's "stale pairing" cleared the
    /// connection wish and left the session armed, and Start did nothing afterwards.
    public private(set) var isWanted = false
    public private(set) var centralState: CentralState = .unknown
    /// The dongle this phone has paired with before, if any.
    public private(set) var storedIdentifier: String?
    public private(set) var lastRSSI: Int?
    /// Subscriptions that came back with an error, by characteristic. The old app never looked
    /// at `didUpdateNotificationStateFor`'s error at all.
    public private(set) var subscriptionFailures: [CairnGATT.Characteristic: LinkFailure] = [:]
    /// When each notify channel was last heard from, for the screen's freshness badges.
    public private(set) var lastNotified: [CairnGATT.Characteristic: Date] = [:]
    /// Consecutive pairing failures, kept across reconnects within one episode.
    public private(set) var pairingFailures = 0
    /// Consecutive `CBErrorDomain#15` failures with no `ready` in between. See
    /// `encryptionFailureLimit` for why the count, rather than the code, is what means anything.
    public private(set) var encryptionFailures = 0
    public private(set) var attempt = 0

    private var authRetries = 0
    private var directAttempts = 0
    private var writeRemeasures = 0
    private var remeasureAt: Date?
    private var connectedAt: Date?
    private var discovered: Set<CairnGATT.Characteristic> = []

    public init(storedIdentifier: String? = nil, logCapacity: Int = LinkLog.defaultCapacity) {
        self.storedIdentifier = storedIdentifier
        self.log = LinkLog(capacity: logCapacity)
    }

    // MARK: - Reading it

    /// When the current state expires by itself. The adapter schedules one tick for exactly
    /// then; a test jumps straight to it.
    public var nextDeadline: Date? {
        let fromState: Date? = switch state {
        case .scanning(let deadline), .connecting(_, let deadline): deadline
        case .backoff(_, _, let until): until
        case .discovering(_, let since): since.addingTimeInterval(Self.discoveryDeadline)
        case .securing(_, let since): since.addingTimeInterval(Self.securingDeadline)
        default: nil
        }
        return [fromState, remeasureAt].compactMap { $0 }.min()
    }

    public var ready: LinkReady? { if case .ready(let r) = state { r } else { nil } }

    /// What to tell the owner when only they can fix it. Named because the bench matrix asks for
    /// a message that "names the fix", and because "pairing failed" has never helped anybody.
    public var advice: String? {
        switch state {
        case .needsForget(let failure):
            // Every way the bond can disagree earns the same instruction, because there is only
            // one fix and the app cannot apply it. `CB 14` used to fall through to
            // `failure.message`, which tells the owner what went wrong and nothing about what to
            // do. `CB 15` is not here on purpose — it is usually a bad link, not a bad bond.
            if failure.isAuthentication || failure == .pairingRefused
                || failure.isPeerRemovedPairing {
                return "Open Settings › Bluetooth, tap the ⓘ beside Cairn and choose "
                    + "\"Forget This Device\", then come back and tap Retry. The dongle no longer "
                    + "holds the key this phone is offering (\(failure.shortCode)), and an app "
                    + "cannot delete an iOS pairing."
            }
            return failure.message
        case .backoff(_, let reason, _) where reason == .notFound:
            // A dongle this phone has already been ready with has gone quiet, and by far the
            // likeliest reason is that it took its radio off BLE to upload over Wi-Fi: the
            // firmware tears the whole BLE stack down for a slot and does not advertise at all
            // until it comes back, for up to four minutes (CAIRN_UPLINK_SLOT_MAX_MS). Nothing is
            // wrong and nothing is asked of the owner, so say so first.
            //
            // The signal advice used to come first whenever an RSSI was known, which is always
            // true straight after a ready link — so the one case where the dongle is certainly
            // fine was the one case that got told to re-cable the car.
            if storedIdentifier != nil {
                var advice = "No answer yet. The dongle stops advertising while it uploads over "
                    + "Wi-Fi — up to about 4 minutes — and this clears up by itself; nothing to do."
                if let lastRSSI, lastRSSI <= Self.weakRSSI {
                    advice += " It was also last heard at only \(lastRSSI) dBm, so if this keeps "
                        + "happening the OBD extension cable is the fix for a dongle buried "
                        + "under the dash."
                }
                return advice
            }
            if let lastRSSI {
                return "The dongle was last heard at \(lastRSSI) dBm. Below about −70 dBm it "
                    + "stops answering; the OBD extension cable is the fix for a dongle buried "
                    + "under the dash."
            }
            return "No Cairn dongle answered. It advertises only when it is powered: check the "
                + "car's ignition, or that the dongle is not in a Wi-Fi slot."
        // "Failed to encrypt the connection" sounds like a key problem and is usually a radio
        // one: the pairing handshake needs a link that stays up long enough to finish it. On
        // 2026-11-05 the dongle logged a successful pair on every attempt the phone reported this
        // on. So name the likely cause, and the one that would be true if it persists.
        case .backoff(_, let reason, _) where reason.isEncryptionFailure:
            // Past the limit, nothing has ever succeeded, so the bond is the explanation and the
            // owner is the only one who can act. Still retrying underneath, in case it is not.
            if encryptionFailures >= Self.encryptionFailureLimit {
                return "Open Settings › Bluetooth, tap the ⓘ beside Cairn and choose \"Forget "
                    + "This Device\", then come back and tap Retry. The dongle has pairing keys "
                    + "this phone does not match (\(reason.shortCode)) after "
                    + "\(encryptionFailures) tries, and an app cannot delete an iOS pairing. "
                    + "It is still retrying in case this is only a weak signal."
            }
            var advice = "The dongle answered but the link did not survive long enough to finish "
                + "securing it. That is usually signal rather than pairing"
            if let lastRSSI { advice += ", and it was last heard at \(lastRSSI) dBm" }
            advice += ". Retrying by itself (\(reason.shortCode))."
            return advice
        case .backoff(_, let reason, _):
            return reason.message
        default:
            return nil
        }
    }

    // MARK: - Driving it

    /// Handle one event and return what the adapter should do.
    ///
    /// Every branch below either changes the state or says in the log why it did not. There is
    /// no path on which a failure is swallowed.
    @discardableResult
    public mutating func handle(_ event: LinkEvent, now: Date) -> [LinkEffect] {
        if event.isWorthLogging {
            log.append(at: now, state: state.name, detail: event.logDetail, kind: .event)
        }
        let before = state
        let effects = apply(event, now: now)
        if before != state {
            log.append(at: now, state: state.name, detail: "→ \(state.name)" + describeTransition(now: now), kind: .transition)
            if let failure = state.failure {
                log.append(at: now, state: state.name, detail: "\(failure)", kind: .failure)
            }
        }
        for effect in effects {
            if let detail = effect.logDetail {
                log.append(at: now, state: state.name, detail: detail, kind: .effect)
            }
        }
        return effects
    }

    /// A line from outside: the receiver timeline, or anything else a bench record wants beside
    /// the link's own transitions. It cannot change the state, only the record of it.
    public mutating func note(_ detail: String, at now: Date) {
        log.append(at: now, state: state.name, detail: detail, kind: .event)
    }

    private func describeTransition(now: Date) -> String {
        switch state {
        case .ready(let r):
            " · \(r.version.shortDescription), \(r.writeLength) B writes"
                + (lastRSSI.map { ", \($0) dBm" } ?? "")
        case .backoff(let attempt, _, let until):
            // `now`, not `Date()`: the machine reads no clock of its own, so a log line written
            // under a test clock says what the test clock said.
            " · attempt \(attempt), \(String(format: "%.0f", until.timeIntervalSince(now).rounded())) s"
        case .securing:
            " · reading PROTOCOL_VERSION; iOS pairs here"
        default: ""
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func apply(_ event: LinkEvent, now: Date) -> [LinkEffect] {
        switch event {
        case .startRequested:
            isWanted = true
            resetEpisode()
            return resume(now: now)

        case .stopRequested:
            isWanted = false
            var effects: [LinkEffect] = [.stopScan]
            if let peripheral = state.peripheral { effects.append(.cancelConnection(peripheral)) }
            clearConnection()
            state = .idle
            return effects

        case .retryRequested:
            // This is what makes `needsForget` a state you can leave. The old app's equivalent
            // was terminal and the Start control did nothing afterwards.
            isWanted = true
            resetEpisode()
            var effects: [LinkEffect] = []
            if let peripheral = state.peripheral { effects.append(.cancelConnection(peripheral)) }
            clearConnection()
            return effects + resume(now: now)

        case .forgetRequested:
            storedIdentifier = nil
            isWanted = true
            resetEpisode()
            var effects: [LinkEffect] = [.forgetIdentifier]
            if let peripheral = state.peripheral { effects.append(.cancelConnection(peripheral)) }
            clearConnection()
            return effects + resume(now: now)

        case .centralStateChanged(let new):
            centralState = new
            if let reason = new.offReason {
                clearConnection()
                state = .off(reason)
                return []
            }
            // The radio came back. Only pick the link up again if someone still wants it.
            if case .off = state { return resume(now: now) }
            return []

        case .restored(let peripheral, let connected):
            // iOS relaunches the app only for a connection it was holding, so it was wanted.
            isWanted = true
            if connected {
                // Nothing to connect: the link is already up. Straight to discovery.
                connectedAt = now
                state = .discovering(peripheral, since: now)
                return [.discoverServices(service: CairnGATT.serviceUUID)]
            }
            return connect(to: peripheral, now: now)

        case .discovered(let peripheral, let rssi):
            lastRSSI = rssi
            guard case .scanning = state else { return [] }
            return [.stopScan] + connect(to: peripheral, now: now)

        case .connected(let peripheral):
            guard state.peripheral == peripheral else { return [] }
            connectedAt = now
            state = .discovering(peripheral, since: now)
            return [.discoverServices(service: CairnGATT.serviceUUID)]

        case .failedToConnect(let peripheral, let failure):
            guard state.peripheral == peripheral else { return [] }
            directAttempts += 1
            let failure = failure ?? LinkFailure(domain: LinkFailure.cbDomain,
                                                 code: LinkFailure.CB.connectionFailed.rawValue,
                                                 message: "the connection failed")
            // `CBErrorDomain#14` is iOS saying the peer no longer recognises this phone's keys.
            // That is unambiguous and only the owner can fix it, so count it: three of them reach
            // `needsForget` and name the fix, rather than backing off forever.
            //
            // `#15` is deliberately **not** counted, and that is the whole lesson of 2026-11-05.
            // It reads like a bond failure — "failed to encrypt the connection" — and it is not:
            // the dongle's own log showed `paired: encrypted=1 bonded=1` on every single attempt
            // through the same window the phone was logging `#15`. The bond was fine; the
            // *encryption procedure was timing out* on a link that could not hold a connection
            // for more than a few seconds. Escalating it would have sent the owner to Settings to
            // delete a perfectly good pairing, and the next attempt would have failed the same
            // way. A stale bond already has paths that do catch it: the firmware's own "pairing
            // failed, disconnecting" arrives as a disconnect inside `securing`, and a refused
            // read arrives as `ATT 5`.
            if failure.isPeerRemovedPairing {
                return pairingFailed(failure, now: now)
            }
            if failure.isEncryptionFailure { encryptionFailures += 1 }
            return backoff(failure, now: now)

        case .disconnected(let peripheral, let failure, let isReconnecting):
            return disconnected(peripheral, failure, isReconnecting: isReconnecting, now: now)

        case .servicesDiscovered(let uuids, let failure):
            guard case .discovering(let peripheral, _) = state else { return [] }
            if let failure { return backoff(failure, now: now) }
            guard uuids.contains(where: { $0.caseInsensitiveCompare(CairnGATT.serviceUUID) == .orderedSame }) else {
                return backoff(.serviceNotFound, now: now)
            }
            _ = peripheral
            // A nil filter, always. The old app passed a list, that list omitted 0030 and 0031,
            // and so the offload capability was never detected and the controller exited before
            // its first LIST.
            return [.discoverCharacteristics(service: CairnGATT.serviceUUID)]

        case .characteristicsDiscovered(let found, let failure):
            guard case .discovering(let peripheral, _) = state else { return [] }
            if let failure { return backoff(failure, now: now) }
            discovered = Set(found)
            let missing = CairnGATT.requiredCharacteristics.subtracting(discovered)
            guard missing.isEmpty else {
                return backoff(.missingCharacteristics(missing.map(\.title).sorted()), now: now)
            }
            state = .securing(peripheral, since: now)
            return [.read(.protocolVersion)]

        case .valueRead(let characteristic, let data, let failure):
            return valueRead(characteristic, data, failure, now: now)

        case .notificationStateChanged(let characteristic, let enabled, let failure):
            guard let failure else {
                subscriptionFailures[characteristic] = nil
                if enabled { lastNotified[characteristic] = nil }
                return []
            }
            subscriptionFailures[characteristic] = failure
            // An authentication error on a subscribe is the same news as one on the read: iOS
            // and the dongle disagree about the key.
            if failure.isAuthentication, case .securing = state {
                return escalateAuthentication(failure, retry: [.setNotify(characteristic, true)], now: now)
            }
            return []

        case .notified(let characteristic, _):
            lastNotified[characteristic] = now
            return []

        case .writeLengthMeasured(let length):
            return writeLengthMeasured(length, now: now)

        case .rssiRead(let rssi):
            lastRSSI = rssi
            return []

        case .tick:
            return tick(now: now)
        }
    }

    // MARK: - The harder branches

    private mutating func disconnected(
        _ peripheral: PeripheralRef, _ failure: LinkFailure?, isReconnecting: Bool, now: Date
    ) -> [LinkEffect] {
        guard state.peripheral == peripheral else { return [] }

        // iOS reporting that the peer has dropped our keys is the bond disagreeing, whatever
        // state it arrives in — on hardware it lands in `discovering` as often as in `securing`,
        // because iOS encrypts a bonded link before handing over the service list rather than at
        // the version read. Counted wherever it lands, or a stale bond is an endless backoff that
        // never names the fix. An encryption *timeout* is not included; see `failedToConnect`.
        if let failure, failure.isPeerRemovedPairing {
            return pairingFailed(failure, now: now)
        }
        if let failure, failure.isEncryptionFailure { encryptionFailures += 1 }

        // A disconnect while securing, soon after connecting, is a pairing failure. This is how
        // the dongle's own "pairing failed, disconnecting" arrives at a central: the firmware
        // logs it, may drop its bond, and then terminates the link itself, which reaches iOS as
        // an ordinary disconnect with no ATT error anywhere.
        if case .securing = state, let connectedAt,
           now.timeIntervalSince(connectedAt) <= Self.pairingFailureWindow {
            return pairingFailed(failure ?? .pairingRefused, now: now)
        }

        if case .ready = state {
            clearConnection()
            if isReconnecting {
                // The system is already bringing it back; do not race it with a connect of our
                // own. Auto-reconnect is on for exactly this.
                state = .connecting(peripheral, deadline: now.addingTimeInterval(Self.connectDeadline))
                return []
            }
            // A link that was up and went away is the first failure of a new episode, and the
            // dongle starts advertising again the moment it disconnects. Waiting a second here
            // would be a second of a drive nobody recorded.
            attempt = 0
            return connect(to: peripheral, now: now)
        }

        clearConnection()
        return backoff(failure ?? LinkFailure(domain: LinkFailure.cbDomain,
                                              code: LinkFailure.CB.peripheralDisconnected.rawValue,
                                              message: "the dongle disconnected"), now: now)
    }

    private mutating func valueRead(
        _ characteristic: CairnGATT.Characteristic, _ data: Data?, _ failure: LinkFailure?, now: Date
    ) -> [LinkEffect] {
        switch characteristic {
        case .protocolVersion:
            if case .ready(var r) = state {
                // A re-read while ready is part of the write-length retry, not a pairing step.
                if let data, let version = PayloadDecoder.protocolVersion(data) {
                    r = LinkReady(peripheral: r.peripheral, version: version, present: r.present,
                                  writeLength: r.writeLength, deviceInfo: r.deviceInfo, readyAt: r.readyAt)
                    state = .ready(r)
                }
                return []
            }
            guard case .securing(let peripheral, _) = state else { return [] }
            if let failure {
                guard failure.isAuthentication else { return backoff(failure, now: now) }
                return escalateAuthentication(failure, retry: [.read(.protocolVersion)], now: now)
            }
            guard let data, let version = PayloadDecoder.protocolVersion(data) else {
                return backoff(.badVersionPayload, now: now)
            }
            guard version.isSupported else {
                return backoff(.unsupportedVersion(version.version), now: now)
            }
            return becomeReady(peripheral, version, now: now)

        case .deviceInfo:
            guard case .ready(var r) = state else { return [] }
            // DEVICE_INFO is a nice-to-have: it names the firmware and its engine profiles. A
            // dongle that refuses it still primes and still offloads, so a failure here is a
            // log line and nothing more.
            guard failure == nil, let data, let info = try? parseDeviceInfo(data) else { return [] }
            r.deviceInfo = info
            state = .ready(r)
            return []

        default:
            return []
        }
    }

    /// The owner declined the dialog, or iOS has no key the dongle will accept. Retry the read
    /// once — iOS sometimes reports this while the pairing it just started is still settling —
    /// and then stop, with the exact code, because only the owner can clear an iOS bond.
    private mutating func escalateAuthentication(
        _ failure: LinkFailure, retry: [LinkEffect], now: Date
    ) -> [LinkEffect] {
        authRetries += 1
        guard authRetries > Self.authRetryLimit else { return retry }
        return needsForget(failure, now: now)
    }

    private mutating func pairingFailed(_ failure: LinkFailure, now: Date) -> [LinkEffect] {
        pairingFailures += 1
        clearConnection()
        guard pairingFailures < Self.pairingFailureLimit else {
            return needsForget(failure, now: now)
        }
        // Under the limit this is worth another go without troubling anybody: the firmware drops
        // its own half of the bond on PINKEY_MISSING, AUTH_FAIL and the encryption errors, so the
        // very next attempt may be a clean pairing. That is the "phone forgot the dongle" case.
        return backoff(failure, now: now)
    }

    private mutating func needsForget(_ failure: LinkFailure, now: Date) -> [LinkEffect] {
        var effects: [LinkEffect] = []
        if let peripheral = state.peripheral { effects.append(.cancelConnection(peripheral)) }
        clearConnection()
        state = .needsForget(failure)
        // Deliberately not `forgetIdentifier`: the identifier is still right, it is the *bond*
        // that is wrong, and that one is in iOS Settings where only the owner can reach it.
        return effects + [.askToForgetInSettings(failure)]
    }

    private mutating func becomeReady(
        _ peripheral: PeripheralRef, _ version: ProtocolVersion, now: Date
    ) -> [LinkEffect] {
        let wasFirstReady = storedIdentifier != peripheral.id
        attempt = 0
        pairingFailures = 0
        // Reaching ready means the bond encrypted, so no run of encryption failures before this
        // was the bond's fault. This reset is what makes the count mean "never succeeded".
        encryptionFailures = 0
        authRetries = 0
        directAttempts = 0
        writeRemeasures = 0
        remeasureAt = nil
        subscriptionFailures = [:]

        state = .ready(LinkReady(
            peripheral: peripheral, version: version, present: discovered,
            writeLength: 0, readyAt: now
        ))

        var effects: [LinkEffect] = [.measureWriteLength, .readRSSI]
        if wasFirstReady {
            // Only now. The old app wrote this in `didConnect`, before bonding had succeeded,
            // and from then on only ever connected to it.
            storedIdentifier = peripheral.id
            effects.append(.persistIdentifier(peripheral.id))
        }
        // Subscribe to whatever this firmware actually exposes. Nothing is required: the shipping
        // firmware exposes neither OBD_LIVE nor DEVICE_STATUS, and the old app gated its whole
        // background location session on notifications from them, which is why it never streamed.
        for characteristic in [CairnGATT.Characteristic.gnssQuality, .companionStatus, .obdLive, .deviceStatus]
        where discovered.contains(characteristic) {
            effects.append(.setNotify(characteristic, true))
        }
        if version.hasBundleOffload {
            for characteristic in [CairnGATT.Characteristic.offloadControl, .offloadData]
            where discovered.contains(characteristic) {
                effects.append(.setNotify(characteristic, true))
            }
        }
        if version.hasDeviceInformation, discovered.contains(.deviceInfo) {
            effects.append(.read(.deviceInfo))
        }
        return effects
    }

    private mutating func writeLengthMeasured(_ length: Int, now: Date) -> [LinkEffect] {
        guard case .ready(var r) = state else { return [] }
        if length >= CairnGATT.requiredWriteLength {
            r = LinkReady(peripheral: r.peripheral, version: r.version, present: r.present,
                          writeLength: length, deviceInfo: r.deviceInfo, readyAt: r.readyAt)
            state = .ready(r)
            writeRemeasures = 0
            remeasureAt = nil
            return []
        }
        writeRemeasures += 1
        guard writeRemeasures <= Self.writeRemeasureLimit else {
            clearConnection()
            return backoff(.writeTooSmall(length), now: now)
        }
        log.append(at: now, state: state.name,
                   detail: "write length \(length) B is under 28; re-measuring in 500 ms "
                         + "(\(writeRemeasures) of \(Self.writeRemeasureLimit))",
                   kind: .effect)
        remeasureAt = now.addingTimeInterval(Self.writeRemeasureDelay)
        return []
    }

    private mutating func tick(now: Date) -> [LinkEffect] {
        var effects: [LinkEffect] = []
        if let remeasureAt, now >= remeasureAt {
            self.remeasureAt = nil
            effects += [.read(.protocolVersion), .measureWriteLength]
        }
        switch state {
        case .scanning(let deadline) where now >= deadline:
            return effects + [.stopScan] + backoff(.notFound, now: now)

        case .connecting(let peripheral, let deadline) where now >= deadline:
            // Back to scanning, as the plan says: a saved identifier that will not connect is
            // not a reason to stop looking for the dongle that is actually there.
            directAttempts += 1
            clearConnection()
            log.append(at: now, state: state.name, detail: "\(LinkFailure.connectTimedOut)", kind: .failure)
            return effects + [.cancelConnection(peripheral)] + beginScanning(now: now)

        case .discovering(_, let since) where now.timeIntervalSince(since) >= Self.discoveryDeadline:
            return effects + backoff(.cairn(9, "service discovery did not answer in \(Int(Self.discoveryDeadline)) s"), now: now)

        case .securing(_, let since) where now.timeIntervalSince(since) >= Self.securingDeadline:
            return effects + pairingFailed(
                .cairn(10, "pairing did not finish in \(Int(Self.securingDeadline)) s"), now: now
            )

        case .backoff(_, _, let until) where now >= until:
            return effects + resume(now: now)

        default:
            return effects
        }
    }

    // MARK: - Moves

    private mutating func resume(now: Date) -> [LinkEffect] {
        guard isWanted else {
            state = .idle
            return []
        }
        if let reason = centralState.offReason {
            state = .off(reason)
            return []
        }
        // A stored identifier is a shortcut, not a commitment. Two failures and it goes back to
        // scanning — the old app had no such fallback, so one bad save stranded it for good.
        if let storedIdentifier, directAttempts < Self.directAttemptLimit {
            return connect(to: PeripheralRef(id: storedIdentifier, name: CairnGATT.advertisedName), now: now)
        }
        return beginScanning(now: now)
    }

    private mutating func beginScanning(now: Date) -> [LinkEffect] {
        state = .scanning(deadline: now.addingTimeInterval(Self.scanWindow))
        return [.scan(service: CairnGATT.serviceUUID)]
    }

    private mutating func connect(to peripheral: PeripheralRef, now: Date) -> [LinkEffect] {
        state = .connecting(peripheral, deadline: now.addingTimeInterval(Self.connectDeadline))
        return [.connect(peripheral)]
    }

    private mutating func backoff(_ reason: LinkFailure, now: Date) -> [LinkEffect] {
        clearConnection()
        guard isWanted else {
            state = .idle
            return []
        }
        attempt += 1
        let delay = LinkBackoff.delay(attempt: attempt)
        state = .backoff(attempt: attempt, reason: reason, until: now.addingTimeInterval(delay))
        return []
    }

    /// Everything that belongs to one connection, and nothing that belongs to the episode.
    private mutating func clearConnection() {
        discovered = []
        connectedAt = nil
        remeasureAt = nil
        writeRemeasures = 0
    }

    /// A fresh intent from the owner: forget how badly the last few minutes went.
    private mutating func resetEpisode() {
        attempt = 0
        pairingFailures = 0
        encryptionFailures = 0
        authRetries = 0
        directAttempts = 0
        subscriptionFailures = [:]
        lastNotified = [:]
    }
}
