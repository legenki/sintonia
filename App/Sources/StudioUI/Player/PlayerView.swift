import PresetKit
import SwiftUI
import SynthCore
import UIKit
import WaveForgeExport

/// Simplified primary player screen featuring an iOS 27 Liquid Glass header & transport bar,
/// live oscilloscope + sparkline timeline scrubber, and 4 GarageBand Smart Control knobs.
public struct PlayerView: View {
    private let engine: AudioEngineController
    private let onOpenLibrary: () -> Void
    private let onOpenStudio: () -> Void

    @State private var isShowingExportSheet = false
    @State private var isShowingAboutSheet = false
    @State private var dismissedSpeakerNotice = false
    @State private var transportHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stepHaptic = UIImpactFeedbackGenerator(style: .light)

    public init(
        engine: AudioEngineController,
        onOpenLibrary: @escaping () -> Void = {},
        onOpenStudio: @escaping () -> Void = {}
    ) {
        self.engine = engine
        self.onOpenLibrary = onOpenLibrary
        self.onOpenStudio = onOpenStudio
    }

    private var accentColor: Color {
        engine.dominantBand.accentColor
    }

    private var activeVoiceCount: Int {
        let voices = engine.currentPreset.voices.prefix(SynthSnapshot.maxVoices)
        let hasSolo = voices.contains { $0.isEnabled && $0.isSolo }
        return voices.filter { $0.isEnabled && !$0.isMuted && (!hasSolo || $0.isSolo) }.count
    }

    private var shouldShowSpeakerNotice: Bool {
        !engine.showHeadphoneBanner
            && !dismissedSpeakerNotice
            && engine.presetHasActiveBinaural
            && engine.outputRoute == .speaker
    }

    public var body: some View {
        ZStack {
            StudioTheme.rackBackgroundGradient
                .ignoresSafeArea()

            // Subtle ambient radial glow matching current brainwave band
            RadialGradient(
                colors: [
                    accentColor.opacity(engine.isPlaying ? 0.14 : 0.06),
                    Color.clear
                ],
                center: .top,
                startRadius: 20,
                endRadius: 380
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.45), value: engine.dominantBand)
            .animation(.easeInOut(duration: 0.35), value: engine.isPlaying)

            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        topGlassBar

                        if engine.showHeadphoneBanner {
                            headphoneDisconnectedBanner
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else if shouldShowSpeakerNotice {
                            speakerRecommendationBanner
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let errorMessage = engine.lastErrorMessage {
                            errorBanner(message: errorMessage)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        oscilloscopeAndTimelineCard

                        smartControlsRack

                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(minHeight: proxy.size.height)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            floatingTransportBar
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: engine.showHeadphoneBanner)
        .animation(.easeInOut(duration: 0.22), value: shouldShowSpeakerNotice)
        .animation(.easeInOut(duration: 0.22), value: engine.lastErrorMessage != nil)
        .onChange(of: engine.currentPreset.id) { _, _ in
            dismissedSpeakerNotice = false
        }
        .onChange(of: engine.outputRoute) { _, newRoute in
            if newRoute == .headphones {
                dismissedSpeakerNotice = false
            }
        }
        .sheet(isPresented: $isShowingExportSheet) {
            ExportSheetView(preset: engine.currentPreset, accentColor: accentColor)
        }
        .sheet(isPresented: $isShowingAboutSheet) {
            AboutSheetView(accentColor: accentColor)
        }
    }

    // MARK: - Top Liquid Glass Bar

    private var topGlassBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onOpenLibrary) {
                    Image(systemName: "books.vertical.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Library"))

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: engine.currentPreset.name)
                        .font(.headline)
                        .foregroundStyle(StudioTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(categoryTitleKey(for: engine.currentPreset.category))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Button(action: onOpenStudio) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 5) {
                                Image(systemName: "slider.horizontal.3")
                                Text("Studio")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioTheme.primaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(Capsule().fill(accentColor.opacity(0.22)))
                            .overlay(Capsule().strokeBorder(accentColor.opacity(0.5), lineWidth: 0.85))

                            Image(systemName: "slider.horizontal.3")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(StudioTheme.primaryText)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(accentColor.opacity(0.22)))
                                .overlay(Circle().strokeBorder(accentColor.opacity(0.5), lineWidth: 0.85))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Studio"))

                    Button {
                        isShowingExportSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.primaryText)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Export"))

                    Button {
                        isShowingAboutSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.secondaryText)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("About"))
                }
            }

            HStack(spacing: 8) {
                BrainwaveBandBadge(
                    band: engine.dominantBand,
                    beatHz: engine.dominantBeatHz,
                    compact: false
                )

                Spacer(minLength: 4)

                outputRoutePill
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .studioGlassSurface(cornerRadius: 20, tint: accentColor.opacity(0.12), interactive: true)
    }

    private var outputRoutePill: some View {
        let isWarning = engine.presetHasActiveBinaural && engine.outputRoute == .speaker
        let iconName: String = switch engine.outputRoute {
        case .headphones:
            "headphones"
        case .speaker:
            isWarning ? "speaker.wave.2.fill" : "speaker.wave.2"
        case .other:
            engine.presetHasActiveBinaural ? "headphones" : "hifispeaker"
        }

        let labelKey: LocalizedStringKey = switch engine.outputRoute {
        case .headphones:
            "Headphones"
        case .speaker:
            isWarning ? "Headphones Recommended" : "Speaker"
        case .other:
            engine.presetHasActiveBinaural ? "Headphones Recommended" : "Any Output"
        }

        let pillColor: Color = if isWarning {
            StudioTheme.betaColor
        } else if engine.outputRoute == .headphones {
            StudioTheme.alphaColor
        } else {
            StudioTheme.secondaryText
        }

        return HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(pillColor)
            Text(labelKey)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isWarning ? StudioTheme.primaryText : StudioTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(isWarning ? StudioTheme.betaColor.opacity(0.18) : Color.white.opacity(0.06))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    isWarning ? StudioTheme.betaColor.opacity(0.55) : StudioTheme.hairlineHighlight,
                    lineWidth: 0.75
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Audio Output"))
        .accessibilityValue(Text(labelKey))
    }

    // MARK: - Route & Error Banners

    private var headphoneDisconnectedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "headphones.slash")
                .font(.headline)
                .foregroundStyle(StudioTheme.betaColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Headphones Disconnected")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.primaryText)
                Text("Binaural playback was automatically paused because headphones were disconnected.")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                engine.dismissHeadphoneBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(12)
        .studioGlassSurface(cornerRadius: 16, tint: StudioTheme.betaColor.opacity(0.22), interactive: true)
    }

    private var speakerRecommendationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "headphones")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.betaColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Headphones Recommended")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.primaryText)
                Text("Binaural voices work best with stereo headphones; speaker playback reduces the binaural effect.")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                dismissedSpeakerNotice = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(12)
        .studioGlassSurface(cornerRadius: 16, tint: StudioTheme.betaColor.opacity(0.14), interactive: true)
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.ledRed)
                .padding(.top, 1)

            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(StudioTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                engine.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(12)
        .studioRackCard(cornerRadius: 14, borderColor: StudioTheme.ledRed.opacity(0.5))
    }

    // MARK: - Oscilloscope & Mini Timeline

    private var oscilloscopeAndTimelineCard: some View {
        VStack(spacing: 12) {
            OscilloscopeView(
                telemetryBuffer: engine.telemetryBuffer,
                dominantBeatHz: engine.dominantBeatHz,
                dominantBand: engine.dominantBand,
                activeVoiceCount: activeVoiceCount,
                isPlaying: engine.isPlaying
            )
            .frame(minHeight: 168, idealHeight: 210, maxHeight: 250)

            MiniTimelineScrubber(engine: engine)
        }
        .padding(12)
        .studioRackCard(cornerRadius: 20)
    }

    // MARK: - Smart Controls Rack

    private var smartControlsRack: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Smart Controls")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textCase(.uppercase)

                Spacer(minLength: 8)

                if engine.liveOverrides != .identity {
                    Button {
                        stepHaptic.prepare()
                        engine.updateOverrides(.identity)
                        stepHaptic.impactOccurred(intensity: 0.65)
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(accentColor.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 4) {
                StudioKnob(
                    value: masterBinding,
                    range: 0.0...1.0,
                    defaultValue: 1.0,
                    title: "Master",
                    valueFormatter: formatGainPercent,
                    accentColor: accentColor,
                    size: 56
                )
                .frame(maxWidth: .infinity)

                StudioKnob(
                    value: tonesBinding,
                    range: 0.0...2.0,
                    defaultValue: 1.0,
                    title: "Tones",
                    valueFormatter: formatGainPercent,
                    accentColor: StudioTheme.alphaColor,
                    size: 56
                )
                .frame(maxWidth: .infinity)

                StudioKnob(
                    value: noiseBinding,
                    range: 0.0...2.0,
                    defaultValue: 1.0,
                    title: "Noise",
                    valueFormatter: formatGainPercent,
                    accentColor: StudioTheme.thetaColor,
                    size: 56
                )
                .frame(maxWidth: .infinity)

                StudioKnob(
                    value: noiseColorBinding,
                    range: -1.0...1.0,
                    defaultValue: 0.0,
                    title: "Noise Color",
                    valueFormatter: formatNoiseColorOffset,
                    accentColor: StudioTheme.betaColor,
                    size: 56
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .studioRackCard(cornerRadius: 20)
    }

    // MARK: - Floating Liquid Glass Transport Bar

    private var floatingTransportBar: some View {
        HStack(spacing: 22) {
            Button {
                stepHaptic.prepare()
                engine.skip(by: -30.0)
                stepHaptic.impactOccurred(intensity: 0.55)
            } label: {
                Image(systemName: "gobackward.30")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skip Back 30s"))

            Button {
                transportHaptic.prepare()
                engine.togglePlayPause()
                transportHaptic.impactOccurred(intensity: 0.8)
            } label: {
                ZStack {
                    Circle()
                        .fill(accentColor)
                        .shadow(color: accentColor.opacity(engine.isPlaying ? 0.6 : 0.35), radius: 10)

                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(StudioTheme.chassisGraphite)
                        .offset(x: engine.isPlaying ? 0 : 1.5)
                }
                .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(engine.isPlaying ? "Pause" : "Play"))

            Button {
                stepHaptic.prepare()
                engine.skip(by: 30.0)
                stepHaptic.impactOccurred(intensity: 0.55)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skip Forward 30s"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .studioGlassCapsule(tint: accentColor.opacity(0.14), interactive: true)
        .shadow(color: StudioTheme.hardwareShadow, radius: 14, x: 0, y: 8)
    }

    // MARK: - Live Override Bindings & Formatters

    private var masterBinding: Binding<Double> {
        Binding(
            get: { engine.liveOverrides.masterGain },
            set: { newValue in
                var updated = engine.liveOverrides
                updated.masterGain = newValue
                engine.updateOverrides(updated)
            }
        )
    }

    private var tonesBinding: Binding<Double> {
        Binding(
            get: { engine.liveOverrides.tonesGain },
            set: { newValue in
                var updated = engine.liveOverrides
                updated.tonesGain = newValue
                engine.updateOverrides(updated)
            }
        )
    }

    private var noiseBinding: Binding<Double> {
        Binding(
            get: { engine.liveOverrides.noiseGain },
            set: { newValue in
                var updated = engine.liveOverrides
                updated.noiseGain = newValue
                engine.updateOverrides(updated)
            }
        )
    }

    private var noiseColorBinding: Binding<Double> {
        Binding(
            get: { engine.liveOverrides.noiseSmoothnessOffset },
            set: { newValue in
                var updated = engine.liveOverrides
                updated.noiseSmoothnessOffset = newValue
                engine.updateOverrides(updated)
            }
        )
    }

    private func formatGainPercent(_ value: Double) -> String {
        guard value.isFinite else { return "100%" }
        return String(format: "%.0f%%", max(0.0, value) * 100.0)
    }

    private func formatNoiseColorOffset(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        let pct = Int((value * 100.0).rounded())
        if pct == 0 {
            return "0%"
        }
        return String(format: "%+d%%", pct)
    }

    private func categoryTitleKey(for category: PresetCategory) -> LocalizedStringKey {
        switch category {
        case .focus: return "Focus"
        case .relax: return "Relax"
        case .sleep: return "Sleep"
        case .meditation: return "Meditation"
        case .study: return "Study"
        case .creative: return "Creative"
        case .custom: return "Custom"
        }
    }
}
