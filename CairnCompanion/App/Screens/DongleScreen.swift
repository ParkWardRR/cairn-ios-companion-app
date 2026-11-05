import SwiftUI

/// What the link is doing, and why it is not doing better.
///
/// Empty at R0 on purpose: the scaffold lands first and green, then R1 fills this in with the
/// state, the RSSI, the MTU, the firmware version, the capability bits, the last error with its
/// numeric code, and Retry / Forget / Export Log.
struct DongleScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No link yet", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("The link layer arrives in R1. This screen will show what the radio saw: "
                     + "state, signal, MTU, firmware version and the last error's own code.")
            }
            .navigationTitle("Dongle")
        }
    }
}

#Preview {
    DongleScreen()
}
