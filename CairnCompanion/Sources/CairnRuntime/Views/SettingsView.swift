import CairnCore
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    let session: DrivingSession
    let syncClient: TripSyncClient
    let dataPorter: DataPorter
    let enrolmentService: EnrolmentService?
    @State private var lanURL: String = ""
    @State private var tailnetURL: String = ""
    @State private var showDeleteConfirm = false
    @State private var showServerSetup = false
    @State private var isProbing = false
    @State private var showExportSheet = false
    @State private var showImportPicker = false
    @State private var exportPassphrase = ""
    @State private var importPassphrase = ""
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    @State private var importFileURL: URL?
    @State private var showImportPassphrase = false
    @State private var dataMessage: String?
    @State private var dataError: String?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var enrolmentState: EnrolmentState = .notEnrolled
    @State private var enrolledIdentity: EnrolledIdentity?
    @State private var invitationCode: String = ""
    @State private var isEnrolling = false
    @State private var enrolmentError: String?
    @State private var showResetIdentity = false
    @State private var adminClients: [ClientEntry] = []
    @State private var adminDevices: [DeviceEntry] = []
    @State private var isLoadingAdmin = false
    @State private var revokeTarget: ClientEntry?
    @State private var showRevokeConfirm = false
    @State private var dashboard = DashboardAccess()
    @State private var showDashboard = false
    @State private var showDashboardCode = false
    @State private var dashboardCode = ""
    @AppStorage(FuelEstimate.ethanolKey) private var ethanol = FuelEstimate.defaultEthanolPercent

    let offload: OffloadController?

    public init(session: DrivingSession, syncClient: TripSyncClient, dataPorter: DataPorter, enrolmentService: EnrolmentService? = nil, offload: OffloadController? = nil) {
        self.offload = offload
        self.session = session
        self.syncClient = syncClient
        self.dataPorter = dataPorter
        self.enrolmentService = enrolmentService
    }

    public var body: some View {
        NavigationStack {
            Form {
                if enrolmentService != nil {
                    identitySection
                }
                if enrolledIdentity?.isAdmin == true {
                    adminSection
                }
                if syncClient.hasServer { dashboardSection }
                fuelSection
                bluetoothSection
                if let offload {
                    OffloadSection(offload: offload)
                }
                serverSection
                if syncClient.hasServer {
                    diagnosticsSection
                    syncStatusSection
                }
                dataSection
                aboutSection
                dangerZone
            }
            .navigationTitle("Settings")
            .onAppear(perform: reloadSetup)
            // The setup sheet (scan a QR code) changes all of this while this screen is showing.
            .onReceive(NotificationCenter.default.publisher(for: .cairnSetupChanged).receive(on: DispatchQueue.main)) { _ in
                reloadSetup()
            }
            .confirmationDialog("Reset device identity?", isPresented: $showResetIdentity, titleVisibility: .visible) {
                Button("Reset Identity", role: .destructive) {
                    resetIdentity()
                }
            } message: {
                Text("This forgets this phone's sign-in key and enrolment. You will need a setup QR code or a new invitation code to enrol again.")
            }
            .alert("Export", isPresented: $showExportSheet) {
                SecureField("Passphrase", text: $exportPassphrase)
                Button("Export") { performExport() }
                Button("Cancel", role: .cancel) { exportPassphrase = "" }
            } message: {
                Text("Enter a passphrase to encrypt the backup. You'll need it to restore.")
            }
            .alert("Import", isPresented: $showImportPassphrase) {
                SecureField("Passphrase", text: $importPassphrase)
                Button("Import") { performImport() }
                Button("Cancel", role: .cancel) { importPassphrase = ""; importFileURL = nil }
            } message: {
                Text("Enter the passphrase used when this backup was created.")
            }
            .alert("Done", isPresented: .init(get: { dataMessage != nil }, set: { if !$0 { dataMessage = nil } })) {
                Button("OK") { dataMessage = nil }
            } message: {
                Text(dataMessage ?? "")
            }
            .alert("Error", isPresented: .init(get: { dataError != nil }, set: { if !$0 { dataError = nil } })) {
                Button("OK") { dataError = nil }
            } message: {
                Text(dataError ?? "")
            }
            .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importFileURL = url
                        showImportPassphrase = true
                    }
                case .failure(let error):
                    dataError = error.localizedDescription
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(url: url)
                }
            }
            #endif
        }
    }

    // MARK: - Fuel

    private var fuelSection: some View {
        Section {
            Stepper(value: $ethanol, in: 0...85) {
                HStack {
                    Text("Ethanol blend")
                    Spacer()
                    Text("E\(ethanol)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("Fuel")
        } footer: {
            Text("What is in the tank, for the economy shown on each trip. The car's fuel rate is not read, so economy is estimated from airflow, and the blend changes the estimate.")
        }
    }

    // MARK: - Dashboard (passkeys)

    private var dashboardSection: some View {
        Section {
            Toggle("Same address as the server", isOn: $dashboard.sameHost)
                .onChange(of: dashboard.sameHost) { _, _ in Task { await dashboard.refresh() } }
            if !dashboard.sameHost {
                TextField("https://dashboard.example.lan", text: $dashboard.typedURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { Task { await dashboard.refresh() } }
            } else if let url = dashboard.url {
                // what "the same" came to, so it can be checked at a glance
                Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary)
            }

            Label(dashboardStatusText, systemImage: dashboardStatusSymbol)
                .font(.subheadline)
                .foregroundStyle(dashboardStatusTone.color)

            #if os(iOS)
            switch dashboard.status {
            case .signedIn:
                Button { showDashboard = true } label: { Label("Open the dashboard", systemImage: "rectangle.on.rectangle") }
            case .signedOut(let passkeys) where passkeys > 0:
                Button { Task { await dashboard.signIn() } } label: { Label("Sign in with a passkey", systemImage: "person.badge.key.fill") }
            default:
                EmptyView()
            }

            if dashboard.url != nil, dashboard.status != .unreachable, dashboard.status != .checking {
                Button {
                    if case .signedOut(let passkeys) = dashboard.status, passkeys == 0 { showDashboardCode = true }
                    else { Task { await dashboard.createPasskey() } }
                } label: { Label("Create a passkey on this iPhone", systemImage: "key.fill") }
            }
            if case .signedIn(let viaTailnet, _, _) = dashboard.status, !viaTailnet {
                Button("Sign out of the dashboard", role: .destructive) { Task { await dashboard.signOut() } }
            }
            #endif

            if dashboard.busy { ProgressView() }
            if let message = dashboard.message {
                Text(message).font(.footnote).foregroundStyle(dashboard.failed ? Color.red : Color.secondary)
            }
        } header: {
            Text("Dashboard")
        } footer: {
            Text("The dashboard is the web page for your server, normally on the same host name. A passkey is your iPhone's own sign-in: Face ID, kept in iCloud Keychain, and the same one Safari uses there. On your tailnet, the dashboard already knows this phone and needs no sign-in.")
        }
        .task(id: syncClient.lanURL) {
            dashboard.serverURL = syncClient.lanURL
            await dashboard.refresh()
        }
        #if os(iOS)
        .sheet(isPresented: $showDashboard) {
            if let url = dashboard.url { DashboardSheet(url: url, cookies: dashboard.sessionCookies) }
        }
        .alert("One-time code", isPresented: $showDashboardCode) {
            SecureField("Code from the server", text: $dashboardCode)
            Button("Create passkey") {
                let code = dashboardCode
                dashboardCode = ""
                Task { await dashboard.createPasskey(code: code) }
            }
            Button("Cancel", role: .cancel) { dashboardCode = "" }
        } message: {
            Text("The very first passkey needs the code in bootstrap-code on the server (sudo cat /var/lib/cairn-ui/bootstrap-code), unless this phone is a tailnet device the dashboard allows.")
        }
        #endif
    }

    private var dashboardStatusText: String {
        switch dashboard.status {
        case .unset: dashboard.addressProblem ?? "Checking\u{2026}"
        case .checking: "Checking\u{2026}"
        case .signedOut(let passkeys): passkeys == 0 ? "No passkey exists yet." : "Not signed in."
        case .signedIn(let viaTailnet, _, _): viaTailnet ? "Signed in: this phone is on your tailnet." : "Signed in with a passkey."
        case .unreachable: "Can't reach the dashboard."
        }
    }

    private var dashboardStatusSymbol: String {
        switch dashboard.status {
        case .signedIn: "checkmark.seal.fill"
        case .unreachable: "wifi.exclamationmark"
        case .signedOut: "lock.fill"
        default: "link"
        }
    }

    private var dashboardStatusTone: Tone {
        switch dashboard.status {
        case .signedIn: .good
        case .unreachable: .bad
        default: .neutral
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private var identitySection: some View {
        switch enrolmentState {
        case .enrolled:
            Section {
                if let identity = enrolledIdentity {
                    LabeledContent("Client ID") {
                        Text(String(identity.clientID.prefix(12)) + "...")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Role") {
                        Text(identity.role.capitalized)
                            .font(.subheadline.weight(.medium))
                    }
                    LabeledContent("Instance") {
                        Text(String(identity.instanceID.prefix(8)) + "...")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Identity")
                }
            } footer: {
                Text("This device is enrolled with the Cairn server. The Secure Enclave key proves identity on every request.")
            }

        case .notEnrolled, .enrolling:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter the invitation code from your server admin to enrol this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Invitation code", text: $invitationCode)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                Button {
                    performEnrolment()
                } label: {
                    HStack {
                        Text("Enrol Device")
                        Spacer()
                        if isEnrolling {
                            ProgressView()
                        }
                    }
                }
                .disabled(invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEnrolling)

                if let error = enrolmentError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                    Text("Identity")
                }
            }

        case .needsReenrolment:
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "key.slash.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set this phone up again")
                            .font(.subheadline.weight(.semibold))
                        Text("This phone's sign-in key is not the one the server knows, so the server refuses it. Scan a new setup QR code from the dashboard's Add a phone page, or reset the identity and enter a new invitation code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Reset Identity", role: .destructive) {
                    showResetIdentity = true
                }
            } header: {
                Text("Identity")
            }

        case .revoked:
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Identity Revoked")
                            .font(.subheadline.weight(.semibold))
                        Text("This device's enrolment has been revoked by the server. Reset identity to re-enrol with a new invitation code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Reset Identity", role: .destructive) {
                    showResetIdentity = true
                }
            } header: {
                Text("Identity")
            }
        }
    }

    private func reloadSetup() {
        lanURL = syncClient.lanURL
        tailnetURL = syncClient.tailnetURL
        loadEnrolmentState()
    }

    private func loadEnrolmentState() {
        guard let service = enrolmentService else { return }
        Task {
            let (state, identity) = await service.loadIdentity()
            enrolmentState = state
            enrolledIdentity = identity
        }
    }

    private func performEnrolment() {
        guard let service = enrolmentService else { return }
        let code = invitationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        let serverURL = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else {
            enrolmentError = "Enter a server URL first"
            return
        }

        isEnrolling = true
        enrolmentError = nil

        Task {
            do {
                let identity = try await DeviceEnrolment.enrol(
                    code: code, serverURL: serverURL, tailnetURL: tailnetURL, service: service
                )
                enrolmentState = .enrolled
                enrolledIdentity = identity
                invitationCode = ""
            } catch {
                enrolmentError = DeviceEnrolment.message(for: error)
            }
            isEnrolling = false
        }
    }

    // MARK: - Admin

    @ViewBuilder
    private var adminSection: some View {
        Section {
            if isLoadingAdmin {
                HStack {
                    ProgressView()
                    Text("Loading…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if adminClients.isEmpty {
                Text("No clients found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(adminClients) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.name ?? String(client.clientID.prefix(12)))
                                .font(.subheadline.weight(.medium))
                            HStack(spacing: 8) {
                                Text(client.role.capitalized)
                                    .font(.caption)
                                if client.isRevoked {
                                    Text("Revoked")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.red)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !client.isRevoked && client.clientID != enrolledIdentity?.clientID {
                            Button("Revoke", role: .destructive) {
                                revokeTarget = client
                                showRevokeConfirm = true
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.purple)
                Text("Administration")
            }
        } footer: {
            Text("Revoking a client disables it on its next request. This cannot be undone.")
        }
        .onAppear { loadAdmin() }
        .confirmationDialog(
            "Revoke \(revokeTarget?.name ?? "client")?",
            isPresented: $showRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let target = revokeTarget {
                    performRevoke(target)
                }
            }
        } message: {
            Text("This client will be unable to authenticate with the server. This cannot be undone.")
        }
    }

    private func loadAdmin() {
        guard let service = enrolmentService,
              enrolledIdentity?.isAdmin == true else { return }
        isLoadingAdmin = true
        Task {
            let signer = await service.makeSigner()
            guard let signer else {
                isLoadingAdmin = false
                return
            }
            let serverURL = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let baseURL = URL(string: serverURL), !serverURL.isEmpty else {
                isLoadingAdmin = false
                return
            }
            let transport = URLSessionTransport(baseURL: baseURL)
            let client = CairnServerClient(transport: transport, signer: signer)
            do {
                adminClients = try await client.listClients()
                isLoadingAdmin = false
            } catch {
                isLoadingAdmin = false
            }
        }
    }

    private func performRevoke(_ target: ClientEntry) {
        guard let service = enrolmentService else { return }
        Task {
            let signer = await service.makeSigner()
            guard let signer else { return }
            let serverURL = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let baseURL = URL(string: serverURL), !serverURL.isEmpty else { return }
            let transport = URLSessionTransport(baseURL: baseURL)
            let client = CairnServerClient(transport: transport, signer: signer)
            do {
                try await client.revokeClient(target.clientID, reason: "revoked from app")
                loadAdmin()
            } catch {
                // silently fail — the list will reflect the actual state on reload
            }
        }
    }

    // MARK: - Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        Section {
            NavigationLink {
                BluetoothSettingsView(session: session)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.body)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bluetooth")
                            .font(.body)
                        Text(session.state.stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        if syncClient.hasServer || showServerSetup {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server address")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("https://cairn.example.lan", text: $lanURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { saveLAN() }
                        .onChange(of: lanURL) { _, _ in saveLAN() }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailscale address (optional)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("https://cairn.ts.net", text: $tailnetURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { saveTailnet() }
                        .onChange(of: tailnetURL) { _, _ in saveTailnet() }
                }

                if syncClient.hasServer {
                    Button {
                        syncClient.sync()
                    } label: {
                        HStack {
                            Text("Sync Now")
                            Spacer()
                            if syncClient.state == .syncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncClient.state == .syncing)
                }
            } header: {
                Text("Cairn Server")
            } footer: {
                Text("One server, so one address. The Tailscale address is only for when you are away from home: it is used when the first one cannot be reached. A setup QR code fills both in for you.")
            }
        } else {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Standalone Mode")
                            .font(.subheadline.weight(.semibold))
                        Text("All features work offline. Connect a server to sync trip data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    showServerSetup = true
                } label: {
                    Label("Connect to Server", systemImage: "link")
                }
            } header: {
                Text("Server")
            }
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            HStack {
                Text("Active Route")
                Spacer()
                routeBadge(syncClient.activeRoute)
            }

            if let lan = syncClient.lastLANProbe {
                probeRow("LAN", probe: lan)
            }

            if let tailnet = syncClient.lastTailnetProbe {
                probeRow("Tailnet", probe: tailnet)
            }

            Button {
                isProbing = true
                Task {
                    await syncClient.probeEndpoints()
                    isProbing = false
                }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isProbing {
                        ProgressView()
                    }
                }
            }
            .disabled(isProbing)
        } header: {
            Text("Diagnostics")
        }
    }

    @ViewBuilder
    private func routeBadge(_ route: TripSyncClient.Route) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(routeColor(route))
                .frame(width: 7, height: 7)
            Text(route.rawValue)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(routeColor(route))
        }
    }

    private func routeColor(_ route: TripSyncClient.Route) -> Color {
        switch route {
        case .lan: .green
        case .tailnet: .blue
        case .unreachable: .red
        }
    }

    @ViewBuilder
    private func probeRow(_ label: String, probe: TripSyncClient.ProbeResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                if let error = probe.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("\(probe.latencyMs) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if probe.error == nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Sync Status

    @ViewBuilder
    private var syncStatusSection: some View {
        Section("Sync Status") {
            if let manifest = syncClient.manifest {
                LabeledContent("Trips", value: "\(manifest.tripCount)")
                LabeledContent("Bundles", value: "\(manifest.bundleCount)")
                LabeledContent("Total rows", value: formattedCount(manifest.totalRows))
                LabeledContent("Server built") {
                    Text(manifest.builtAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Schema", value: "v\(manifest.schemaVersion)")
            }

            if let lastSync = syncClient.lastSyncAt {
                LabeledContent("Last synced") {
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Last synced", value: "Never")
            }

            switch syncClient.state {
            case .idle: EmptyView()
            case .syncing:
                HStack {
                    ProgressView()
                    Text("Syncing...").foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Data

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button {
                showExportSheet = true
            } label: {
                HStack {
                    Label("Export Data", systemImage: "square.and.arrow.up")
                    Spacer()
                    if isExporting { ProgressView() }
                }
            }
            .disabled(isExporting)

            Button {
                showImportPicker = true
            } label: {
                HStack {
                    Label("Import Data", systemImage: "square.and.arrow.down")
                    Spacer()
                    if isImporting { ProgressView() }
                }
            }
            .disabled(isImporting)
        } header: {
            Text("Data")
        } footer: {
            Text("Export creates an encrypted .cairnbackup file containing vehicles, maintenance, odometer readings, and annotations. Drive sessions are not included — they re-sync from the server.")
        }
    }

    private func performExport() {
        guard !exportPassphrase.isEmpty else {
            dataError = "Passphrase cannot be empty"
            return
        }
        isExporting = true
        let passphrase = exportPassphrase
        exportPassphrase = ""
        Task {
            do {
                let data = try await dataPorter.exportData(passphrase: passphrase)
                let fileName = "cairn-backup-\(Self.dateStamp()).cairnbackup"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: tempURL)
                exportedFileURL = tempURL
                isExporting = false
                #if os(iOS)
                showShareSheet = true
                #else
                dataMessage = "Exported to \(tempURL.lastPathComponent)"
                #endif
            } catch {
                isExporting = false
                dataError = error.localizedDescription
            }
        }
    }

    private func performImport() {
        guard let url = importFileURL else { return }
        guard !importPassphrase.isEmpty else {
            dataError = "Passphrase cannot be empty"
            return
        }
        isImporting = true
        let passphrase = importPassphrase
        importPassphrase = ""
        Task {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let summary = try await dataPorter.importData(data, passphrase: passphrase)
                isImporting = false
                importFileURL = nil
                dataMessage = "Imported \(summary.vehicles) vehicles, \(summary.maintenance) maintenance entries, \(summary.odometer) odometer readings, \(summary.annotations) annotations"
            } catch {
                isImporting = false
                importFileURL = nil
                dataError = error.localizedDescription
            }
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        let build = BuildIdentity.current
        Section {
            LabeledContent("App", value: "Cairn Companion")
            LabeledContent("Version", value: build.version)
            LabeledContent("Build", value: build.build)
            LabeledContent("Channel", value: build.channel.title)
            if let commit = build.commit {
                LabeledContent("Commit", value: commit)
            }
        } header: {
            Text("About")
        } footer: {
            if let notice = build.channel.notice {
                Text(notice)
            }
        }
    }

    // MARK: - Danger Zone

    @ViewBuilder
    private var dangerZone: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete All History", systemImage: "trash")
            }
            .confirmationDialog("Delete all drive history?", isPresented: $showDeleteConfirm) {
                Button("Delete All", role: .destructive) {
                    Task {
                        try? await session.recorder.deleteAllSessions()
                    }
                }
            } message: {
                Text("This removes all phone-recorded sessions. Server data will re-sync on next download.")
            }

            Button {
                session.forgetDongle()
            } label: {
                Label("Forget Dongle", systemImage: "minus.circle")
                    .foregroundStyle(.red)
            }

            if enrolmentService != nil && enrolmentState != .notEnrolled && enrolmentState != .enrolling {
                Button(role: .destructive) {
                    showResetIdentity = true
                } label: {
                    Label("Reset Identity", systemImage: "person.crop.circle.badge.minus")
                }
            }
        } header: {
            Text("Danger Zone")
        }
    }

    private func saveLAN() {
        syncClient.lanURL = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveTailnet() {
        syncClient.tailnetURL = tailnetURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetIdentity() {
        guard let service = enrolmentService else { return }
        Task {
            do {
                try await service.reset()
            } catch {
                // The enrolment is cleared before the key is replaced, so this phone can enrol
                // again either way; say that the key could not be replaced.
                enrolmentError = "The identity was cleared, but the key could not be replaced: \(error.localizedDescription)"
            }
            let (state, identity) = await service.loadIdentity()
            enrolmentState = state
            enrolledIdentity = identity
        }
    }

    private func formattedCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000)
    }
}

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif


/// "Trips on the dongle": what the phone is carrying to the server, and a button to do it now.
private struct OffloadSection: View {
    let offload: OffloadController

    var body: some View {
        Section {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if offload.isRunning, let p = offload.progress, case .uploading(let chunk, let total) = p.phase {
                ProgressView(value: Double(chunk), total: Double(max(total, 1)))
            }
            Button {
                offload.offloadNow()
            } label: {
                Label(offload.isRunning ? "Carrying trips…" : "Offload trips now", systemImage: "arrow.down.circle")
            }
            .disabled(offload.isRunning || !offload.canOffload)
        } header: {
            Text("Trips on the dongle")
        } footer: {
            Text("The dongle keeps each trip until the server confirms it has it. If the dongle uploads some trips on its own, the phone only carries what is left.")
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch offload.status {
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsAttention: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "externaldrive").foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        switch offload.status {
        case .idle: offload.canOffload ? "Ready to carry trips" : "Not connected"
        case .running(let text), .finished(let text), .needsAttention(let text): text
        }
    }

    private var detail: String {
        if !offload.canOffload && offload.status == .idle {
            return "Connect to the dongle with the server set up to carry its trips."
        }
        guard let when = offload.lastRunAt else { return "Hasn't run yet." }
        return "Last run \(when.formatted(.relative(presentation: .named)))."
    }
}
