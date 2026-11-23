import PresetKit
import SwiftUI
import SynthCore
import WaveForgeExport

/// Modal offline audio export sheet rendering the active preset to 24-bit WAV or 256 kbps M4A
/// inside a cancellable task with live progress, localized error handling, and system `ShareLink`.
public struct ExportSheetView: View {
    private let preset: Preset
    private let accentColor: Color
    private let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var environmentDismiss

    @State private var selectedFormat: ExportFormat = .m4a
    @State private var exportState: ExportState = .idle
    @State private var exportTask: Task<Void, Never>?
    @State private var activeRunID: UUID?

    private enum ExportState: Equatable {
        case idle
        case exporting(progress: Double)
        case completed(URL)
        case cancelled
        case failed(String)
    }

    public init(
        preset: Preset,
        accentColor: Color = StudioTheme.alphaColor,
        onDismiss: (() -> Void)? = nil
    ) {
        self.preset = preset
        self.accentColor = accentColor
        self.onDismiss = onDismiss
    }

    private var isExporting: Bool {
        if case .exporting = exportState {
            return true
        }
        return false
    }

    private var estimatedByteCount: Int64 {
        let duration = max(0.0, preset.durationSec)
        switch selectedFormat {
        case .wav:
            return Int64((duration * 48_000.0 * 2.0 * 3.0).rounded(.up))
        case .m4a:
            return Int64((duration * (256_000.0 / 8.0)).rounded(.up))
        }
    }

    private var formattedEstimatedSize: String {
        ByteCountFormatter.string(fromByteCount: estimatedByteCount, countStyle: .file)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    sessionSummaryCard
                    formatSelectorCard
                    exportActionSection
                }
                .padding(16)
            }
            .background(StudioTheme.rackBackgroundGradient.ignoresSafeArea())
            .navigationTitle("Export Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(completedURL == nil ? "Close" : "Done") {
                        dismissSheet()
                    }
                    .foregroundStyle(accentColor)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            cancelActiveTask()
        }
    }

    private var completedURL: URL? {
        if case .completed(let url) = exportState {
            return url
        }
        return nil
    }

    private var sessionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accentColor.opacity(0.16))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Session")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(StudioTheme.secondaryText)
                    Text(verbatim: preset.name)
                        .font(.headline)
                        .foregroundStyle(StudioTheme.primaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            Divider()
                .overlay(StudioTheme.hairlineHighlight)

            VStack(spacing: 8) {
                summaryRow(
                    titleKey: "Estimated Duration",
                    value: StudioTheme.formatTime(preset.durationSec)
                )
                summaryRow(
                    titleKey: "Sample Rate",
                    value: String(localized: "48 kHz Stereo")
                )
                summaryRow(
                    titleKey: "Estimated Size",
                    value: formattedEstimatedSize
                )
            }
        }
        .padding(14)
        .studioRackCard()
    }

    private func summaryRow(titleKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(titleKey)
                .font(.subheadline)
                .foregroundStyle(StudioTheme.secondaryText)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(StudioTheme.primaryText)
        }
    }

    private var formatSelectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Format")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.secondaryText)

            VStack(spacing: 8) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    formatOptionRow(for: format)
                }
            }
            .disabled(isExporting)
            .opacity(isExporting ? 0.65 : 1.0)
        }
        .padding(14)
        .studioRackCard()
    }

    private func formatOptionRow(for format: ExportFormat) -> some View {
        let isSelected = selectedFormat == format
        return Button {
            selectedFormat = format
            if case .completed(let oldURL) = exportState {
                try? FileManager.default.removeItem(at: oldURL)
                exportState = .idle
            } else if case .cancelled = exportState {
                exportState = .idle
            } else if case .failed = exportState {
                exportState = .idle
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? accentColor : StudioTheme.mutedText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTitleKey(for: format))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                    Text(verbatim: ".\(format.fileExtension.uppercased())")
                        .font(.caption.monospaced())
                        .foregroundStyle(StudioTheme.secondaryText)
                }

                Spacer(minLength: 8)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.14) : StudioTheme.recessedWell.opacity(0.85))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? accentColor.opacity(0.6) : StudioTheme.hairlineHighlight,
                        lineWidth: isSelected ? 1.1 : 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func formatTitleKey(for format: ExportFormat) -> LocalizedStringKey {
        switch format {
        case .wav:
            return "WAV 24-bit"
        case .m4a:
            return "M4A AAC"
        }
    }

    @ViewBuilder
    private var exportActionSection: some View {
        switch exportState {
        case .idle:
            startExportButton

        case .exporting(let progress):
            VStack(spacing: 14) {
                HStack {
                    Text("Exporting Audio…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(Int((min(1.0, max(0.0, progress)) * 100.0).rounded()))%")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(accentColor)
                }

                ProgressView(value: min(1.0, max(0.0, progress)), total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(accentColor)

                Button(role: .cancel) {
                    cancelExportByUser()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .tint(StudioTheme.secondaryText)
            }
            .padding(14)
            .studioRackCard()

        case .completed(let url):
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(StudioTheme.ledGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export Complete")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.primaryText)
                        Text(verbatim: url.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(StudioTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .studioRackCard(borderColor: StudioTheme.ledGreen.opacity(0.45))

                ShareLink(item: url) {
                    Label("Share Audio", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(StudioTheme.chassisGraphite)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(accentColor)
                        }
                }
                .buttonStyle(.plain)

                Button {
                    try? FileManager.default.removeItem(at: url)
                    exportState = .idle
                } label: {
                    Text("Export Again")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(StudioTheme.secondaryText)
            }

        case .cancelled:
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(StudioTheme.betaColor)
                    Text("Export Cancelled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .studioRackCard(borderColor: StudioTheme.betaColor.opacity(0.4))

                startExportButton
            }

        case .failed(let message):
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(StudioTheme.ledRed)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Export Failed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.primaryText)
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(StudioTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .studioRackCard(borderColor: StudioTheme.ledRed.opacity(0.5))

                startExportButton
            }
        }
    }

    private var startExportButton: some View {
        Button {
            startExport()
        } label: {
            Label("Export", systemImage: "arrow.down.doc.fill")
                .font(.headline)
                .foregroundStyle(StudioTheme.chassisGraphite)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accentColor)
                }
        }
        .buttonStyle(.plain)
    }

    private func startExport() {
        cancelActiveTask()
        if case .completed(let oldURL) = exportState {
            try? FileManager.default.removeItem(at: oldURL)
        }

        let runID = UUID()
        activeRunID = runID
        exportState = .exporting(progress: 0.0)

        let presetToExport = preset
        let formatToExport = selectedFormat

        exportTask = Task {
            do {
                let url = try await SessionExporter.export(
                    preset: presetToExport,
                    format: formatToExport
                ) { progress in
                    Task { @MainActor in
                        guard activeRunID == runID else { return }
                        if case .exporting(let currentProgress) = exportState {
                            let clamped = progress.isFinite ? min(1.0, max(0.0, progress)) : currentProgress
                            exportState = .exporting(progress: max(currentProgress, clamped))
                        }
                    }
                }
                guard !Task.isCancelled, activeRunID == runID else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                exportState = .completed(url)
                exportTask = nil
            } catch is CancellationError {
                if activeRunID == runID {
                    exportState = .cancelled
                    exportTask = nil
                }
            } catch {
                if activeRunID == runID {
                    exportState = .failed(Self.localizedErrorMessage(for: error))
                    exportTask = nil
                }
            }
        }
    }

    private func cancelExportByUser() {
        cancelActiveTask()
        exportState = .cancelled
    }

    private func cancelActiveTask() {
        activeRunID = nil
        exportTask?.cancel()
        exportTask = nil
    }

    private func dismissSheet() {
        if let onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    private static func localizedErrorMessage(for error: any Error) -> String {
        if let exportError = error as? ExportError {
            switch exportError {
            case .invalidDuration:
                return String(localized: "Session duration must be greater than zero.")
            case .invalidSampleRate:
                return String(localized: "Export sample rate must be finite and positive.")
            case .insufficientStorage:
                return String(localized: "Not enough free storage space to export this audio file.")
            case .audioFormatUnavailable:
                return String(localized: "Unable to configure 48 kHz stereo PCM audio format.")
            case .bufferAllocationFailed:
                return String(localized: "Unable to allocate offline audio render buffer.")
            case .writeFailed(let detail):
                return detail.isEmpty ? String(localized: "Export Failed") : detail
            }
        }
        return error.localizedDescription
    }
}
