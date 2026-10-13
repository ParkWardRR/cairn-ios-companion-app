import CairnCore
import CoreLocation
import Foundation

/// Follows the Cairn dongle. While auto-connect is on, the app keeps a pending BLE connection to the
/// paired dongle; location streaming starts when the link is bonded and stops when it drops. It keeps
/// location and BLE alive with the screen locked, throttles to ~1 Hz, encodes, and hands fixes to the BLE manager.
@MainActor
public final class DrivingSession {
    public let state: SessionState
    private let ble: CairnBLEManager
    public let recorder: DriveRecorder
    public let power: PowerStateMonitor
    private let authorization: CLLocationManager = {
        let mgr = CLLocationManager()
        #if os(iOS)
        mgr.allowsBackgroundLocationUpdates = true
        mgr.pausesLocationUpdatesAutomatically = false
        mgr.showsBackgroundLocationIndicator = true
        #endif
        return mgr
    }()

    private static let autoConnectKey = "cairn.autoConnectEnabled"

    #if os(iOS)
    private var backgroundSession: CLBackgroundActivitySession?
    #endif
    private var locationTask: Task<Void, Never>?
    private var utcTask: Task<Void, Never>?
    private var baroTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var drivingStartedAt: Date?
    private var loggedFirstFix = false
    private static let summaryInterval: Duration = .seconds(30)
    private static let utcSyncInterval: Duration = .seconds(60)
    private var throttle = TransmitThrottle()
    private var seq: UInt16 = 0

    /// The dongle link became usable / went away. The bundle offload hangs off these.
    public var onDongleReady: (() -> Void)?
    public var onDongleLost: (() -> Void)?

    public init(state: SessionState, ble: CairnBLEManager, recorder: DriveRecorder, power: PowerStateMonitor) {
        self.state = state
        self.ble = ble
        self.recorder = recorder
        self.power = power
        ble.onReady = { [weak self] in
            self?.beginDriving()
            self?.onDongleReady?()
        }
        ble.onLinkLost = { [weak self] in
            self?.endDriving()
            self?.onDongleLost?()
        }
        ble.onStatus = { [weak self] status in self?.recorder.recordStatus(status) }
        ble.onStreamingChanged = { [weak self] streaming in self?.recorder.recordStreamingChange(isStreaming: streaming) }
        ble.onOBDReceived = { [weak self] in
            self?.recorder.noteOBDReceived()
            self?.activateBackgroundSessionIfNeeded()
        }
        ble.onDeviceStatus = { [weak self] status in
            if status.tripPhase == .driving {
                self?.recorder.noteDeviceDriving()
                self?.activateBackgroundSessionIfNeeded()
            } else if status.tripPhase == .idle {
                self?.deactivateBackgroundSession()
            }
        }
    }

    /// Call at launch, including background relaunches. Auto-connect is on unless the user turned it off.
    public func resumeIfEnabled() {
        let enabled = UserDefaults.standard.object(forKey: Self.autoConnectKey) as? Bool ?? true
        log("launch autoConnect \(enabled) location \(Self.describe(authorization.authorizationStatus))")
        if enabled { arm() }
    }

    /// Start waiting for the dongle. Location is not used until the link is up.
    public func arm() {
        guard !state.isArmed else { return }
        UserDefaults.standard.set(true, forKey: Self.autoConnectKey)
        state.resetAll()
        state.isArmed = true
        state.record(.armed)
        seq = 0
        recorder.reconcileOnLaunch(bleRestored: false)

        log("arm location \(Self.describe(authorization.authorizationStatus))")
        // A link that comes up while the app is in the background has to start location there, which
        // needs Always authorization. While In Use is enough only when the app is foregrounded.
        switch authorization.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse: authorization.requestAlwaysAuthorization()
        default: break
        }
        ble.start()
    }

    /// Clear the stored dongle and guide the user to remove the bond in iOS Settings.
    public func forgetDongle() {
        disarm()
        ble.forgetDongle()
    }

    /// Stop following the dongle and release BLE and location.
    public func disarm() {
        log("disarm")
        UserDefaults.standard.set(false, forKey: Self.autoConnectKey)
        endDriving()
        recorder.disarmed()
        ble.stop()
        state.resetAll()
        state.isArmed = false
    }

    private func beginDriving() {
        guard state.isArmed, !state.isDriving else { return }
        state.isDriving = true
        drivingStartedAt = Date()
        loggedFirstFix = false
        log("driving begin location \(Self.describe(authorization.authorizationStatus))")
        state.sentCount = 0
        state.droppedCount = 0
        throttle.reset()
        recorder.linkReady(deviceID: nil)
        recorder.newCounterEpoch()
        locationTask = Task { [weak self] in
            for await event in LocationStream.events() {
                self?.handle(event)
            }
        }
        startEnrichment()
        summaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.summaryInterval)
                self?.logSummary()
                self?.recorder.checkpoint()
            }
        }
    }

    /// Phase 2 writes, sent only if the dongle exposes the characteristic.
    private func startEnrichment() {
        if ble.supportsUTCSync {
            utcTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.ble.send(UTCSyncPayload(date: Date()))
                    try? await Task.sleep(for: Self.utcSyncInterval)
                }
            }
        }
        if ble.supportsBaroAlt, BaroStream.isAvailable {
            baroTask = Task { [weak self] in
                for await reading in BaroStream.readings() {
                    self?.ble.send(reading)
                }
            }
        }
    }

    private func endDriving() {
        guard state.isDriving else { return }
        recorder.linkLost(reason: nil)
        locationTask?.cancel()
        locationTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        logSummary(prefix: "driving end")
        utcTask?.cancel()
        utcTask = nil
        baroTask?.cancel()
        baroTask = nil
        #if os(iOS)
        backgroundSession?.invalidate()
        backgroundSession = nil
        #endif
        state.isDriving = false
        state.phoneFix = nil
        state.locationMessage = nil
    }

    private func activateBackgroundSessionIfNeeded() {
        #if os(iOS)
        guard backgroundSession == nil, state.isDriving else { return }
        backgroundSession = CLBackgroundActivitySession()
        log("background session activated — device reports driving")
        #endif
    }

    private func deactivateBackgroundSession() {
        #if os(iOS)
        guard backgroundSession != nil else { return }
        backgroundSession?.invalidate()
        backgroundSession = nil
        log("background session deactivated — device reports idle")
        #endif
    }

    private func handle(_ event: LocationEvent) {
        switch event {
        case .unavailable(let message):
            if state.locationMessage != message { log("location unavailable: \(message)") }
            state.locationMessage = message
        case .fix(let fix):
            if !loggedFirstFix {
                loggedFirstFix = true
                let wait = drivingStartedAt.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
                log("first fix \(wait) s after link ready, hAcc \(fix.horizontalAccuracy) m")
            }
            state.locationMessage = nil
            state.phoneFix = fix
            recorder.recordFix(fix)
            transmit(fix)
        }
    }

    /// Persisted event for post-drive review (Files app > Cairn > cairn-drive.log).
    public func log(_ message: String) {
        DriveLog.shared.record("app \(message)")
    }

    private func logSummary(prefix: String = "summary") {
        let device = state.companionStatus.map {
            "device accepted \($0.acceptedCount) rejected \($0.rejectedCount) queueDrop \($0.queueDropCount)"
        } ?? "device status none"
        let fix = state.phoneFix.map {
            String(format: "last hAcc %.0f m age %.1f s", $0.horizontalAccuracy, Date().timeIntervalSince($0.timestamp))
        } ?? "no fix"
        log("\(prefix) sent \(state.sentCount) dropped \(state.droppedCount) \(device) streaming \(state.isStreaming) \(fix)")
    }

    private static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "whenInUse"
        @unknown default: "unknown"
        }
    }

    private func refreshThrottleMode() {
        if power.isCharging {
            throttle.powerMode = .charger
        } else if let q = state.deviceQuality, q.fixType >= 2 {
            throttle.powerMode = .batterySaver
        } else {
            throttle.powerMode = .battery
        }
    }

    private func transmit(_ fix: PhoneGNSSFix) {
        refreshThrottleMode()
        guard throttle.shouldSend(fix) else { return }
        guard let payload = PayloadEncoder.encode(fix, now: Date(), seq: seq, isCharging: power.isCharging) else {
            state.droppedCount += 1
            return
        }
        switch ble.send(payload) {
        case .sent:
            seq &+= 1
            state.sentCount += 1
            state.lastSent = payload
            state.lastWriteAt = Date()
            recorder.recordSend()
        case .backpressure:
            state.droppedCount += 1
            recorder.recordWriteFailure()
        case .notReady:
            break // not connected yet; fixes are not queued
        }
    }
}
