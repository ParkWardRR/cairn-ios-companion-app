import AVFoundation
import CairnKit
import CairnProtocol
import CairnRuntime
import SwiftUI

/// Setting the phone up with a server: scan the QR code, read what it says, agree.
///
/// The link arrives from outside the app — a camera, a message, anything — so it is untrusted
/// input. It fills in this sheet and **nothing is saved or sent until the person agrees**, with
/// the server's addresses and its certificate's fingerprint in front of them. The invitation
/// code is single-use and expires in ten minutes (`sync/v1` §3), so a sheet left open is a
/// sheet that will fail, which is the right way round.
struct EnrolmentScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var link: ConfigureLink?
    @State private var parseProblem: String?
    @State private var working = false
    @State private var failure: String?
    @State private var scanning = false

    private var session: ServerSession { model.server }

    var body: some View {
        NavigationStack {
            List {
                if let link {
                    confirmation(link)
                } else {
                    entry
                }
            }
            .navigationTitle("Set up a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $scanning) {
                QRScannerSheet { scanned in
                    scanning = false
                    accept(scanned)
                }
            }
        }
    }

    // MARK: - Entry

    private var entry: some View {
        Group {
            Section {
                Button("Scan the QR code", systemImage: "qrcode.viewfinder") { scanning = true }
            } footer: {
                Text("Your server's administrator runs `cairn-admin client invite` and shows you "
                     + "a code. It works once and expires in ten minutes.")
            }

            Section("Or paste the link") {
                TextField("cairn://configure?…", text: $pasted, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                Button("Continue") { accept(pasted) }
                    .disabled(pasted.isEmpty)
            }

            if let parseProblem {
                Section {
                    Text(parseProblem).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Confirmation

    private func confirmation(_ link: ConfigureLink) -> some View {
        Group {
            Section("This server") {
                LabeledContent("On your network", value: link.serverHost)
                if !link.tailnetURL.isEmpty {
                    LabeledContent("Over Tailscale", value: URL(string: link.tailnetURL)?.host ?? link.tailnetURL)
                }
                LabeledContent("Certificate") {
                    Text(link.caCertificateDER == nil ? "none in the link" : "its own, in the link")
                        .foregroundStyle(link.caCertificateDER == nil ? .red : .secondary)
                }
            }

            Section {
                Button(working ? "Setting up…" : "Set This Phone Up") { enrol(link) }
                    .disabled(working)
                Button("Back", role: .cancel) { self.link = nil }
            } footer: {
                Text("This phone makes a signing key in its Secure Enclave and registers it. "
                     + "The key never leaves the phone, and nothing it sends is readable by "
                     + "anyone but your server. Your trips stay sealed either way: the phone "
                     + "carries bundles it cannot open.")
            }

            if let failure {
                Section {
                    Text(failure).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Actions

    private func accept(_ text: String) {
        parseProblem = nil
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            parseProblem = "That does not look like a link."
            return
        }
        do {
            link = try ConfigureLink.parse(url)
        } catch let error as ConfigureLink.ParseError {
            parseProblem = Self.explain(error)
        } catch {
            parseProblem = "That link could not be read."
        }
    }

    private func enrol(_ link: ConfigureLink) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                // The CA and the host go in first: the enrolment request itself is the first
                // thing that has to reach the server over TLS, so the trust anchor has to be
                // there before it. The pin arrives in the answer and is stored after.
                if let der = link.caCertificateDER { try PinnedCA.save(der: der) }
                let identity = try await session.enrol(link, deviceName: UIDevice.current.name)
                if let host = URL(string: link.serverURL)?.host {
                    try PinnedCA.save(spkiSHA256: identity.spkiSHA256, forHost: host)
                }
                await session.chooseRoute(force: true)
                dismiss()
            } catch {
                failure = Self.explain(error)
                PinnedCA.clear()
            }
        }
    }

    private static func explain(_ error: ConfigureLink.ParseError) -> String {
        switch error {
        case .notAConfigureLink: "That is not a Cairn setup link."
        case .unsupportedVersion: "That link was made by a newer server than this app knows."
        case .invalidServerURL: "The server address in that link is not an https:// one."
        case .invalidTailnetURL: "The Tailscale address in that link is not an https:// one."
        case .missingInvitationCode: "That link has no invitation code in it."
        case .malformedCertificate: "The certificate in that link is not one."
        }
    }

    private static func explain(_ error: Error) -> String {
        guard let error = error as? CairnServerError else { return "Setting up failed." }
        switch error {
        case .transport(.offline): return "The server could not be reached from here."
        case .transport(.timedOut): return "The server did not answer."
        case .transport(.tls):
            return "This phone does not trust the server's certificate. If the link had no "
                + "certificate in it, ask for one that does."
        case .forbidden(.enrolmentRefused), .notFound:
            return "That invitation code has already been used, or it expired. Ask for another."
        case .unauthenticated:
            return "The server did not accept the invitation code."
        default:
            return "The server answered \(error.httpStatus.map(String.init) ?? "with an error")."
        }
    }
}

/// The camera, looking for one `cairn://configure` link and stopping.
private struct QRScannerSheet: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !done,
                  let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let value = code.stringValue,
                  value.lowercased().hasPrefix("cairn://") else { return }
            done = true
            found(value)
        }
    }

    final class ScannerController: UIViewController {
        private let session = AVCaptureSession()
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)

            // `startRunning` blocks, so it must not be on the main thread; the session itself
            // is safe to touch from another one.
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            session.stopRunning()
        }
    }
}
