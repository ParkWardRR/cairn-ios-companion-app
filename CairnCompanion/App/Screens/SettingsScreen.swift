import CairnKit
import CairnRuntime
import SwiftUI

/// What this build is, and the log it wrote.
///
/// A release process cannot ship what cannot identify itself, so every Cairn component answers
/// the same question: version, build number, channel and commit. The build number is derived
/// from `git rev-list --count HEAD` by `scripts/release-testflight.sh` and never typed by hand —
/// the old app had 12 in `project.yml` and 13 in the pbxproj at the same time.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var resetting = false

    var body: some View {
        NavigationStack {
            List {
                Section("This build") {
                    LabeledContent("Version", value: model.build.shortDescription)
                    LabeledContent("Channel", value: model.build.channel.title)
                    LabeledContent("Commit", value: model.build.commit ?? "not stamped")
                }

                if let notice = model.build.channel.notice {
                    Section {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Server") {
                    LabeledContent("This phone", value: model.server.statusLine)
                    if let identity = model.server.identity {
                        LabeledContent("Client id") {
                            Text(identity.clientID).font(.caption.monospaced())
                        }
                        if let pin = PinnedCA.pinFingerprint {
                            LabeledContent("Certificate pin") {
                                Text(pin).font(.caption.monospaced())
                            }
                        }
                        Button("Forget This Server", systemImage: "trash", role: .destructive) {
                            resetting = true
                        }
                    }
                }

                Section {
                    Button("Export Log", systemImage: "square.and.arrow.up") {
                        model.driveLog.flush()
                        exporting = true
                    }
                } footer: {
                    Text("Every link transition this build has written, with its timestamp and "
                         + "its error code, across relaunches. It is also in the Files app under "
                         + "On My iPhone › Cairn. The Dongle screen's Export Log is the current "
                         + "link only, with the dongle named at the top.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $exporting) {
                ShareSheet(items: [model.driveLog.fileURL])
            }
            .confirmationDialog(
                "Forget this server?", isPresented: $resetting, titleVisibility: .visible
            ) {
                Button("Forget It", role: .destructive) {
                    Task { try? await model.server.reset() }
                }
            } message: {
                // Worth being exact about: the phone's key is replaced, so the server's record
                // of this client is dead and enrolling again needs a fresh invitation. Nothing
                // on the dongle or the server is touched, and no trip is lost.
                Text("This phone's signing key is replaced and its enrolment forgotten, so "
                     + "setting it up again needs a new invitation code. Nothing on the dongle "
                     + "or the server is deleted.")
            }
        }
    }
}

