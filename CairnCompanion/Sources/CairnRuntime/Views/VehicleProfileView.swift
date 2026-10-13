import CairnCore
import Charts
import SwiftUI

/// Readings are stored in kilometres and shown in whichever unit the owner drives in. `formatted`
/// has taken `useMiles` all along; nothing was passing it, so a US owner read their odometer in km.
/// The entry field stays explicitly "(km)" with a live miles conversion under it, because that is a
/// number the owner copies off the dash and converting it on the way in would lose the original.
let odometerInMiles = DisplayUnits.forLocale(.current).distance == .miles

struct VehicleProfileView: View {
    @State private var vehicle: Vehicle
    let vehicleStore: GRDBVehicleStore
    let maintenanceStore: GRDBMaintenanceStore
    let recorder: DriveRecorder
    @State private var maintenanceEntries: [MaintenanceEntry] = []
    @State private var odometerHistory: [OdometerCorrection] = []
    @State private var driveSessions: [DriveSession] = []
    @State private var assignments: [VehicleAssignment] = []
    @State private var showAddMaintenance = false
    @State private var showRecordOdometer = false
    @State private var showEditVehicle = false
    @State private var selectedMaintenanceEntry: MaintenanceEntry?

    init(vehicle: Vehicle, vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore, recorder: DriveRecorder) {
        self._vehicle = State(initialValue: vehicle)
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.recorder = recorder
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                identityCard
                dongleCard
                driveStatsCard
                odometerCard
                maintenanceCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Backdrop().ignoresSafeArea())
        .navigationTitle(vehicle.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button { showAddMaintenance = true } label: {
                        Label("Log Service", systemImage: "wrench.and.screwdriver")
                    }
                    Button { showRecordOdometer = true } label: {
                        Label("Record Odometer", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    Divider()
                    Button { showEditVehicle = true } label: {
                        Label("Edit Vehicle", systemImage: "pencil")
                    }
                    Button {
                        vehicleStore.selectVehicle(vehicle.id)
                    } label: {
                        Label("Set as Active", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAddMaintenance) {
            AddMaintenanceSheet(vehicleID: vehicle.id) { entry in
                Task {
                    try? await maintenanceStore.saveEntry(entry)
                    await load()
                }
            }
        }
        .sheet(isPresented: $showRecordOdometer) {
            RecordOdometerSheet(vehicleID: vehicle.id) { correction in
                Task {
                    try? await maintenanceStore.saveOdometerCorrection(correction)
                    await load()
                }
            }
        }
        .sheet(isPresented: $showEditVehicle) {
            EditVehicleSheet(vehicle: vehicle) { updated in
                Task {
                    try? await vehicleStore.saveVehicle(updated)
                    vehicle = updated
                }
            }
        }
        .sheet(item: $selectedMaintenanceEntry) { entry in
            MaintenanceDetailSheet(entry: entry)
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private var identityCard: some View {
        Card(title: "Vehicle", symbol: "car.fill") {
            MetricGrid {
                Metric("Year", "\(vehicle.year)")
                Metric("Make", vehicle.make)
                Metric("Model", vehicle.model)
                if let code = vehicle.engineCode {
                    Metric("Engine", code)
                }
            }

            Button { showEditVehicle = true } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        }
    }

    // MARK: - Dongle Assignment

    @ViewBuilder
    private var dongleCard: some View {
        let assignedDongle = assignments.first(where: { $0.vehicleID == vehicle.id })

        Card(title: "Dongle", symbol: "sensor.tag.radiowaves.forward") {
            if let assignment = assignedDongle {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assignment.dongleID)
                            .font(.subheadline.weight(.medium).monospaced())
                        Text("Assigned")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    BadgePill(text: "LINKED", color: .green)
                }

                Button(role: .destructive) {
                    Task {
                        try? await vehicleStore.unassign(dongleID: assignment.dongleID)
                        await load()
                    }
                } label: {
                    Label("Unassign", systemImage: "minus.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Placeholder("No dongle assigned")

                AssignDongleSection(
                    vehicleID: vehicle.id,
                    vehicleStore: vehicleStore,
                    existingAssignments: assignments
                ) {
                    Task { await load() }
                }
            }
        }
    }

    // MARK: - Drive Stats

    @ViewBuilder
    private var driveStatsCard: some View {
        let closedSessions = driveSessions.filter { $0.lifecycle == .closed }
        let drives = closedSessions.filter { $0.quality == .drive }
        let bench = closedSessions.filter { $0.quality == .bench }

        Card(title: "Drives", symbol: "road.lanes") {
            if driveSessions.isEmpty {
                Placeholder("No drives recorded")
            } else {
                MetricGrid {
                    Metric("Total drives", "\(closedSessions.count)")
                    Metric("Real drives", "\(drives.count)")
                    if !bench.isEmpty {
                        Metric("Bench sessions", "\(bench.count)")
                    }
                    if let lastDrive = closedSessions.max(by: { $0.startedAt < $1.startedAt }) {
                        Metric("Last drive", lastDrive.startedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                if !drives.isEmpty {
                    let avgStreaming = drives.compactMap(\.streamingFraction).reduce(0, +) / max(1, Double(drives.compactMap(\.streamingFraction).count))
                    let totalDuration = drives.reduce(0.0) { $0 + $1.duration }

                    Divider()
                    MetricGrid {
                        Metric("Total time", formatDuration(totalDuration))
                        Metric("Avg streaming", "\(Int(avgStreaming * 100))%",
                               tone: avgStreaming > 0.9 ? .good : avgStreaming > 0.5 ? .warn : .bad)
                    }
                }
            }
        }
    }

    // MARK: - Odometer

    @ViewBuilder
    private var odometerCard: some View {
        Card(title: "Odometer", symbol: "gauge.with.dots.needle.67percent") {
            if odometerHistory.isEmpty {
                Placeholder("No odometer readings")
            } else {
                if let latest = odometerHistory.first {
                    MetricGrid {
                        Metric("Current", latest.formatted(useMiles: odometerInMiles))
                        Metric("Recorded", latest.recordedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                if odometerHistory.count > 1 {
                    let chartData = odometerHistory.sorted { $0.recordedAt < $1.recordedAt }

                    let axis = odometerInMiles ? "mi" : "km"
                    Chart(chartData, id: \.id) { reading in
                        LineMark(
                            x: .value("Date", reading.recordedAt),
                            y: .value(axis, odometerInMiles ? reading.odometerMiles : reading.odometerKm)
                        )
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", reading.recordedAt),
                            y: .value(axis, odometerInMiles ? reading.odometerMiles : reading.odometerKm)
                        )
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisValueLabel {
                                if let km = value.as(Int.self) {
                                    Text("\(km / 1000)k")
                                }
                            }
                            AxisGridLine()
                        }
                    }
                    .frame(height: 160)
                    .foregroundStyle(Color.accentColor)

                    Divider()

                    ForEach(odometerHistory) { reading in
                        HStack {
                            Text(reading.recordedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(reading.formatted(useMiles: odometerInMiles))
                                .font(.subheadline.weight(.medium).monospacedDigit())
                        }
                    }
                }
            }

            Button { showRecordOdometer = true } label: {
                Label("Record Reading", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        }
    }

    // MARK: - Maintenance Timeline

    @ViewBuilder
    private var maintenanceCard: some View {
        Card(title: "Maintenance", symbol: "wrench.and.screwdriver") {
            if maintenanceEntries.isEmpty {
                Placeholder("No maintenance logged")
            } else {
                let grouped = groupedMaintenance

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.key) { group in
                        Text(group.key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, group.key == grouped.first?.key ? 0 : 12)
                            .padding(.bottom, 6)

                        ForEach(group.entries) { entry in
                            Button {
                                selectedMaintenanceEntry = entry
                            } label: {
                                maintenanceRow(entry)
                            }
                            .buttonStyle(.plain)

                            if entry.id != group.entries.last?.id {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }
            }

            Button { showAddMaintenance = true } label: {
                Label("Log Service", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        }
    }

    private struct MaintenanceGroup {
        let key: String
        let entries: [MaintenanceEntry]
    }

    private var groupedMaintenance: [MaintenanceGroup] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let grouped = Dictionary(grouping: maintenanceEntries) { entry in
            formatter.string(from: entry.performedAt)
        }
        return grouped.map { MaintenanceGroup(key: $0.key, entries: $0.value) }
            .sorted { group1, group2 in
                guard let d1 = group1.entries.first?.performedAt,
                      let d2 = group2.entries.first?.performedAt else { return false }
                return d1 > d2
            }
    }

    @ViewBuilder
    private func maintenanceRow(_ entry: MaintenanceEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.category.systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Text(entry.performedAt, style: .date)
                    if let cost = entry.formattedCost {
                        Text(cost).foregroundStyle(Color.accentColor)
                    }
                    if let shop = entry.shop {
                        Text(shop)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let notes = entry.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private func load() async {
        maintenanceEntries = (try? await maintenanceStore.listEntries(vehicleID: vehicle.id)) ?? []
        odometerHistory = (try? await maintenanceStore.listOdometerCorrections(vehicleID: vehicle.id)) ?? []
        driveSessions = (try? await recorder.sessions(forVehicle: vehicle.id)) ?? []
        assignments = (try? await vehicleStore.assignments()) ?? []
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

// MARK: - Assign Dongle

private struct AssignDongleSection: View {
    let vehicleID: String
    let vehicleStore: GRDBVehicleStore
    let existingAssignments: [VehicleAssignment]
    let onAssign: () -> Void
    @State private var dongleID = ""

    var body: some View {
        HStack {
            TextField("Dongle ID", text: $dongleID)
                .font(.subheadline.monospaced())
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Button("Assign") {
                let trimmed = dongleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task {
                    try? await vehicleStore.assign(dongleID: trimmed, to: vehicleID)
                    dongleID = ""
                    onAssign()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(dongleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

// MARK: - Edit Vehicle Sheet

struct EditVehicleSheet: View {
    let original: Vehicle
    let onSave: (Vehicle) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var year: String
    @State private var make: String
    @State private var model: String
    @State private var engineCode: String

    init(vehicle: Vehicle, onSave: @escaping (Vehicle) -> Void) {
        self.original = vehicle
        self.onSave = onSave
        self._year = State(initialValue: "\(vehicle.year)")
        self._make = State(initialValue: vehicle.make)
        self._model = State(initialValue: vehicle.model)
        self._engineCode = State(initialValue: vehicle.engineCode ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Year", text: $year)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Make", text: $make)
                    TextField("Model", text: $model)
                    TextField("Engine code (optional)", text: $engineCode)
                }
                Section {
                    if let preview = previewName {
                        Text(preview)
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Edit Vehicle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let y = Int(year), !make.isEmpty, !model.isEmpty else { return }
                        var updated = original
                        updated.year = y
                        updated.make = make
                        updated.model = model
                        updated.engineCode = engineCode.isEmpty ? nil : engineCode
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(Int(year) == nil || make.isEmpty || model.isEmpty)
                }
            }
        }
    }

    private var previewName: String? {
        guard let y = Int(year), !make.isEmpty, !model.isEmpty else { return nil }
        var parts = ["\(y)", make, model]
        if !engineCode.isEmpty { parts.append("— \(engineCode)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Maintenance Detail Sheet

private struct MaintenanceDetailSheet: View {
    let entry: MaintenanceEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Service") {
                    LabeledContent("Category") {
                        Label(entry.category.displayName, systemImage: entry.category.systemImage)
                    }
                    LabeledContent("Title", value: entry.title)
                    LabeledContent("Date") {
                        Text(entry.performedAt, style: .date)
                    }
                }
                Section("Details") {
                    if let cost = entry.formattedCost {
                        LabeledContent("Cost", value: cost)
                    }
                    if let shop = entry.shop {
                        LabeledContent("Shop", value: shop)
                    }
                    if let km = entry.odometerKm {
                        LabeledContent("Odometer", value: "\(km.formatted()) km")
                    }
                }
                if !entry.partNumbers.isEmpty {
                    Section("Parts") {
                        ForEach(entry.partNumbers, id: \.self) { part in
                            Text(part)
                                .font(.subheadline.monospaced())
                        }
                    }
                }
                if let notes = entry.notes, !notes.isEmpty {
                    Section("Notes") {
                        Text(notes)
                    }
                }
            }
            .navigationTitle(entry.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Add Maintenance Sheet

struct AddMaintenanceSheet: View {
    let vehicleID: String
    let onSave: (MaintenanceEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category: MaintenanceCategory = .oilChange
    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var costString: String = ""
    @State private var shop: String = ""
    @State private var odometerString: String = ""
    @State private var performedAt: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Category", selection: $category) {
                        ForEach(MaintenanceCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.systemImage)
                                .tag(cat)
                        }
                    }
                    TextField("Title", text: $title)
                    DatePicker("Date", selection: $performedAt, displayedComponents: .date)
                }
                Section("Details") {
                    TextField("Cost", text: $costString)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    TextField("Shop / location", text: $shop)
                    TextField("Odometer (km)", text: $odometerString)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Log Service")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = MaintenanceEntry(
                            vehicleID: vehicleID,
                            category: category,
                            performedAt: performedAt,
                            title: title.isEmpty ? category.displayName : title,
                            notes: notes.isEmpty ? nil : notes,
                            cost: Decimal(string: costString),
                            shop: shop.isEmpty ? nil : shop,
                            odometerKm: Int(odometerString)
                        )
                        onSave(entry)
                        dismiss()
                    }
                }
            }
            .onChange(of: category) { _, newCat in
                if title.isEmpty || MaintenanceCategory.allCases.map(\.displayName).contains(title) {
                    title = newCat.displayName
                }
            }
            .onAppear { title = category.displayName }
        }
    }
}

// MARK: - Record Odometer Sheet

struct RecordOdometerSheet: View {
    let vehicleID: String
    let onSave: (OdometerCorrection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var odometerString: String = ""
    @State private var recordedAt: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Odometer (km)", text: $odometerString)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    DatePicker("Date", selection: $recordedAt, displayedComponents: .date)
                } footer: {
                    if let km = Int(odometerString) {
                        let miles = Int(Double(km) * 0.621371)
                        Text("\(miles.formatted()) miles")
                    }
                }
            }
            .navigationTitle("Record Odometer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let km = Int(odometerString) else { return }
                        let correction = OdometerCorrection(
                            vehicleID: vehicleID,
                            odometerKm: km,
                            recordedAt: recordedAt
                        )
                        onSave(correction)
                        dismiss()
                    }
                    .disabled(Int(odometerString) == nil)
                }
            }
        }
    }
}
