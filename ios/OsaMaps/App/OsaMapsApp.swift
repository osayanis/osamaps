import SwiftUI

@main
struct OsaMapsApp: App {
    init() {
        MainActor.assumeIsolated {
            Registry.register(allFeatures)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Core.shared)
                .environment(Prefs.shared)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}
