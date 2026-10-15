import CairnCore
import SwiftUI

public struct TripsView: View {
    let recorder: DriveRecorder
    let vehicleStore: GRDBVehicleStore
    let maintenanceStore: GRDBMaintenanceStore
    let syncClient: TripSyncClient
    @State private var sessions: [DriveSession] = []
    @State private var serverTrips: [TripSnapshot] = []
    @State private var isLoading = true
    @State private var vehicles: [Vehicle] = []
    @State private var filterVehicleID: String?
    @State private var dateRange: DateRange = .all
    @State private var showFavoritesOnly = false
    @State private var searchText = ""
    @State private var allAnnotations: [Annotation] = []
    @AppStorage(FuelEstimate.ethanolKey) private var ethanol = FuelEstimate.defaultEthanolPercent

    public init(recorder: DriveRecorder, vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore, syncClient: TripSyncClient) {
        self.recorder = recorder
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.syncClient = syncClient
    }

    private var allEntries: [HistoryEntry] {
        HistoryMerger.merge(sessions: sessions, trips: serverTrips)
    }

    private var filteredEntries: [HistoryEntry] {
        var result = allEntries

        if let vid = filterVehicleID {
            result = result.filter {
                $0.phoneSession?.vehicleID == vid || $0.serverTrip?.vehicleID == vid
            }
        }

        let calendar = Calendar.current
        let now = Date()
        switch dateRange {
        case .today:
            result = result.filter { calendar.isDateInToday($0.startedAt) }
        case .week:
            if let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
                result = result.filter { $0.startedAt >= weekStart }
            }
        case .month:
            if let monthStart = calendar.dateInterval(of: .month, for: now)?.start {
                result = result.filter { $0.startedAt >= monthStart }
            }
        case .all:
            break
        }

        if showFavoritesOnly {
            let favTargetIDs = Set(allAnnotations.filter { $0.kind == .favorite }.map(\.targetID))
            result = result.filter { favTargetIDs.contains($0.id) }
        }

        if !searchText.isEmpty {
            let notesByTarget = Dictionary(grouping: allAnnotations.filter { $0.kind == .note }, by: \.targetID)
            result = result.filter { entry in
                notesByTarget[entry.id]?.contains { $0.text.localizedCaseInsensitiveContains(searchText) } == true
            }
        }

        return result
    }

    private var isFiltered: Bool {
        filterVehicleID != nil || dateRange != .all || showFavoritesOnly || !searchText.isEmpty
    }

    private var tripDays: [TripDay] {
        TripDay.group(filteredEntries.map { TripSummary(entry: $0, ethanolPercent: ethanol) })
    }

    private var summaryTotals: String {
        let summaries = filteredEntries.map { TripSummary(entry: $0, ethanolPercent: ethanol) }.filter { !$0.isBench }
        let distance = summaries.compactMap(\.distanceMeters).reduce(0, +)
        var parts = ["\(summaries.count) \(summaries.count == 1 ? "trip" : "trips")"]
        if distance > 0 { parts.append(formatDistance(distance)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if allEntries.isEmpty {
                    ContentUnavailableView(
                        "No trips yet",
                        systemImage: "car.side",
                        description: Text("Trips appear here by themselves once your Cairn dongle has connected and you have driven.")
                    )
                } else {
                    VStack(spacing: 0) {
                        filterBar
                        if filteredEntries.isEmpty {
                            filteredEmptyState
                        } else {
                            driveList
                        }
                    }
                }
            }
            .navigationTitle("Trips")
            .searchable(text: $searchText, prompt: "Search notes")
            .toolbar {
                if syncClient.hasServer {
                    ToolbarItem(placement: .automatic) {
                        syncButton
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Button { filterVehicleID = nil } label: {
                        HStack {
                            Text("All Vehicles")
                            if filterVehicleID == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(vehicles.filter { !$0.isArchived }) { vehicle in
                        Button {
                            filterVehicleID = vehicle.id
                        } label: {
                            HStack {
                                Text(vehicle.displayName)
                                if filterVehicleID == vehicle.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "car.fill")
                            .font(.caption)
                        Text(vehicleFilterLabel)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(filterVehicleID != nil ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(filterVehicleID != nil ? Color.accentColor : .primary)
                }

                Button {
                    showFavoritesOnly.toggle()
                } label: {
                    Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(showFavoritesOnly ? Color.yellow.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(showFavoritesOnly ? .yellow : .secondary)
                }

                Spacer()
            }

            Picker("Date range", selection: $dateRange) {
                ForEach(DateRange.allCases, id: \.self) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)

            Text(summaryTotals)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var vehicleFilterLabel: String {
        if let vid = filterVehicleID, let v = vehicles.first(where: { $0.id == vid }) {
            return v.displayName
        }
        return "All Vehicles"
    }

    // MARK: - Empty State

    @ViewBuilder
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("No matching trips", systemImage: "magnifyingglass")
        } description: {
            if showFavoritesOnly {
                Text("No starred trips. Open a trip and star it.")
            } else if !searchText.isEmpty {
                Text("No trips have notes matching \"\(searchText)\".")
            } else if dateRange != .all {
                Text("No trips \(dateRange.emptyLabel).")
            } else if let vid = filterVehicleID, let v = vehicles.first(where: { $0.id == vid }) {
                Text("No trips for \(v.displayName).")
            } else {
                Text("Try adjusting your filters.")
            }
        } actions: {
            Button("Clear Filters") {
                filterVehicleID = nil
                dateRange = .all
                showFavoritesOnly = false
                searchText = ""
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Drive List

    private var driveList: some View {
        let entries = Dictionary(uniqueKeysWithValues: filteredEntries.map { ($0.id, $0) })
        return List {
            ForEach(tripDays) { day in
                Section {
                    ForEach(day.trips) { summary in
                        if let entry = entries[summary.id] {
                            NavigationLink(value: entry.id) {
                                TripCard(summary: summary, entry: entry, annotations: allAnnotations.filter { $0.targetID == entry.id })
                            }
                        }
                    }
                    .onDelete { indexSet in
                        let doomed = indexSet.compactMap { entries[day.trips[$0].id]?.phoneSession?.id }
                        Task {
                            for id in doomed { try? await recorder.deleteSession(id) }
                            await load()
                        }
                    }
                } header: {
                    TripDayHeader(day: day)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationDestination(for: String.self) { id in
            if let entry = allEntries.first(where: { $0.id == id }) {
                TripDetailView(entry: entry, maintenanceStore: maintenanceStore, vehicles: vehicles) {
                    Task { await loadAnnotations() }
                }
            }
        }
    }

    @ViewBuilder
    private var syncButton: some View {
        Button {
            syncClient.sync()
            Task {
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        } label: {
            if syncClient.state == .syncing {
                ProgressView()
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(syncClient.state == .syncing)
    }

    // MARK: - Data Loading

    private func load() async {
        isLoading = true
        vehicles = (try? await vehicleStore.listVehicles()) ?? []
        sessions = (try? await recorder.allSessions()) ?? []
        serverTrips = syncClient.cachedTrips()
        await loadAnnotations()
        isLoading = false
    }

    private func loadAnnotations() async {
        allAnnotations = (try? await maintenanceStore.listAnnotations(vehicleID: nil)) ?? []
    }
}

// MARK: - DateRange

enum DateRange: String, CaseIterable {
    case today, week, month, all

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        case .all: "All"
        }
    }

    var emptyLabel: String {
        switch self {
        case .today: "today"
        case .week: "this week"
        case .month: "this month"
        case .all: ""
        }
    }
}

// MARK: - Detail

struct TripDetailView: View {
    let entry: HistoryEntry
    let maintenanceStore: GRDBMaintenanceStore
    let vehicles: [Vehicle]
    var onAnnotationChange: (() -> Void)?
    @State private var annotations: [Annotation] = []
    @State private var showAddNote = false
    @State private var noteText = ""
    @State private var editingAnnotation: Annotation?

    init(entry: HistoryEntry, maintenanceStore: GRDBMaintenanceStore, vehicles: [Vehicle] = [], onAnnotationChange: (() -> Void)? = nil) {
        self.entry = entry
        self.maintenanceStore = maintenanceStore
        self.vehicles = vehicles
        self.onAnnotationChange = onAnnotationChange
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                tripHeader
                if let session = entry.phoneSession {
                    phoneSection(session)
                }
                if let trip = entry.serverTrip {
                    serverSection(trip)
                }
                annotationSection
                if let session = entry.phoneSession, !session.events.isEmpty {
                    eventTimeline(session)
                }
            }
            .padding()
        }
        .navigationTitle(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        toggleFavorite()
                    } label: {
                        let isFav = annotations.contains { $0.kind == .favorite }
                        Label(isFav ? "Unfavorite" : "Favorite", systemImage: isFav ? "star.slash" : "star")
                    }
                    Button {
                        showAddNote = true
                    } label: {
                        Label("Add Note", systemImage: "note.text.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await loadAnnotations() }
        .alert("Add Note", isPresented: $showAddNote) {
            TextField("Note", text: $noteText)
            Button("Save") {
                guard !noteText.isEmpty else { return }
                let annotation = Annotation(
                    vehicleID: entry.phoneSession?.vehicleID,
                    targetID: entry.id,
                    text: noteText
                )
                Task {
                    try? await maintenanceStore.saveAnnotation(annotation)
                    noteText = ""
                    await loadAnnotations()
                    onAnnotationChange?()
                }
            }
            Button("Cancel", role: .cancel) { noteText = "" }
        }
        .alert("Edit Note", isPresented: Binding(
            get: { editingAnnotation != nil },
            set: { if !$0 { editingAnnotation = nil } }
        )) {
            if let editing = editingAnnotation {
                TextField("Note", text: $noteText)
                Button("Save") {
                    var updated = editing
                    updated.text = noteText
                    updated.updatedAt = Date()
                    Task {
                        try? await maintenanceStore.saveAnnotation(updated)
                        editingAnnotation = nil
                        noteText = ""
                        await loadAnnotations()
                        onAnnotationChange?()
                    }
                }
                Button("Cancel", role: .cancel) {
                    editingAnnotation = nil
                    noteText = ""
                }
            }
        }
    }

    @AppStorage(FuelEstimate.ethanolKey) private var ethanol = FuelEstimate.defaultEthanolPercent
    private var summary: TripSummary { TripSummary(entry: entry, ethanolPercent: ethanol) }

    /// The answer to "what was this trip": the route, stat bar, categorized insights, and fuel note.
    @ViewBuilder
    private var tripHeader: some View {
        let trip = entry.serverTrip

        TripRouteMap(runs: summary.routeRuns)

        // -- Stat bar: Driving / Stopped / Total / Distance / Max Speed --
        MetricGrid {
            let drivingSec = trip?.drivingSeconds
            Metric("Driving", formatDuration(drivingSec ?? summary.durationSeconds))
            Metric("Stopped", stoppedText(total: summary.durationSeconds, driving: drivingSec))
            Metric("Total", formatDuration(summary.durationSeconds))

            let distance = summary.distanceMeters.map { tripUnits.distanceParts(metres: $0) }
            Metric("Distance", distance?.value ?? "\u{2014}", unit: distance?.unit)

            let topKph = trip?.maxObdSpeedKph ?? summary.maxSpeedKph
            let top = topKph.map { tripUnits.speedParts(kph: Double($0)) }
            Metric("Max speed", top?.value ?? "\u{2014}", unit: top?.unit)

            if let fuel = summary.fuel {
                let trip = tripUnits.economyParts(mpgUS: fuel.tripMpg)
                Metric("Fuel economy", trip.value, unit: trip.unit)
            }
        }

        // -- Drive insights --
        driveInsights(trip)

        // -- Performance insights --
        performanceInsights(trip)

        // -- Data Quality insights --
        dataQualityInsights(trip)

        if let fuel = summary.fuel {
            Text("Economy is estimated from \(fuel.sampleCount) airflow readings at E\(fuel.ethanolPercent): the car's own fuel rate is not read. Set the blend in Settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if summary.isBench {
            Text("This looks like a bench test: no engine data and the dongle never reported driving.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func stoppedText(total: TimeInterval, driving: TimeInterval?) -> String {
        guard let driving else { return "\u{2014}" }
        let stopped = max(0, total - driving)
        return formatDuration(stopped)
    }

    @ViewBuilder
    private func driveInsights(_ trip: TripSnapshot?) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let distance = summary.distanceMeters {
                    insightRow("Distance", tripUnits.distanceText(metres: distance))
                }
                if let avg = summary.averageSpeedKph {
                    insightRow("Average speed", tripUnits.speedText(kph: Double(avg)))
                }
                let topKph = trip?.maxObdSpeedKph ?? summary.maxSpeedKph
                if let kph = topKph {
                    insightRow("Top speed", tripUnits.speedText(kph: Double(kph)))
                }
                if let driving = trip?.drivingSeconds {
                    let idle = max(0, summary.durationSeconds - driving)
                    insightRow("Idle time", formatDuration(idle))
                }
                if let fuel = summary.fuel {
                    if let cruise = fuel.cruiseMpg {
                        insightRow("Cruising economy", tripUnits.economyText(mpgUS: cruise))
                    }
                    if let gallons = summary.fuelGallons {
                        let vol = tripUnits.volumeParts(gallonsUS: gallons)
                        insightRow("Fuel used", "\(vol.value) \(vol.unit)")
                    }
                }
            }
        } label: {
            Label("Drive", systemImage: "car.fill")
        }
    }

    @ViewBuilder
    private func performanceInsights(_ trip: TripSnapshot?) -> some View {
        let maxRpm = trip?.maxRpm ?? summary.maxSpeedKph.flatMap { _ in nil as Int? }
        let boostCount = trip?.boostSamples ?? 0
        if maxRpm != nil || boostCount > 0 {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let rpm = trip?.maxRpm {
                        insightRow("Top RPM", "\(rpm)")
                    }
                    if boostCount > 0 {
                        insightRow("Boost samples", "\(boostCount)")
                    }
                }
            } label: {
                Label("Performance", systemImage: "gauge.with.dots.needle.33percent")
            }
        }
    }

    @ViewBuilder
    private func dataQualityInsights(_ trip: TripSnapshot?) -> some View {
        if let trip {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if trip.gnssSamples > 0 {
                        let fixRate = trip.fixSamples > 0
                            ? Int((Double(trip.fixSamples) / Double(trip.gnssSamples) * 100).rounded())
                            : 0
                        insightRow("GPS fix rate", "\(fixRate)%",
                                   tone: fixRate < 80 ? .warn : .neutral)
                    }
                    if trip.gapCount > 0 {
                        HStack(spacing: 0) {
                            insightRow("Gaps", "\(trip.gapCount) (\(formatDuration(trip.gnssGapSeconds)))")
                            Spacer()
                            Badge(text: "gaps", tone: .warn)
                        }
                    }
                    if let maxGap = trip.maxGapMs, maxGap > 0 {
                        insightRow("Longest gap", formatDuration(Double(maxGap) / 1000.0))
                    }
                    insightRow("OBD samples", "\(trip.obdSamples)")
                    insightRow("GNSS samples", "\(trip.gnssSamples)")
                    insightRow("Phone samples", "\(trip.phoneSamples)")
                }
            } label: {
                HStack(spacing: 6) {
                    Label("Data Quality", systemImage: "waveform.badge.magnifyingglass")
                    if trip.gapCount > 0 {
                        Badge(text: "\(trip.gapCount) gaps", tone: .warn)
                    }
                }
            }
        }
    }

    private func insightRow(_ label: String, _ value: String, tone: Tone = .neutral) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
        }
    }

    @ViewBuilder
    private var annotationSection: some View {
        if !annotations.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(annotations) { annotation in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: annotation.kind.systemImage)
                                .foregroundStyle(annotation.kind == .favorite ? .yellow : .secondary)
                                .frame(width: 16)
                            if annotation.kind != .favorite {
                                Text(annotation.text)
                                    .font(.callout)
                            }
                            Spacer()
                            Text(annotation.updatedAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            if annotation.kind == .note {
                                Button {
                                    noteText = annotation.text
                                    editingAnnotation = annotation
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                            }
                            Button(role: .destructive) {
                                Task {
                                    try? await maintenanceStore.deleteAnnotation(annotation.id)
                                    await loadAnnotations()
                                    onAnnotationChange?()
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Notes")
            }
        }
    }

    private func loadAnnotations() async {
        annotations = (try? await maintenanceStore.annotations(forTarget: entry.id)) ?? []
    }

    private func toggleFavorite() {
        Task {
            if let existing = annotations.first(where: { $0.kind == .favorite }) {
                try? await maintenanceStore.deleteAnnotation(existing.id)
            } else {
                let fav = Annotation(
                    vehicleID: entry.phoneSession?.vehicleID,
                    targetID: entry.id,
                    kind: .favorite,
                    text: ""
                )
                try? await maintenanceStore.saveAnnotation(fav)
            }
            await loadAnnotations()
            onAnnotationChange?()
        }
    }

    @ViewBuilder
    private func phoneSection(_ session: DriveSession) -> some View {
        GroupBox("Phone-Observed Session") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tile("Duration", formatDuration(session.duration))
                tile("Streaming", session.streamingFraction.map { "\(Int($0 * 100))%" } ?? "\u{2014}")
                tile("Sent", "\(session.counters.sent)")
                tile("Accepted", "\(session.counters.accepted)")
                tile("Rejected", "\(session.counters.rejected)")
                tile("Queue drops", "\(session.counters.queueDrops)")
                tile("Write failures", "\(session.counters.writeFailures)")
                tile("Reconnects", "\(session.reconnects)")
                tile("Track points", "\(session.track.count)")
                tile("OBD data", session.obdReceived ? "Yes" : "No")
                tile("Device driving", session.deviceReportedDriving ? "Yes" : "No")
                tile("Classification", session.quality.rawValue.capitalized)
            }
            .padding(.top, 4)
        }

        if session.lifecycle != .closed {
            GroupBox {
                HStack {
                    Image(systemName: "info.circle")
                    Text("This session is \(session.lifecycle.rawValue). Statistics are provisional.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func serverSection(_ trip: TripSnapshot) -> some View {
        GroupBox("Server Trip") {
            VStack(alignment: .leading, spacing: 8) {
                if trip.vehicleID != nil || trip.deviceID != nil || trip.tripId != nil {
                    HStack(spacing: 12) {
                        if let vid = trip.vehicleID,
                           let vehicle = vehicles.first(where: { $0.id == vid }) {
                            Label("\(vehicle.year) \(vehicle.make) \(vehicle.model)", systemImage: "car.fill")
                                .font(.caption)
                        }
                        if let did = trip.deviceID {
                            Label(String(did.prefix(8)), systemImage: "sensor.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    tile("Duration", formatDuration(trip.durationSeconds))
                    if let driving = trip.drivingSeconds {
                        tile("Driving", formatDuration(driving))
                    }
                    if let legs = trip.legCount {
                        tile("Legs", "\(legs)")
                    }
                    if let speed = trip.maxObdSpeedKph {
                        tile("Max OBD speed", tripUnits.speedText(kph: Double(speed)))
                    }
                    if let speed = trip.maxSpeedKph {
                        tile("Max GNSS speed", tripUnits.speedText(kph: Double(speed)))
                    }
                    if let rpm = trip.maxRpm { tile("Max RPM", "\(rpm)") }
                    tile("OBD samples", "\(trip.obdSamples)")
                    tile("GNSS samples", "\(trip.gnssSamples)")
                    tile("Fix samples", "\(trip.fixSamples)")
                    if trip.boostSamples > 0 {
                        tile("Boost samples", "\(trip.boostSamples)")
                    }
                    tile("Phone samples", "\(trip.phoneSamples)")
                    tile("GNSS gaps", "\(trip.gapCount) (\(formatDuration(trip.gnssGapSeconds)))")
                    if let maxGap = trip.maxGapMs, maxGap > 0 {
                        tile("Longest gap", formatDuration(Double(maxGap) / 1000.0))
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func eventTimeline(_ session: DriveSession) -> some View {
        GroupBox("Link Events") {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.events.enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(eventColor(event.kind))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.rawValue.replacingOccurrences(of: "bluetooth", with: "BT "))
                                .font(.caption.weight(.medium))
                            if let detail = event.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(event.at, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventColor(_ kind: LinkEventKind) -> Color {
        switch kind {
        case .ready, .armed, .streamingResumed: .green
        case .dropped, .streamingLost, .bluetoothUnavailable: .orange
        case .failed: .red
        case .disarmed: .secondary
        }
    }
}

// MARK: - Merge

enum HistoryMerger {
    static func merge(sessions: [DriveSession], trips: [TripSnapshot]) -> [HistoryEntry] {
        var entries: [HistoryEntry] = sessions.map { HistoryEntry(phoneSession: $0) }
        var matchedTrips: Set<String> = []
        for i in entries.indices {
            guard let session = entries[i].phoneSession else { continue }
            if let trip = trips.first(where: { matchesTime(session: session, trip: $0) && !matchedTrips.contains($0.id) }) {
                entries[i] = HistoryEntry(phoneSession: session, serverTrip: trip)
                matchedTrips.insert(trip.id)
            }
        }
        for trip in trips where !matchedTrips.contains(trip.id) {
            entries.append(HistoryEntry(serverTrip: trip))
        }
        entries.sort { $0.startedAt > $1.startedAt }
        return entries
    }

    private static func matchesTime(session: DriveSession, trip: TripSnapshot) -> Bool {
        guard let tripEnd = trip.endedAt else { return false }
        let sessionEnd = session.closedAt ?? session.lastObservedAt
        let overlapStart = max(session.startedAt, trip.startedAt)
        let overlapEnd = min(sessionEnd, tripEnd)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        let sessionDuration = sessionEnd.timeIntervalSince(session.startedAt)
        guard sessionDuration > 0 else { return false }
        return overlap / sessionDuration > 0.5
    }
}
