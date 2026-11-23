import SwiftUI

/// Minimal macOS `@main` entry scaffold; full multi-window scenes and commands are wired in Task 5.
@main
struct WaveForgeMacApp: App {
    @State private var coordinator = MacAppCoordinator()

    var body: some Scene {
        Window(Text("WaveForge"), id: "player") {
            PlayerView(engine: coordinator.engine)
                .preferredColorScheme(.dark)
        }
    }
}
