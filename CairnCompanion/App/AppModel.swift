import CairnKit
import CairnRuntime
import Foundation
import Observation

/// The one object the screens read.
///
/// Architecture rule 2: one `AppModel`, main-actor, observable, and no two objects writing the
/// same state. The old app had a `SessionState`, a `DrivingSession`, a `CairnBLEManager`, an
/// `OffloadController` and a `TripSyncClient` all mutating overlapping fields — which is how its
/// "stale pairing" state came to clear the connection wish while leaving the session armed, so
/// that the Start control did nothing afterwards and no single object could say why.
@MainActor
@Observable
final class AppModel {
    let build: BuildIdentity
    let link: LinkSupervisor
    /// The log on disk, so a link can be reviewed after a drive the phone spent locked in a
    /// mount. The ring in `LinkSupervisor` is what the screen shows; this is what survives a
    /// relaunch and what Export Log shares.
    let driveLog: DriveLog

    init(build: BuildIdentity, link: LinkSupervisor, driveLog: DriveLog) {
        self.build = build
        self.link = link
        self.driveLog = driveLog
    }

    /// The real app: a CoreBluetooth central, the system clock, and the dongle this phone
    /// already knows about if it knows one.
    static func live() -> AppModel {
        let driveLog = DriveLog.shared
        let central = CoreBluetoothCentral()
        let link = LinkSupervisor(
            machine: LinkMachine(storedIdentifier: CoreBluetoothCentral.storedIdentifier),
            central: central,
            clock: SystemLinkClock(),
            sink: { entry in driveLog.record("link \(entry.state) \(entry.detail)", at: entry.at) }
        )
        let model = AppModel(build: .current, link: link, driveLog: driveLog)
        // Nothing is gated on a screen being visible: the app wants the link from launch, and
        // iOS relaunches it for the dongle through state restoration.
        link.start()
        return model
    }

    /// The link log with the build and the dongle named at the top, ready to paste into a bench
    /// record or an issue. This is what firmware #44 has been waiting for since 2026-10-10.
    func exportText() -> String {
        link.exportLog(build: build)
    }
}
