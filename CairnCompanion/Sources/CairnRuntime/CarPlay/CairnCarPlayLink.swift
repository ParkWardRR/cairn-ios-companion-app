#if os(iOS)
import CairnCore
import Foundation

/// Where the app's object graph and the CarPlay scene meet.
///
/// CarPlay can cold-launch Cairn before the phone's own UI has ever appeared, and UIKit builds the
/// CarPlay scene delegate from a class name in `Info.plist` — so that delegate has no way to reach the
/// session the app's entry point wired up. This is the one place they are introduced.
///
/// It hands over *readings only*. Showing or closing the car screen must never change what is being
/// recorded, so the CarPlay side is given `SessionState` and never `DrivingSession`: there is no method
/// here it could call to arm, disarm, or stop the logger.
@MainActor
public final class CairnCarPlayLink {
    public static let shared = CairnCarPlayLink()
    private init() {}

    public private(set) var state: SessionState?
    private var deviceInfo: () -> DeviceInfo? = { nil }

    /// Called once during launch, before any scene connects.
    public func attach(state: SessionState, deviceInfo: @escaping () -> DeviceInfo?) {
        self.state = state
        self.deviceInfo = deviceInfo
    }

    func currentDeviceInfo() -> DeviceInfo? { deviceInfo() }

    /// Units follow the phone's locale. The rule itself lives in `HUDUnits.forLocale`, so the
    /// Drive tab reads the same as the HUD.
    public static var units: HUDUnits { .forLocale(.current) }
}

// MARK: - SessionState to HUDInput

extension HUDInput {
    /// A flat copy of the live session, taken on the main actor. `stage` and `linkDetail` are reused
    /// verbatim from `SessionState` so the car and the phone never word the same situation differently.
    @MainActor
    init(state: SessionState, deviceInfo: DeviceInfo?, units: HUDUnits, gaugeSlots: Int, now: Date) {
        let link: HUDLink
        switch state.connection {
        case .idle: link = state.isArmed ? .waiting : .off
        case .bluetoothUnavailable: link = .unavailable
        case .scanning, .connecting, .bonding: link = .waiting
        case .ready: link = .ready
        case .failed: link = .failed
        }

        self.init(
            link: state.isArmed ? link : .off,
            stage: state.stage,
            linkDetail: state.linkDetail(now: now),
            isStreaming: state.isStreaming,
            connectedSince: state.connectedSince,
            dropCount: state.linkLog.dropCount,
            lastDrop: state.linkLog.lastDrop,
            obd: state.obdLive,
            lastOBDAt: state.lastOBDAt,
            deviceStatus: state.deviceStatus,
            lastDeviceStatusAt: state.lastDeviceStatusAt,
            companionStatus: state.companionStatus,
            lastStatusAt: state.lastStatusAt,
            quality: state.deviceQuality,
            lastQualityAt: state.lastQualityAt,
            phoneFix: state.phoneFix,
            locationMessage: state.locationMessage,
            sentCount: state.sentCount,
            droppedCount: state.droppedCount,
            deviceInfo: deviceInfo,
            units: units,
            gaugeSlots: gaugeSlots
        )
    }
}
#endif
