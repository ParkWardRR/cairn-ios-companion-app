import SwiftUI

/// Two tabs, because there are two things to look at: the dongle, and this build.
///
/// D6: diagnostics are the first interface. Firmware #44 has been open since 2026-10-10 waiting
/// for a second central to say what it saw, and the phone is that central — so the first screen
/// the app ever had is the one that can answer it.
struct RootScreen: View {
    var body: some View {
        TabView {
            Tab("Dongle", systemImage: "dot.radiowaves.left.and.right") {
                DongleScreen()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsScreen()
            }
        }
    }
}
