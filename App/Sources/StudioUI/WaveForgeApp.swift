import PresetKit
import SwiftUI
import SynthCore

@main
struct WaveForgeApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 12) {
                    Text("WaveForge")
                        .font(.largeTitle.bold())
                    Text("Binaural & Isochronic Sound Studio")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .navigationTitle("WaveForge")
            }
        }
    }
}
