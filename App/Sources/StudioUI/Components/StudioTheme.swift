import Foundation
import SwiftUI
import SynthCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public extension Color {
    /// Initializes a SwiftUI `Color` from a 24-bit RGB hex integer (`0xRRGGBB`).
    init(studioHex: UInt32, alpha: Double = 1.0) {
        let red = Double((studioHex >> 16) & 0xFF) / 255.0
        let green = Double((studioHex >> 8) & 0xFF) / 255.0
        let blue = Double(studioHex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// GarageBand hardware & iOS 27 Liquid Glass visual design system for Sintonia.
public enum StudioTheme: Sendable {
    // MARK: - Core Studio Palette

    /// Deep studio graphite rack chassis background (`#101216`).
    public static let chassisGraphite = Color(studioHex: 0x101216)

    /// Obsidian hardware panel surface (`#1A1D24`).
    public static let obsidianSurface = Color(studioHex: 0x1A1D24)

    /// Elevated control housing / bezel surface (`#222631`).
    public static let elevatedSurface = Color(studioHex: 0x222631)

    /// Deep recessed slot / CRT display interior (`#0A0C10`).
    public static let recessedWell = Color(studioHex: 0x0A0C10)

    /// Subtle hardware bezel highlight line.
    public static let hairlineHighlight = Color.white.opacity(0.11)

    /// Soft edge shadow for recessed and floating controls.
    public static let hardwareShadow = Color.black.opacity(0.65)

    /// Primary studio readout text.
    public static let primaryText = Color(studioHex: 0xF3F5F8)

    /// Secondary hardware legend text.
    public static let secondaryText = Color(studioHex: 0x9BA3B4)

    /// Muted scale tick & inactive legend text (WCAG AA ~4.6:1 on obsidianSurface).
    public static let mutedText = Color(studioHex: 0x7E879B)

    // MARK: - Brushed Metal Accents & Gradients

    public static let metalHighlight = Color(studioHex: 0x8F96A3)
    public static let metalMid = Color(studioHex: 0x4A505C)
    public static let metalDark = Color(studioHex: 0x242831)

    /// Vertical dark graphite studio chassis gradient.
    public static let rackBackgroundGradient = LinearGradient(
        colors: [
            Color(studioHex: 0x15181E),
            chassisGraphite,
            Color(studioHex: 0x0C0E12)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Subtle top-lit obsidian module gradient.
    public static let obsidianModuleGradient = LinearGradient(
        colors: [
            Color(studioHex: 0x20242D),
            obsidianSurface,
            Color(studioHex: 0x15181F)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Warm brushed gunmetal gradient for bezels and hardware trims.
    public static let brushedMetalGradient = LinearGradient(
        colors: [
            Color(studioHex: 0x5E626C),
            Color(studioHex: 0x393D47),
            Color(studioHex: 0x4E535E),
            Color(studioHex: 0x2A2D35)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Conical radial brushed-metal sheen for rotary knob caps.
    public static let knobCapGradient = AngularGradient(
        gradient: Gradient(colors: [
            Color(studioHex: 0x5B5F69),
            Color(studioHex: 0x343841),
            Color(studioHex: 0x6A6F7B),
            Color(studioHex: 0x2D3038),
            Color(studioHex: 0x545964),
            Color(studioHex: 0x383C46),
            Color(studioHex: 0x5B5F69)
        ]),
        center: .center
    )

    /// Beveled warm metallic gradient for linear fader thumb caps.
    public static let faderCapGradient = LinearGradient(
        colors: [
            Color(studioHex: 0x707582),
            Color(studioHex: 0x4A4F5A),
            Color(studioHex: 0x333741),
            Color(studioHex: 0x585E6B),
            Color(studioHex: 0x2A2D35)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Specular rim stroke gradient giving depth to circular and rounded hardware housings.
    public static let metallicRimGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.28),
            Color.white.opacity(0.06),
            Color.black.opacity(0.45)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Brainwave Band Colors

    /// Delta (0.5–4 Hz) — deep luminous indigo.
    public static let deltaColor = Color(studioHex: 0x5B63F6)

    /// Theta (4–8 Hz) — purple.
    public static let thetaColor = Color(studioHex: 0xA855F7)

    /// Alpha (8–13 Hz) — teal.
    public static let alphaColor = Color(studioHex: 0x1AD9C5)

    /// Beta (13–30 Hz) — warm amber.
    public static let betaColor = Color(studioHex: 0xF5A623)

    /// Gamma (30–60 Hz) — coral.
    public static let gammaColor = Color(studioHex: 0xFF6B5B)

    // MARK: - Telemetry & Metering Colors

    /// Left channel oscilloscope phosphor trace (teal).
    public static let leftTraceColor = alphaColor

    /// Right channel oscilloscope phosphor trace (warm amber).
    public static let rightTraceColor = betaColor

    /// Safe nominal signal LED segment color.
    public static let ledGreen = Color(studioHex: 0x2EE57D)

    /// High-headroom warning LED segment color.
    public static let ledAmber = Color(studioHex: 0xF5B324)

    /// Near-0 dBFS clip LED segment color.
    public static let ledRed = Color(studioHex: 0xFF4757)

    /// Dark unlit LED well base.
    public static let ledOff = Color(studioHex: 0x1E232D)

    // MARK: - Brainwave Band Helpers

    /// Returns the canonical accent color for `band`.
    public static func color(for band: BrainwaveBand) -> Color {
        switch band {
        case .delta: return deltaColor
        case .theta: return thetaColor
        case .alpha: return alphaColor
        case .beta: return betaColor
        case .gamma: return gammaColor
        }
    }

    /// Returns the localized band display name (`Delta`..`Gamma`).
    public static func localizedName(for band: BrainwaveBand) -> String {
        switch band {
        case .delta: return String(localized: "Delta")
        case .theta: return String(localized: "Theta")
        case .alpha: return String(localized: "Alpha")
        case .beta: return String(localized: "Beta")
        case .gamma: return String(localized: "Gamma")
        }
    }

    /// Returns the canonical Hz frequency span label for `band`.
    public static func frequencyRangeLabel(for band: BrainwaveBand) -> String {
        switch band {
        case .delta: return "0.5–4 Hz"
        case .theta: return "4–8 Hz"
        case .alpha: return "8–13 Hz"
        case .beta: return "13–30 Hz"
        case .gamma: return "30–60 Hz"
        }
    }

    // MARK: - Formatting Helpers

    /// Formats a duration or timestamp in seconds as `MM:SS` (e.g., `00:00`, `40:00`).
    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let clamped = min(359_999.0, max(0.0, seconds))
        let totalSeconds = Int(clamped)
        let minutes = totalSeconds / 60
        let remainderSeconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, remainderSeconds)
    }

    /// Formats a beat or carrier frequency readout without trailing unit (e.g., `"9.4"`, `"7.83"`, `"210"`).
    public static func formatFrequencyNumber(_ hz: Double) -> String {
        guard hz.isFinite else { return "0.0" }
        let clamped = max(0.0, hz)
        if clamped >= 50.0 && abs(clamped - clamped.rounded()) < 0.05 {
            return String(format: "%.0f", clamped)
        }
        let hundredths = (clamped * 100.0).rounded()
        let tenths = (clamped * 10.0).rounded()
        if clamped < 20.0 && abs(hundredths - tenths * 10.0) >= 0.5 {
            return String(format: "%.2f", clamped)
        }
        return String(format: "%.1f", clamped)
    }

    /// Formats a frequency readout with unit suffix (e.g., `"9.4 Hz"`, `"7.83 Hz"`).
    public static func formatFrequency(_ hz: Double) -> String {
        "\(formatFrequencyNumber(hz)) Hz"
    }

    /// Formats a linear gain multiplier as dB (e.g., `"0.0 dB"`, `"-6.0 dB"`, `"-∞ dB"`).
    public static func formatDecibels(linearGain: Double) -> String {
        guard linearGain.isFinite, linearGain > 0.0001 else {
            return "-∞ dB"
        }
        let db = 20.0 * log10(linearGain)
        if abs(db) < 0.05 {
            return "0.0 dB"
        }
        return String(format: "%+.1f dB", db)
    }
}

public extension BrainwaveBand {
    /// Accent color mapped to this brainwave band.
    var accentColor: Color {
        StudioTheme.color(for: self)
    }

    /// Localized display name for this brainwave band.
    var localizedTitle: String {
        StudioTheme.localizedName(for: self)
    }

    /// Canonical frequency range string (`"0.5–4 Hz"`, etc.).
    var frequencyRangeLabel: String {
        StudioTheme.frequencyRangeLabel(for: self)
    }
}

// MARK: - iOS 27 Liquid Glass & Hardware Surface Helpers

public extension View {
    /// Applies an iOS 27 Liquid Glass rounded panel effect tuned for Sintonia's dark studio rack.
    func studioGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let baseGlass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        return self
            .glassEffect(baseGlass.interactive(interactive), in: shape)
            .overlay {
                shape.strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
            }
    }

    /// Applies an iOS 27 Liquid Glass capsule effect for transport bars and status badges.
    func studioGlassCapsule(
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        let baseGlass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        return self
            .glassEffect(baseGlass.interactive(interactive), in: Capsule())
            .overlay {
                Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
            }
    }

    /// Styles a container as an obsidian GarageBand rack module with beveled rim highlight.
    func studioRackCard(
        cornerRadius: CGFloat = 16,
        borderColor: Color = StudioTheme.hairlineHighlight
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape
                    .fill(StudioTheme.obsidianModuleGradient)
                    .shadow(color: StudioTheme.hardwareShadow, radius: 10, x: 0, y: 6)
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 1.0)
            }
    }
}

/// Compact pill badge displaying the active brainwave band and optional live beat frequency.
public struct BrainwaveBandBadge: View {
    private let band: BrainwaveBand
    private let beatHz: Double?
    private let compact: Bool

    public init(band: BrainwaveBand, beatHz: Double? = nil, compact: Bool = false) {
        self.band = band
        self.beatHz = beatHz
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: compact ? 5 : 6) {
            Circle()
                .fill(band.accentColor)
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
                .shadow(color: band.accentColor.opacity(0.85), radius: 4)

            if let beatHz {
                Text(verbatim: "\(band.localizedTitle) • \(StudioTheme.formatFrequency(beatHz))")
                    .font((compact ? Font.caption2 : Font.caption).weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
            } else {
                Text(verbatim: "\(band.localizedTitle) • \(band.frequencyRangeLabel)")
                    .font((compact ? Font.caption2 : Font.caption).weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .background {
            Capsule()
                .fill(band.accentColor.opacity(0.16))
        }
        .overlay {
            Capsule()
                .strokeBorder(band.accentColor.opacity(0.45), lineWidth: 0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let beatHz {
            return "\(band.localizedTitle), \(StudioTheme.formatFrequency(beatHz))"
        }
        return "\(band.localizedTitle), \(band.frequencyRangeLabel)"
    }
}

/// Shared GarageBand tactile haptic and modifier-input coordinator across `StudioUI` controls.
@MainActor
internal final class StudioControlHaptics {
    enum ImpactStyle {
        case light
        case medium
        case rigid
    }

    static var isFineTuningModifierPressed: Bool {
        #if os(macOS)
        !NSEvent.modifierFlags.intersection([.option, .shift]).isEmpty
        #else
        false
        #endif
    }

    #if os(iOS)
    private let detentGenerator = UIImpactFeedbackGenerator(style: .light)
    private let transportGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let limitGenerator = UIImpactFeedbackGenerator(style: .rigid)
    #endif

    func prepare() {
        #if os(iOS)
        detentGenerator.prepare()
        transportGenerator.prepare()
        limitGenerator.prepare()
        #endif
    }

    func handleNormalizedTransition(
        from oldNormalized: Double,
        to newNormalized: Double,
        isBipolar: Bool
    ) {
        let hitLowerLimit = newNormalized <= 0.0 && oldNormalized > 0.0
        let hitUpperLimit = newNormalized >= 1.0 && oldNormalized < 1.0
        if hitLowerLimit || hitUpperLimit {
            fireImpact(.rigid, intensity: 0.85)
            return
        }

        if isBipolar {
            let crossedCenter = (oldNormalized < 0.5 && newNormalized >= 0.5)
                || (oldNormalized > 0.5 && newNormalized <= 0.5)
            if crossedCenter {
                fireImpact(.light, intensity: 0.72)
                return
            }
        }

        for step in 1...9 {
            let threshold = Double(step) * 0.1
            let crossed = (oldNormalized < threshold && newNormalized >= threshold)
                || (oldNormalized > threshold && newNormalized <= threshold)
            if crossed {
                fireImpact(.light, intensity: 0.45)
                return
            }
        }
    }

    func fireModeShift() {
        fireImpact(.light, intensity: 0.35)
    }

    func fireStep() {
        fireImpact(.light, intensity: 0.45)
    }

    func fireReset() {
        fireImpact(.rigid, intensity: 0.65)
    }

    func fireTransport() {
        fireImpact(.medium, intensity: 0.8)
    }

    func fireImpact(_ style: ImpactStyle = .light, intensity: CGFloat = 0.65) {
        #if os(iOS)
        switch style {
        case .light:
            detentGenerator.impactOccurred(intensity: intensity)
        case .medium:
            transportGenerator.impactOccurred(intensity: intensity)
        case .rigid:
            limitGenerator.impactOccurred(intensity: intensity)
        }
        #elseif os(macOS)
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch style {
        case .light: .alignment
        case .medium, .rigid: .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        #endif
    }
}
