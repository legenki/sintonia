import SwiftUI
import SintoniaExport

/// Hybrid macOS desktop app entry exposing singleton Player, Library, and Studio Rack windows,
/// live MenuBarExtra status/controls, native keyboard commands, and `.bwg`/`.sintonia` file opening.
@main
struct SintoniaMacApp: App {
    @State private var coordinator = MacAppCoordinator()

    init() {
        SessionExporter.cleanupStaleTemporaryExports()
    }

    var body: some Scene {
        Window(Text("Sintonia"), id: SintoniaWindowID.player) {
            MacPlayerWindowView(coordinator: coordinator)
                .onOpenURL { url in
                    coordinator.handleIncomingURLs([url], source: .external)
                }
        }
        .defaultSize(width: 430, height: 700)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            MacCommands(coordinator: coordinator)
        }

        Window(Text("Library"), id: SintoniaWindowID.library) {
            MacLibraryWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 780, height: 640)
        .windowResizability(.contentMinSize)

        Window(Text("Studio Rack"), id: SintoniaWindowID.studio) {
            MacStudioWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 1160, height: 740)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MacMenuBarView(coordinator: coordinator)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                if coordinator.engine.isPlaying {
                    Text(verbatim: StudioTheme.formatFrequency(coordinator.engine.dominantBeatHz))
                        .font(.caption.monospacedDigit())
                }
            }
            .accessibilityLabel(Text("Sintonia"))
        }
        .menuBarExtraStyle(.window)
    }
}
