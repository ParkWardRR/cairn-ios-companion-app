import CairnCore
import CairnRuntime
import SwiftUI

@main
struct CairnCompanionApp: App {
    private let session: DrivingSession
    private let vehicleStore: GRDBVehicleStore
    private let maintenanceStore: GRDBMaintenanceStore
    private let syncClient: TripSyncClient
    private let dataPorter: DataPorter
    private let enrolmentService: EnrolmentService
    private let outboxStore: GRDBOutboxStore
    private let syncStateStore: GRDBSyncStateStore
    private let offload: OffloadController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let state = SessionState()
        let db = try! CairnDatabase()
        let driveStore = GRDBDriveStore(db: db)
        let vehicleStore = GRDBVehicleStore(db: db)
        let maintenanceStore = GRDBMaintenanceStore(db: db)
        let recorder = DriveRecorder(store: driveStore, vehicleStore: vehicleStore)
        let ble = CairnBLEManager(state: state)
        // Hold references in locals too, so the Task { ... } below captures those (reference-
        // typed) locals rather than `self`. Swift 6 refuses an escaping closure that captures
        // `self` from a struct init.
        let power = PowerStateMonitor()
        let session = DrivingSession(state: state, ble: ble, recorder: recorder, power: power)
        self.session = session
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.dataPorter = DataPorter(db: db, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore)

        let keyProvider = IdentityKeys.make()
        let identityStore = KeychainIdentityStore()
        let enrolmentService = EnrolmentService(keyProvider: keyProvider, identityStore: identityStore)
        self.enrolmentService = enrolmentService
        let syncClient = TripSyncClient(enrolmentService: enrolmentService)
        self.syncClient = syncClient
        outboxStore = GRDBOutboxStore(db: db)
        syncStateStore = GRDBSyncStateStore(db: db)
        let offload = OffloadController(ble: ble, sync: syncClient)
        self.offload = offload
        session.onDongleReady = { offload.dongleReady() }
        session.onDongleLost = { offload.dongleLost() }

        // Introduce the live session to CarPlay before any scene can connect — CarPlay is allowed to
        // cold-launch the app, and its scene delegate has no other way to reach this graph. Readings
        // only: the car screen is never handed anything that could start or stop recording.
        CairnCarPlayLink.shared.attach(state: state, deviceInfo: { ble.lastDeviceInfo })

        #if DEBUG
        if DemoMode.seedsTrips {
            Task { await DemoMode.seedTrips(into: driveStore) }
            syncClient.injectDemoTrips(DemoMode.demoServerTrips())
        }
        if let scenario = DemoMode.scenario {
            DemoMode.apply(scenario, to: state)
            return
        }
        #endif
        session.resumeIfEnabled()
        let client = syncClient
        Task { await client.loadCachedSnapshot() }
        #if DEBUG
        // A test launch can force a sync (CAIRN_TEST_SYNC=1) to prove a relaunched app still signs in.
        if ProcessInfo.processInfo.environment["CAIRN_TEST_SYNC"] != nil { syncClient.sync() }
        #endif
        if syncClient.isStale { syncClient.sync() }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let scale = DemoMode.scale {
                GeometryReader { proxy in
                    RootView(session: session, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService, offload: offload)
                        .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                RootView(session: session, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService, offload: offload)
            }
            #else
            RootView(session: session, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService, offload: offload)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            session.log("scene \(phase)")
        }
    }
}
