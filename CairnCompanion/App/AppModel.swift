import CairnKit
import CairnProtocol
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
    /// The clock and the position the dongle's receiver cannot get for itself.
    let priming: PrimingService
    /// Who this phone is to the server, and which way it is reaching it.
    let server: ServerSession
    /// Carrying finished trips over, and the receipts back.
    let offload: OffloadCoordinator
    /// What the server has published: trips, cars, assignments.
    let sync: SyncEngine
    /// The log on disk, so a link can be reviewed after a drive the phone spent locked in a
    /// mount. The ring in `LinkSupervisor` is what the screen shows; this is what survives a
    /// relaunch and what Export Log shares.
    let driveLog: DriveLog

    init(
        build: BuildIdentity, link: LinkSupervisor, priming: PrimingService,
        server: ServerSession, offload: OffloadCoordinator, sync: SyncEngine, driveLog: DriveLog
    ) {
        self.build = build
        self.link = link
        self.priming = priming
        self.server = server
        self.offload = offload
        self.sync = sync
        self.driveLog = driveLog
    }

    /// The real app: a CoreBluetooth central, Core Location, the Secure Enclave, URLSession and
    /// GRDB — each behind the `CairnKit` protocol the tests drive with a fake.
    static func live() -> AppModel {
        let driveLog = DriveLog.shared
        let central = CoreBluetoothCentral()
        // One clock for the link's deadlines and the priming cadence, so an exported log's
        // timings all come from the same place.
        let clock = SystemLinkClock()
        let link = LinkSupervisor(
            machine: LinkMachine(storedIdentifier: CoreBluetoothCentral.storedIdentifier),
            central: central,
            clock: clock,
            sink: { entry in driveLog.record("link \(entry.state) \(entry.detail)", at: entry.at) }
        )
        let priming = PrimingService(link: link, location: CoreLocationSource(), clock: clock)

        let server = ServerSession(
            enrolment: EnrolmentService(
                keyProvider: IdentityKeys.make(),
                identityStore: KeychainIdentityStore()
            ),
            tokenStore: KeychainBearerTokenStore(),
            transportFor: { url in
                guard let base = URL(string: url) else { return nil }
                return URLSessionTransport(baseURL: base)
            },
            // Chunks, and only chunks, go to the system: they are the one request that may
            // outlive the app, and the bearer token exists so they can.
            chunkTransportFor: { url in
                guard let base = URL(string: url) else { return nil }
                return BackgroundChunkTransport(baseURL: base)
            }
        )

        // A database that will not open is not a reason to have no app: the link, the priming
        // and the diagnostics all still work, and offload says it is not available.
        let database = try? CairnDatabase()
        let store: any BundleStore = database.map { GRDBBundleStore(database: $0) } ?? InMemoryBundleStore()
        let offload = OffloadCoordinator(
            link: link, provider: central, session: server, store: store, clock: clock
        )
        let sync = SyncEngine(
            session: server,
            store: database.map { GRDBSyncStore(database: $0) } ?? InMemorySyncStore()
        )

        let model = AppModel(
            build: .current, link: link, priming: priming,
            server: server, offload: offload, sync: sync, driveLog: driveLog
        )

        // The two things that follow the link, wired in one place rather than fighting over
        // one hook.
        link.onTransition = { [weak model] from, to in
            model?.priming.linkChanged(from: from, to: to)
            switch to {
            case .ready(let ready): model?.offload.linkBecameReady(ready)
            default: if case .ready = from { model?.offload.linkEnded() }
            }
        }
        link.onNotify = { [weak model] characteristic, data in
            model?.priming.received(characteristic, data)
            if characteristic == .deviceStatus, let status = PayloadDecoder.deviceStatus(data) {
                model?.offload.deviceStatusChanged(status)
            }
        }

        // Nothing is gated on a screen being visible: the app wants the link from launch, and
        // iOS relaunches it for the dongle through state restoration.
        link.start()
        priming.requestAuthorisation()
        Task {
            await sync.load()
            await server.load()
            await server.chooseRoute()
            await offload.sweep()
            await sync.sync()
        }
        return model
    }

    /// The link log with the build and the dongle named at the top, ready to paste into a bench
    /// record or an issue. This is what firmware #44 has been waiting for since 2026-10-10.
    func exportText() -> String {
        link.exportLog(build: build)
    }

    /// Everything about this phone that the Dongle screen says, in the form a bench record
    /// wants: one line per step, seconds since link-ready.
    var receiverLine: String { priming.timeline.line }
}
