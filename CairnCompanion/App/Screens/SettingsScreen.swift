import CairnKit
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
        }
    }
}

