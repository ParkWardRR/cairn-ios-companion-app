import CairnKit
import CairnRuntime
import Foundation
import Observation

/// The one object the screens read.
///
/// Architecture rule 2: one `AppModel`, main-actor, observable, and no two objects writing the
/// same state. The old app had a `SessionState`, a `DrivingSession`, a `CairnBLEManager`, an
/// `OffloadController` and a `TripSyncClient` all mutating overlapping fields, which is why its
/// "stale pairing" state could clear the connection wish and leave the session armed.
@MainActor
@Observable
final class AppModel {
    let build: BuildIdentity
    let log: DriveLog

    init(build: BuildIdentity, log: DriveLog) {
        self.build = build
        self.log = log
    }

    /// The real app: this build's stamp, and the log in `Documents` that the Files app can see.
    static func live() -> AppModel {
        AppModel(build: .current, log: .shared)
    }
}
