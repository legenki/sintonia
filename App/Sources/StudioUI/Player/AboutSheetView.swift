import SwiftUI

/// Modal About sheet presenting WaveForge's App Store Guideline 1.4.1 wellness & safe-listening
/// disclaimer, synthesis feature overview, offline privacy guarantee, and `.bwg` compatibility note.
public struct AboutSheetView: View {
    private let accentColor: Color
    private let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var environmentDismiss

    public init(accentColor: Color = StudioTheme.alphaColor, onDismiss: (() -> Void)? = nil) {
        self.accentColor = accentColor
        self.onDismiss = onDismiss
    }

    private var appVersionLabel: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(shortVersion) (\(buildNumber))"
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    wellnessDisclaimerCard
                    featuresCard
                    bwgCompatibilityCard
                    offlinePrivacyCard
                }
                .padding(16)
            }
            .background(StudioTheme.rackBackgroundGradient.ignoresSafeArea())
            .navigationTitle("About WaveForge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let onDismiss {
                            onDismiss()
                        } else {
                            environmentDismiss()
                        }
                    }
                    .foregroundStyle(accentColor)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.28), StudioTheme.deltaColor.opacity(0.24)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 58, height: 58)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.45), lineWidth: 1.0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("WaveForge")
                    .font(.title3.bold())
                    .foregroundStyle(StudioTheme.primaryText)

                Text("Binaural & Isochronic Sound Studio")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.secondaryText)

                HStack(spacing: 5) {
                    Text("Version")
                    Text(verbatim: appVersionLabel)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(StudioTheme.mutedText)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .studioRackCard()
    }

    private var wellnessDisclaimerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "ear.and.waveform")
                    .font(.headline)
                    .foregroundStyle(StudioTheme.betaColor)
                Text("Wellness & Safe-Listening Notice")
                    .font(.headline)
                    .foregroundStyle(StudioTheme.primaryText)
            }

            Text("Wellness & Safe-Listening Disclaimer")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .studioRackCard(borderColor: StudioTheme.betaColor.opacity(0.42))
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Features")
                .font(.headline)
                .foregroundStyle(StudioTheme.primaryText)

            featureRow(
                icon: "dial.medium.fill",
                titleKey: "Real-Time Multi-Voice Synthesis",
                detailKey: "Real-Time Multi-Voice Synthesis Detail"
            )

            Divider()
                .overlay(StudioTheme.hairlineHighlight)

            featureRow(
                icon: "chart.xyaxis.line",
                titleKey: "Automation & Offline Export",
                detailKey: "Automation & Offline Export Detail"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .studioRackCard()
    }

    private func featureRow(
        icon: String,
        titleKey: LocalizedStringKey,
        detailKey: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(titleKey)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                Text(detailKey)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bwgCompatibilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.headline)
                    .foregroundStyle(accentColor)
                Text("BWG Compatibility")
                    .font(.headline)
                    .foregroundStyle(StudioTheme.primaryText)
            }

            Text("BWG Compatibility Note")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .studioRackCard()
    }

    private var offlinePrivacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(StudioTheme.ledGreen)
                Text("Offline Privacy")
                    .font(.headline)
                    .foregroundStyle(StudioTheme.primaryText)
            }

            Text("Offline Privacy Detail")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .studioRackCard()
    }
}
