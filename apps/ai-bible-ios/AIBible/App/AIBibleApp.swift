import SwiftUI

@main
struct AIBibleApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.entitlements.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flush() }
        }
    }
}
