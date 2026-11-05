import CairnProtocol
import Foundation

/// Decides when to offload, and does nothing else.
///
/// The trigger is the plan's: **whenever the link is ready and no trip is active**. Not a
/// button, not a schedule, not a notification from a characteristic that may not exist. The
/// dongle holds standby for a phone that is working, capped at fifteen minutes per connection,
/// so the run leaves at fourteen and picks up at the next link.
@MainActor
@Observable
public final class OffloadCoordinator {
    public private(set) var summary = OffloadSummary()
    public private(set) var isRunning = false
    /// Rows the store is holding, for the Dongle screen's detail.
    public private(set) var rows: [BundleRow] = []
    public private(set) var lastRunAt: Date?

    private let link: LinkSupervisor
    private let provider: any OffloadLinkProvider
    private let session: ServerSession
    private let store: any BundleStore
    private let clock: any LinkClock
    private let machine = OffloadMachine()
    private var task: Task<Void, Never>?
    /// Set while the dongle says a trip is in progress, so a ready link does not mean a run.
    public private(set) var tripActive = false

    public init(
        link: LinkSupervisor,
        provider: any OffloadLinkProvider,
        session: ServerSession,
        store: any BundleStore,
        clock: any LinkClock
    ) {
        self.link = link
        self.provider = provider
        self.session = session
        self.store = store
        self.clock = clock
        Task { await self.refreshRows() }
    }

    /// Call when the link becomes ready. `PrimingService` owns `onTransition`, so the app wires
    /// this from there rather than fighting over the one hook.
    public func linkBecameReady(_ ready: LinkReady) {
        guard ready.canOffload else {
            // The capability bit and both characteristics, or nothing. The old app checked the
            // bit alone while `0030` and `0031` were missing from its discovery list, and the
            // controller exited before its first LIST for a month.
            return
        }
        start()
    }

    public func linkEnded() {
        task?.cancel()
        task = nil
        isRunning = false
        provider.closeOffloadLink()
    }

    /// Run now, if everything a run needs is true.
    public func start() {
        guard !isRunning else { return }
        guard case .ready = link.state else { return }
        guard machine.shouldRun(linkReady: true, tripActive: tripActive, enrolled: session.isEnrolled) else {
            if !session.isEnrolled {
                summary.stopped = .serverUnavailable("this phone is not set up with a server yet")
            }
            return
        }
        guard let offloadLink = provider.openOffloadLink() else { return }

        isRunning = true
        let connectedSince = clock.now
        task = Task { [weak self] in
            guard let self else { return }
            await self.perform(offloadLink, connectedSince: connectedSince)
        }
    }

    private func perform(_ offloadLink: any OffloadLink, connectedSince: Date) async {
        defer {
            isRunning = false
            lastRunAt = clock.now
            provider.closeOffloadLink()
        }
        guard let client = await session.client() else {
            summary.stopped = .serverUnavailable("the server can't be reached")
            return
        }
        let dongleClient = OffloadClient(link: offloadLink)
        do {
            try await dongleClient.start()
        } catch {
            summary.stopped = .linkLost("the offload link would not open")
            return
        }
        defer { Task { await dongleClient.stop() } }

        // The runner is an actor and runs off the main one, so it is handed a plain closure
        // over the wall clock rather than this object's. A test clock reaches it through the
        // deadlines the coordinator computes here, which is where the decisions are.
        let runner = OffloadRunner(
            dongle: dongleClient,
            relay: BundleRelayService(client: client),
            store: store
        )
        let result = await runner.run(connectedSince: connectedSince) { [weak self] progress in
            Task { @MainActor in self?.summary = progress }
        }
        summary = result
        if case .serverUnavailable = result.stopped { session.routeFailed() }
        await refreshRows()
    }

    /// `DEVICE_STATUS` says whether a trip is running, on a firmware that has it. On one that
    /// does not, the dongle refuses offload with `TRIP_ACTIVE` instead, which the run reads as
    /// a stop and not as a problem — so this is an optimisation, not the rule.
    public func deviceStatusChanged(_ status: DeviceStatus) {
        let active = status.tripPhase == .driving
        guard active != tripActive else { return }
        tripActive = active
        if active { linkEnded() } else { start() }
    }

    public func refreshRows() async {
        rows = ((try? await store.allRows()) ?? []).sorted { $0.firstSeenAt > $1.firstSeenAt }
    }

    /// Housekeeping: a delivered row a week old describes a bundle the dongle pruned long ago.
    public func sweep() async {
        try? await store.deleteFinished(before: clock.now.addingTimeInterval(-7 * 24 * 3600))
        await refreshRows()
    }
}
