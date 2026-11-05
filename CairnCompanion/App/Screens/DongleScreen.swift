import CairnKit
import CairnProtocol
import SwiftUI

/// What the link is doing, and why it is not doing better.
///
/// Decision D6: diagnostics are the first interface. Firmware
/// [#44](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/44) has been open
/// since 2026-10-10 waiting for a second central to settle whether the Mac's `bluetoothd` or the
/// dongle is at fault, and "it did not pair" is not an answer. So this screen shows the state,
/// the signal, the write length, the firmware version, the capability bits and the last error
/// **with the number the radio gave it** — and exports the lot.
struct DongleScreen: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()
    @State private var sharing: SharePayload?

    private var link: LinkSupervisor { model.link }

    var body: some View {
        NavigationStack {
            List {
                stateSection
                if let advice = link.advice { adviceSection(advice) }
                if let ready = link.ready { dongleSection(ready) } else { signalSection }
                if !link.subscriptionFailures.isEmpty { subscriptionSection }
                controlsSection
                logSection
            }
            .navigationTitle("Dongle")
            .animation(.default, value: link.state)
            // A one-second heartbeat, so "time in state" and the freshness of each notify
            // channel are live. Nothing in the link depends on it: the machine's own deadlines
            // are scheduled exactly, by the clock it was given.
            .task {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .sheet(item: $sharing) { payload in
                ShareSheet(items: [payload.url])
            }
        }
    }

    // MARK: - Sections

    private var stateSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(tone)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.state.title)
                        .font(.headline)
                    if let interval = link.timeInState(now: now) {
                        Text("for \(LinkHealth.ageLabel(interval))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if link.attempt > 0, !link.state.isReady {
                    Text("attempt \(link.attempt)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = link.state.failure {
                // The exact code, on the screen, not only in the log. A bench run has to be able
                // to quote it, and so does an issue.
                LabeledContent("Last error") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(failure.shortCode).font(.caption.monospaced())
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        } header: {
            Text("Link")
        }
    }

    private func adviceSection(_ advice: String) -> some View {
        Section {
            Text(advice).font(.callout)
        }
    }

    private func dongleSection(_ ready: LinkReady) -> some View {
        Section("This dongle") {
            LabeledContent("Name", value: ready.peripheral.name ?? CairnGATT.advertisedName)
            LabeledContent("Identifier", value: ready.peripheral.short)
                .font(.body.monospaced())
            if let rssi = link.lastRSSI {
                LabeledContent("Signal", value: "\(rssi) dBm")
            }
            LabeledContent("Writes", value: "\(ready.writeLength) B")
            LabeledContent("Protocol", value: "v\(ready.version.version)")
            LabeledContent("Capabilities") {
                Text(ready.version.capabilities.titles.isEmpty
                     ? "none" : ready.version.capabilities.titles.joined(separator: ", "))
                .font(.caption.monospaced())
            }
            if let firmware = ready.deviceInfo?.firmware {
                LabeledContent("Firmware", value: "\(firmware.major).\(firmware.minor).\(firmware.patch)")
            }
            // Which of the contract's characteristics this firmware actually has. The bits alone
            // are not enough: the old app believed the offload bit while the two offload
            // characteristics were missing from its discovery list.
            DisclosureGroup("Characteristics (\(ready.present.count))") {
                ForEach(CairnGATT.Characteristic.allCases, id: \.self) { characteristic in
                    HStack {
                        Image(systemName: ready.has(characteristic) ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(ready.has(characteristic) ? Color.green : Color.secondary)
                        Text(characteristic.title).font(.caption.monospaced())
                        Spacer()
                        if let heard = link.machine.lastNotified[characteristic] {
                            Text(LinkHealth.ageLabel(now.timeIntervalSince(heard)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var signalSection: some View {
        Section("Signal") {
            if let rssi = link.lastRSSI {
                LabeledContent("Last heard", value: "\(rssi) dBm")
            } else {
                Text("The dongle has not been heard yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subscriptionSection: some View {
        Section("Subscriptions that failed") {
            ForEach(link.subscriptionFailures.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) { pair in
                LabeledContent(pair.key.title) {
                    Text(pair.value.shortCode).font(.caption.monospaced())
                }
            }
        }
    }

    private var controlsSection: some View {
        Section {
            Button("Retry", systemImage: "arrow.clockwise") { link.retry() }
            Button("Forget This Dongle", systemImage: "minus.circle") { link.forget() }
            Button("Export Log", systemImage: "square.and.arrow.up") { share() }
        } footer: {
            Text("Forget drops the dongle this phone remembers and looks again. It cannot delete "
                 + "the iOS pairing — that one is in Settings › Bluetooth.")
        }
    }

    private var logSection: some View {
        Section {
            let entries = link.log.recent(40)
            if entries.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.state)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .leading)
                        Text(entry.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(entry.kind == .failure ? Color.red : Color.primary)
                    }
                }
            }
        } header: {
            Text("Link log")
        } footer: {
            Text("The last 40 lines, newest first. Export Log writes the whole ring oldest "
                 + "first, with this build and this dongle named at the top, which is the form "
                 + "a bench record wants.")
        }
    }

    private var tone: Color {
        switch link.state {
        case .ready: .green
        case .scanning, .connecting, .discovering, .securing: .orange
        case .needsForget: .red
        case .backoff: .yellow
        case .off, .idle: .secondary
        }
    }

    private func share() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-link-\(Int(Date().timeIntervalSince1970)).txt")
        try? Data(model.exportText().utf8).write(to: url)
        sharing = SharePayload(url: url)
    }
}

struct SharePayload: Identifiable {
    let url: URL
    var id: URL { url }
}

/// `UIActivityViewController` as a sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
