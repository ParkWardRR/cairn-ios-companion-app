import CairnKit
import CairnRuntime
import SwiftUI

/// The whole app: one model, two screens.
///
/// There is deliberately no dependency graph to read here. The audit's finding was that the old
/// app's failures all lived in glue that no test could reach, so everything with a decision in it
/// is in `CairnKit` behind a protocol, and this file only names which adapter is real.
@main
struct CairnCompanionApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootScreen()
                .environment(model)
        }
    }
}
