import CairnKit
import CairnProtocol
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let dongle = PeripheralRef(id: "D0000001-0000-0000-0000-000000000001", name: "Cairn")
private let otherDongle = PeripheralRef(id: "D0000002-0000-0000-0000-000000000002", name: "Cairn")

/// Drives the machine by hand, one event at a time, so a rule can be checked without a central
/// in the way. Returns the effects of the last event.
@MainActor
private struct Driver {
    var machine: LinkMachine
    var now: Date = t0
    private(set) var effects: [LinkEffect] = []
    private(set) var allEffects: [LinkEffect] = []

    init(stored: String? = nil) {
        machine = LinkMachine(storedIdentifier: stored)
    }

    @discardableResult
    mutating func send(_ event: LinkEvent) -> [LinkEffect] {
        effects = machine.handle(event, now: now)
        allEffects += effects
        return effects
    }

    mutating func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    /// Jump to the current state's deadline and tick, which is what the supervisor's clock does.
    @discardableResult
    mutating func tickAtDeadline() -> [LinkEffect] {
        guard let deadline = machine.nextDeadline else { return [] }
        now = deadline
        return send(.tick)
    }

    /// Everything up to and including the version read landing, so a test about what happens
    /// afterwards does not have to spell out the whole walk.
    mutating func reachReady(
        version: ProtocolVersion = ProtocolVersion(version: 1, capabilities: [.bundleOffload]),
        characteristics: [CairnGATT.Characteristic] = Array(FakeCentral.Dongle.shippingCharacteristics),
        writeLength: Int? = 244
    ) {
        send(.centralStateChanged(.poweredOn))
        send(.startRequested)
        send(.discovered(dongle, rssi: -55))
        send(.connected(dongle))
        send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        send(.characteristicsDiscovered(characteristics, nil))
        send(.valueRead(.protocolVersion, version.data, nil))
        if let writeLength { send(.writeLengthMeasured(writeLength)) }
    }

    var state: LinkState { machine.state }
}

@MainActor
@Suite("LinkMachine: the rules the audit paid for")
struct LinkMachineTests {
    @Test("nothing happens until both the radio is up and somebody asked")
    func needsRadioAndIntent() {
        var driver = Driver()
        driver.send(.startRequested)
        #expect(driver.state == .off(.unknown), "no radio yet, so nothing to do")
        #expect(driver.effects.isEmpty)

        driver.send(.centralStateChanged(.poweredOn))
        #expect(driver.state.name == "scanning")

        var other = Driver()
        other.send(.centralStateChanged(.poweredOn))
        #expect(other.state == .idle, "a radio nobody asked to use stays idle")
        #expect(other.effects.isEmpty)
    }

    @Test("the radio going away is a state, and coming back resumes")
    func radioOffAndOn() {
        var driver = Driver()
        driver.reachReady()
        #expect(driver.state.isReady)

        driver.send(.centralStateChanged(.poweredOff))
        #expect(driver.state == .off(.poweredOff))
        #expect(LinkOffReason.poweredOff.isUserFixable)

        driver.send(.centralStateChanged(.poweredOn))
        #expect(driver.state.name == "connecting", "it still wants the link it had")
    }

    @Test("characteristics are discovered with no filter: that is what hid 0030 and 0031")
    func discoveryHasNoFilter() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        let effects = driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        // One effect, and it names a service, not a list of characteristics. The old app passed
        // ten UUIDs, that list omitted the two offload ones, and the offload capability was
        // therefore never detected on a dongle that had it.
        #expect(effects == [.discoverCharacteristics(service: CairnGATT.serviceUUID)])
    }

    @Test("a missing required characteristic backs off; a missing optional one does not")
    func requiredCharacteristics() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered([.gnssQuality, .companionStatus], nil))

        #expect(driver.state.name == "backoff")
        #expect(driver.state.failure?.message.contains("GNSS_FIX") == true)
        #expect(driver.state.failure?.message.contains("PROTOCOL_VERSION") == true)

        // The two that matter and nothing else is a link worth having.
        var lean = Driver()
        lean.reachReady(characteristics: [.gnssFix, .protocolVersion])
        #expect(lean.state.isReady)
        #expect(lean.machine.ready?.has(.utcSync) == false)
    }

    @Test("a feature needs its capability bit and its characteristic, both")
    func featureGating() {
        // The bit set, the characteristics missing: this is the shape of the offload bug.
        var claimsOffload = Driver()
        claimsOffload.reachReady(
            version: ProtocolVersion(version: 1, capabilities: [.bundleOffload]),
            characteristics: [.gnssFix, .protocolVersion]
        )
        #expect(claimsOffload.machine.ready?.canOffload == false)

        // The characteristics there, the bit clear: the firmware's own rule is that the bit is
        // set only when the offload task actually started, so believe the bit.
        var hasCharacteristics = Driver()
        hasCharacteristics.reachReady(
            version: ProtocolVersion(version: 1, capabilities: []),
            characteristics: [.gnssFix, .protocolVersion, .offloadControl, .offloadData]
        )
        #expect(hasCharacteristics.machine.ready?.canOffload == false)

        var both = Driver()
        both.reachReady()
        #expect(both.machine.ready?.canOffload == true)
    }

    @Test("it subscribes to what the firmware has, and to nothing it does not")
    func subscribesToWhatIsThere() {
        var driver = Driver()
        driver.reachReady(characteristics: [.gnssFix, .protocolVersion, .gnssQuality, .companionStatus])
        let subscribes = driver.allEffects.compactMap { effect -> CairnGATT.Characteristic? in
            if case .setNotify(let c, true) = effect { return c } else { return nil }
        }
        #expect(Set(subscribes) == [.gnssQuality, .companionStatus])
        // OBD_LIVE and DEVICE_STATUS do not exist on this firmware. The old app made its whole
        // background location session wait for a notification from one of them.
        #expect(!subscribes.contains(.obdLive))
        #expect(!subscribes.contains(.deviceStatus))
    }

    @Test("a subscription error is surfaced, not swallowed")
    func subscriptionErrorSurfaced() {
        var driver = Driver()
        driver.reachReady()
        let failure = LinkFailure(domain: LinkFailure.attDomain, code: 2, message: "Reading is not permitted.")
        driver.send(.notificationStateChanged(.gnssQuality, enabled: false, failure))

        #expect(driver.machine.subscriptionFailures[.gnssQuality] == failure)
        #expect(driver.state.isReady, "one dead notify channel is not a dead link")
        #expect(driver.machine.log.entries.contains { $0.detail.contains("subscribe GNSS_QUALITY failed") })
    }

    // MARK: - Pairing

    @Test("an ATT authentication error is retried once, then it is the owner's to fix")
    func authRetriedOnceThenAsks() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered(Array(FakeCentral.Dongle.shippingCharacteristics), nil))

        let failure = LinkFailure(domain: LinkFailure.attDomain,
                                  code: LinkFailure.ATT.insufficientAuthentication.rawValue,
                                  message: "Authentication is insufficient.")
        let first = driver.send(.valueRead(.protocolVersion, nil, failure))
        #expect(first == [.read(.protocolVersion)], "the first one is retried: iOS may still be settling")
        #expect(driver.state.name == "securing")

        let second = driver.send(.valueRead(.protocolVersion, nil, failure))
        #expect(driver.state == .needsForget(failure))
        #expect(second.contains(.askToForgetInSettings(failure)))
        // The code goes all the way to the screen, because "pairing failed" has never helped.
        #expect(driver.machine.advice?.contains("ATT 5") == true)
    }

    /// Measured on hardware on 2026-11-05 and the reason this test exists: the dongle was ready
    /// at −77 dBm, went off air for a Wi-Fi slot, and the phone spent four minutes reporting
    /// "no Cairn dongle answered the scan". The advice it offered was the signal one — re-cable
    /// the car — because an RSSI was known, which it always is straight after a ready link. The
    /// dongle was fine: the firmware tears its whole BLE stack down for a slot and advertises
    /// nothing for up to `CAIRN_UPLINK_SLOT_MAX_MS`, four minutes, and the released BLE contract
    /// has no field to say so. So the phone has to infer it, and the one thing it knows is that
    /// it has been ready with this dongle before.
    @Test("a dongle we have been ready with going quiet is a Wi-Fi slot, not a cabling job")
    func quietAfterReadyIsAWiFiSlot() {
        var driver = Driver()
        driver.reachReady()
        #expect(driver.state.name == "ready")

        // It goes off air mid-slot, and nothing answers the rescan.
        driver.send(.disconnected(dongle, nil, isReconnecting: false))
        while driver.state.name != "backoff", driver.machine.nextDeadline != nil {
            driver.tickAtDeadline()
        }
        #expect(driver.state.name == "backoff")

        let advice = driver.machine.advice
        #expect(advice?.contains("uploads over Wi-Fi") == true, "the likely reason comes first")
        #expect(advice?.contains("nothing to do") == true, "and it asks nothing of the owner")
        #expect(advice?.contains("extension cable") == false,
                "−55 dBm is a healthy link: re-cabling the car is not the advice")
    }

    @Test("a weak signal is still worth saying, after the Wi-Fi slot")
    func weakSignalIsStillMentioned() {
        var driver = Driver()
        driver.reachReady()
        driver.send(.discovered(dongle, rssi: -84))
        driver.send(.disconnected(dongle, nil, isReconnecting: false))
        while driver.state.name != "backoff", driver.machine.nextDeadline != nil {
            driver.tickAtDeadline()
        }

        let advice = driver.machine.advice
        #expect(advice?.contains("uploads over Wi-Fi") == true, "still the likeliest reason")
        #expect(advice?.contains("-84 dBm") == true, "but at −84 dBm the signal is worth saying too")
        #expect(advice?.contains("extension cable") == true)
    }

    /// A phone that has never been ready with this dongle cannot assume a Wi-Fi slot: it has no
    /// evidence the dongle exists at all, so the honest advice is the one about power.
    @Test("with no dongle ever remembered, the advice is about power, not Wi-Fi")
    func neverReadyAdviceIsAboutPower() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.tickAtDeadline()
        #expect(driver.state.name == "backoff")
        #expect(driver.machine.advice?.contains("powered") == true)
    }

    @Test("a disconnect while securing is a pairing failure, and three of them ask the owner")
    func disconnectWhileSecuringIsPairingFailure() {
        var driver = Driver()
        for expected in 1...3 {
            driver.send(.centralStateChanged(.poweredOn))
            driver.send(expected == 1 ? .startRequested : .tick)
            if driver.state.name == "backoff" { driver.tickAtDeadline() }
            if driver.state.name == "scanning" { driver.send(.discovered(dongle, rssi: -55)) }
            driver.send(.connected(dongle))
            driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
            driver.send(.characteristicsDiscovered(Array(FakeCentral.Dongle.shippingCharacteristics), nil))
            #expect(driver.state.name == "securing")

            // The firmware's own "pairing failed, disconnecting": no ATT error anywhere, just a
            // link that went away a moment after it came up.
            driver.advance(0.4)
            driver.send(.disconnected(dongle, nil, isReconnecting: false))
            #expect(driver.machine.pairingFailures == expected)
        }
        #expect(driver.state.name == "needsForget")
        #expect(driver.machine.advice?.contains("Forget This Device") == true)
    }

    @Test("a disconnect while securing, but long after connecting, is not a pairing failure")
    func lateDisconnectIsNotPairingFailure() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered(Array(FakeCentral.Dongle.shippingCharacteristics), nil))

        // Beyond the window, this is a car driving out of range mid-pair, not a refused key.
        driver.advance(LinkMachine.pairingFailureWindow + 1)
        driver.send(.disconnected(dongle, nil, isReconnecting: false))
        #expect(driver.machine.pairingFailures == 0)
        #expect(driver.state.name == "backoff")
    }

    @Test("pairing that never answers at all times out rather than hanging")
    func securingTimesOut() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered(Array(FakeCentral.Dongle.shippingCharacteristics), nil))
        #expect(driver.state.name == "securing")

        driver.tickAtDeadline()
        #expect(driver.machine.pairingFailures == 1)
        #expect(driver.state.name == "backoff")
    }

    @Test("needsForget is a state you can leave")
    func needsForgetIsNotTerminal() {
        var driver = Driver()
        let failure = LinkFailure(domain: LinkFailure.attDomain, code: 5, message: "Authentication is insufficient.")
        driver.reachReady()
        driver.send(.disconnected(dongle, nil, isReconnecting: false))
        // Force it there the short way.
        driver.machine = {
            var machine = LinkMachine(storedIdentifier: dongle.id)
            machine.handle(.centralStateChanged(.poweredOn), now: t0)
            machine.handle(.startRequested, now: t0)
            machine.handle(.connected(dongle), now: t0)
            machine.handle(.servicesDiscovered([CairnGATT.serviceUUID], nil), now: t0)
            machine.handle(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil), now: t0)
            machine.handle(.valueRead(.protocolVersion, nil, failure), now: t0)
            machine.handle(.valueRead(.protocolVersion, nil, failure), now: t0)
            return machine
        }()
        #expect(driver.state.name == "needsForget")

        let effects = driver.send(.retryRequested)
        #expect(driver.state.name != "needsForget")
        #expect(driver.machine.isWanted, "the old app's equivalent cleared the connection wish")
        #expect(effects.contains { if case .connect = $0 { true } else { false } }
                || effects.contains(.scan(service: CairnGATT.serviceUUID)))
    }

    @Test("Forget drops the stored identifier and starts over by scanning")
    func forgetStartsOver() {
        var driver = Driver(stored: dongle.id)
        driver.reachReady()
        let effects = driver.send(.forgetRequested)
        #expect(effects.contains(.forgetIdentifier))
        #expect(driver.machine.storedIdentifier == nil)
        #expect(driver.state.name == "scanning")
    }

    // MARK: - Deadlines and backoff

    @Test("a connect that does not complete in 15 s goes back to scanning")
    func connectDeadline() {
        var driver = Driver(stored: dongle.id)
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        #expect(driver.state.name == "connecting", "a stored dongle is a shortcut past the scan")

        driver.advance(LinkMachine.connectDeadline - 0.1)
        driver.send(.tick)
        #expect(driver.state.name == "connecting", "not yet")

        driver.advance(0.2)
        let effects = driver.send(.tick)
        #expect(driver.state.name == "scanning")
        #expect(effects.contains(.cancelConnection(dongle)))
        #expect(effects.contains(.scan(service: CairnGATT.serviceUUID)))
    }

    @Test("a stored identifier that fails twice stops being used")
    func storedIdentifierFallsBackToScanning() {
        var driver = Driver(stored: dongle.id)
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)

        for _ in 1...2 {
            #expect(driver.state.name == "connecting")
            driver.send(.failedToConnect(dongle, nil))
            #expect(driver.state.name == "backoff")
            driver.tickAtDeadline()
        }
        #expect(driver.state.name == "scanning", "two failures and the shortcut is not worth it")
        // And a dongle found by scanning may not be the one that was stored.
        driver.send(.discovered(otherDongle, rssi: -60))
        #expect(driver.state.peripheral == otherDongle)
    }

    @Test("the identifier is written on the first ready, and never before")
    func identifierPersistedOnReadyOnly() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        let onConnect = driver.send(.connected(dongle))
        // The old app wrote it here, before bonding had succeeded, and from then on only ever
        // connected to it, with no timeout and no fallback.
        #expect(!onConnect.contains(.persistIdentifier(dongle.id)))
        #expect(driver.machine.storedIdentifier == nil)

        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil))
        let onReady = driver.send(.valueRead(.protocolVersion, ProtocolVersion(version: 1, capabilities: []).data, nil))
        #expect(onReady.contains(.persistIdentifier(dongle.id)))
        #expect(driver.machine.storedIdentifier == dongle.id)
    }

    @Test("the backoff schedule doubles to a 15 s ceiling and the attempt count rises every time")
    func backoffSchedule() {
        #expect(LinkBackoff.delay(attempt: 1) == 1)
        #expect(LinkBackoff.delay(attempt: 2) == 2)
        #expect(LinkBackoff.delay(attempt: 3) == 4)
        #expect(LinkBackoff.delay(attempt: 4) == 8)
        #expect(LinkBackoff.delay(attempt: 5) == 15)
        #expect(LinkBackoff.delay(attempt: 1_000) == 15)

        // Every failing path raises it. The old policy raised it inside one retry helper only,
        // so a connect that failed outright left it at zero and the app retried at 1 s forever.
        var driver = Driver(stored: dongle.id)
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        for expected in 1...4 {
            driver.send(.failedToConnect(driver.state.peripheral ?? dongle, nil))
            #expect(driver.machine.attempt == expected, "attempt should be \(expected)")
            driver.tickAtDeadline()
            if driver.state.name == "scanning" { driver.tickAtDeadline() }
        }
    }

    @Test("a fresh start forgets how badly the last few minutes went")
    func startResetsTheEpisode() {
        var driver = Driver(stored: dongle.id)
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.failedToConnect(dongle, nil))
        driver.tickAtDeadline()
        driver.send(.failedToConnect(driver.state.peripheral ?? dongle, nil))
        #expect(driver.machine.attempt == 2)

        driver.send(.startRequested)
        #expect(driver.machine.attempt == 0)
        #expect(driver.machine.pairingFailures == 0)
    }

    @Test("Stop cancels the link and asks for nothing more")
    func stop() {
        var driver = Driver()
        driver.reachReady()
        let effects = driver.send(.stopRequested)
        #expect(driver.state == .idle)
        #expect(effects.contains(.cancelConnection(dongle)))
        #expect(!driver.machine.isWanted)

        // And a tick afterwards does nothing at all.
        driver.advance(60)
        #expect(driver.send(.tick).isEmpty)
        #expect(driver.state == .idle)
    }

    // MARK: - Write length

    @Test("a short write length is re-measured three times before it is an error")
    func writeLengthIsRetried() {
        var driver = Driver()
        driver.reachReady(writeLength: nil)
        #expect(driver.state.isReady)

        for attempt in 1...LinkMachine.writeRemeasureLimit {
            driver.send(.writeLengthMeasured(20))
            #expect(driver.state.isReady, "still ready on re-measure \(attempt)")
            let effects = driver.tickAtDeadline()
            #expect(effects.contains(.measureWriteLength))
            #expect(effects.contains(.read(.protocolVersion)))
        }

        driver.send(.writeLengthMeasured(20))
        #expect(driver.state.name == "backoff", "four short measurements is an error")
        #expect(driver.state.failure == .writeTooSmall(20))
    }

    @Test("a write length that settles above 28 on the second look is fine")
    func writeLengthSettles() {
        var driver = Driver()
        driver.reachReady(writeLength: nil)
        driver.send(.writeLengthMeasured(23))
        #expect(driver.state.isReady)
        driver.tickAtDeadline()
        driver.send(.writeLengthMeasured(244))
        #expect(driver.machine.ready?.writeLength == 244)
        // And the counter resets, so a later dip gets its own three looks.
        driver.send(.writeLengthMeasured(20))
        #expect(driver.state.isReady)
    }

    // MARK: - Versions

    @Test("an unsupported protocol version backs off and stays reachable")
    func unsupportedVersion() {
        var driver = Driver()
        driver.reachReady(version: ProtocolVersion(version: 7, capabilities: []), writeLength: nil)
        #expect(driver.state.name == "backoff")
        #expect(driver.state.failure == .unsupportedVersion(7))
        // Not terminal: flashing the dongle is the fix, and the app should pick it up by itself.
        #expect(driver.machine.isWanted)
    }

    @Test("a PROTOCOL_VERSION payload that is not two bytes backs off")
    func badVersionPayload() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil))
        driver.send(.valueRead(.protocolVersion, Data([1]), nil))
        #expect(driver.state.failure == .badVersionPayload)
    }

    @Test("a longer PROTOCOL_VERSION read is accepted and its tail ignored")
    func longerVersionPayloadIsFine() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil))
        driver.send(.valueRead(.protocolVersion, Data([1, 0x0C, 0xAB, 0xCD]), nil))
        driver.send(.writeLengthMeasured(244))
        #expect(driver.state.isReady, "a firmware that appends a field must not take the link down")
        #expect(driver.machine.ready?.version.hasBundleOffload == true)
    }

    @Test("DEVICE_INFO is a nice-to-have: refusing it does not break the link")
    func deviceInfoIsOptional() {
        var driver = Driver()
        driver.reachReady(version: ProtocolVersion(version: 1, capabilities: [.deviceInformation]))
        #expect(driver.allEffects.contains(.read(.deviceInfo)))
        driver.send(.valueRead(.deviceInfo, nil, .cairn(1, "refused")))
        #expect(driver.state.isReady)
        #expect(driver.machine.ready?.deviceInfo == nil)
    }

    @Test("DEVICE_INFO is not read when the capability bit is clear")
    func deviceInfoNeedsItsBit() {
        var driver = Driver()
        driver.reachReady(version: ProtocolVersion(version: 1, capabilities: []))
        #expect(!driver.allEffects.contains(.read(.deviceInfo)))
    }

    // MARK: - Drops

    @Test("a drop from ready reconnects at once rather than waiting out a backoff")
    func dropFromReadyReconnects() {
        var driver = Driver()
        driver.reachReady()
        let effects = driver.send(.disconnected(dongle, nil, isReconnecting: false))
        #expect(driver.state.name == "connecting")
        #expect(effects == [.connect(dongle)])
        #expect(driver.machine.attempt == 0, "a link that worked starts a fresh episode")
    }

    @Test("a drop iOS is already handling is not raced with a connect of our own")
    func reconnectingDropIsLeftAlone() {
        var driver = Driver()
        driver.reachReady()
        let effects = driver.send(.disconnected(dongle, nil, isReconnecting: true))
        #expect(driver.state.name == "connecting")
        #expect(effects.isEmpty, "auto-reconnect is on; the system is faster than a timer here")
    }

    @Test("a disconnect for a peripheral the machine has moved on from is ignored")
    func staleDisconnectIgnored() {
        var driver = Driver()
        driver.reachReady()
        driver.send(.stopRequested)
        #expect(driver.state == .idle)
        driver.send(.disconnected(dongle, nil, isReconnecting: false))
        #expect(driver.state == .idle, "the cancellation's own disconnect must not restart anything")
    }

    @Test("service discovery that never answers is a failure, not a state to live in")
    func discoveryTimesOut() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        #expect(driver.state.name == "discovering")
        driver.tickAtDeadline()
        #expect(driver.state.name == "backoff")
    }

    @Test("a dongle with no Cairn service backs off")
    func wrongService() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered(["0000180F-0000-1000-8000-00805F9B34FB"], nil))
        #expect(driver.state.failure == .serviceNotFound)
    }

    @Test("the service UUID is matched without regard to case")
    func serviceUUIDCaseInsensitive() {
        var driver = Driver()
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        let effects = driver.send(.servicesDiscovered([CairnGATT.serviceUUID.lowercased()], nil))
        #expect(effects == [.discoverCharacteristics(service: CairnGATT.serviceUUID)])
    }

    // MARK: - What the screen reads

    @Test("every state knows when it expires, so nothing is polled")
    func deadlinesAreKnown() {
        var driver = Driver(stored: dongle.id)
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        #expect(driver.machine.nextDeadline == t0.addingTimeInterval(LinkMachine.connectDeadline))

        driver.send(.connected(dongle))
        #expect(driver.machine.nextDeadline == t0.addingTimeInterval(LinkMachine.discoveryDeadline))

        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil))
        #expect(driver.machine.nextDeadline == t0.addingTimeInterval(LinkMachine.securingDeadline))

        driver.send(.valueRead(.protocolVersion, ProtocolVersion(version: 1, capabilities: []).data, nil))
        driver.send(.writeLengthMeasured(244))
        #expect(driver.machine.nextDeadline == nil, "a ready link waits for nothing")
    }

    @Test("notify traffic is remembered for the freshness badges but kept out of the log")
    func notifyTrafficIsNotLogged() {
        var driver = Driver()
        driver.reachReady()
        let linesBefore = driver.machine.log.entries.count
        for _ in 0..<50 {
            driver.advance(1)
            driver.send(.notified(.gnssQuality, Data(count: 8)))
        }
        #expect(driver.machine.log.entries.count == linesBefore, "50 notifies would bury the log")
        #expect(driver.machine.lastNotified[.gnssQuality] != nil)
        #expect(LinkHealth.freshness(lastHeard: driver.machine.lastNotified[.gnssQuality], now: driver.now) == .live)
    }

    @Test("the log carries the state a failure happened in, and the failure's own code")
    func logIsEvidence() {
        var driver = Driver()
        let failure = LinkFailure(domain: LinkFailure.attDomain, code: 5, message: "Authentication is insufficient.")
        driver.send(.centralStateChanged(.poweredOn))
        driver.send(.startRequested)
        driver.send(.discovered(dongle, rssi: -55))
        driver.send(.connected(dongle))
        driver.send(.servicesDiscovered([CairnGATT.serviceUUID], nil))
        driver.send(.characteristicsDiscovered([.gnssFix, .protocolVersion], nil))
        driver.send(.valueRead(.protocolVersion, nil, failure))
        driver.send(.valueRead(.protocolVersion, nil, failure))

        let text = driver.machine.log.export(header: ["a test"])
        #expect(text.contains("CBATTErrorDomain#5"))
        #expect(text.contains("securing"))
        #expect(text.contains("needsForget"))
        #expect(text.contains("# a test"))
        // The transitions alone are the shape of a bench row.
        let names = driver.machine.log.transitions.map(\.state)
        #expect(names.contains("securing"))
        #expect(names.last == "needsForget")
    }
}
