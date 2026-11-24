import PresetKit
import SwiftUI
import SynthCore

@MainActor
private final class StudioTelemetryBox {
    var frame = TelemetryFrame()
}

private struct StripMasterLevels {
    let rmsL: Float
    let rmsR: Float
    let peakL: Float
    let peakR: Float

    static let zero = StripMasterLevels(rmsL: 0, rmsR: 0, peakL: 0, peakR: 0)
}

private enum StudioDetailTab: String, CaseIterable, Identifiable {
    case voice
    case noise
    case curves

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .voice: return "Voice"
        case .noise: return "Noise"
        case .curves: return "Curves"
        }
    }

    var systemImage: String {
        switch self {
        case .voice: return "waveform.circle"
        case .noise: return "speaker.wave.2"
        case .curves: return "chart.xyaxis.line"
        }
    }
}

/// Full GarageBand-style Screen 2 Studio Rack & Curve Editor giving users live real-time control
/// over all 10 voices, noise layer, preset metadata, and session automation curves.
public struct StudioRackView: View {
    private let engine: AudioEngineController
    private let presetStore: PresetStore
    private let showsDualPaneWhenWide: Bool
    private let externalSyncTrigger: UUID?
    private let onDirtyStateChanged: (Bool) -> Void
    private let onRegisterSaveHandler: ((() -> Bool)?) -> Void
    private let onRegisterDiscardHandler: ((() -> Void)?) -> Void
    private let onSavedPreset: (Preset) -> Void
    private let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var environmentDismiss
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    @FocusState private var isPresetNameFocused: Bool

    @State private var draft: Preset
    @State private var baselinePreset: Preset
    @State private var hasSavedInStore: Bool
    @State private var lastAppliedSyncTrigger: UUID?
    @State private var isDirty: Bool = false
    @State private var selectedVoiceIndex: Int = 0
    @State private var activeTab: StudioDetailTab = .voice
    @State private var selectedCurveParameter: CurveEditorParameter = .beatHz
    @State private var isPresetMetadataExpanded: Bool = false
    @State private var showRackInLandscape: Bool = false
    @State private var showDiscardConfirmation: Bool = false
    @State private var showSavedBadge: Bool = false
    @State private var savedBadgeTask: Task<Void, Never>?
    @State private var validationErrorMessage: String?
    /// Draft value already pushed to (or pulled from) the engine synchronously; its deferred
    /// `onChange(of: draft)` must not re-apply it after a coordinator has loaded another preset.
    @State private var engineSyncedDraft: Preset?

    @State private var telemetryBox = StudioTelemetryBox()
    @State private var haptics = StudioControlHaptics()

    public init(
        engine: AudioEngineController,
        presetStore: PresetStore,
        showsDualPaneWhenWide: Bool = false,
        externalSyncTrigger: UUID? = nil,
        onDirtyStateChanged: @escaping (Bool) -> Void = { _ in },
        onRegisterSaveHandler: @escaping ((() -> Bool)?) -> Void = { _ in },
        onRegisterDiscardHandler: @escaping ((() -> Void)?) -> Void = { _ in },
        onSavedPreset: @escaping (Preset) -> Void = { _ in },
        onDismiss: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.presetStore = presetStore
        self.showsDualPaneWhenWide = showsDualPaneWhenWide
        self.externalSyncTrigger = externalSyncTrigger
        self.onDirtyStateChanged = onDirtyStateChanged
        self.onRegisterSaveHandler = onRegisterSaveHandler
        self.onRegisterDiscardHandler = onRegisterDiscardHandler
        self.onSavedPreset = onSavedPreset
        self.onDismiss = onDismiss
        let initial = engine.currentPreset
        self._draft = State(initialValue: initial)
        self._baselinePreset = State(initialValue: initial)
        self._hasSavedInStore = State(
            initialValue: initial.isBuiltIn || presetStore.allPresets().contains { $0.id == initial.id }
        )
        self._lastAppliedSyncTrigger = State(initialValue: externalSyncTrigger)
    }

    private var isCompactLandscape: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    private var dualPaneInspectorTab: StudioDetailTab {
        activeTab == .noise ? .noise : .voice
    }

    private var accentColor: Color {
        engine.dominantBand.accentColor
    }

    private var safeVoiceIndex: Int {
        guard !draft.voices.isEmpty else { return 0 }
        return min(max(0, selectedVoiceIndex), draft.voices.count - 1)
    }

    public var body: some View {
        ZStack {
            StudioTheme.rackBackgroundGradient
                .ignoresSafeArea()

            if showsDualPaneWhenWide {
                GeometryReader { proxy in
                    let useDualPane = proxy.size.width >= 880
                    studioBodyContent(useDualPane: useDualPane)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                studioBodyContent(useDualPane: false)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isDirty)
        .onAppear {
            if let externalSyncTrigger, lastAppliedSyncTrigger != externalSyncTrigger {
                lastAppliedSyncTrigger = externalSyncTrigger
                syncFromEngine()
            } else if !isDirty && draft != engine.currentPreset {
                syncFromEngine()
            }
            onRegisterSaveHandler { saveDraft() }
            onRegisterDiscardHandler { revertDraftToBaseline() }
            onDirtyStateChanged(isDirty)
        }
        .onChange(of: draft) { _, updatedDraft in
            handleDraftChanged(updatedDraft)
        }
        .onChange(of: isDirty) { _, dirty in
            onDirtyStateChanged(dirty)
        }
        .onChange(of: externalSyncTrigger) { _, newTrigger in
            guard let newTrigger else { return }
            lastAppliedSyncTrigger = newTrigger
            syncFromEngine()
        }
        .onChange(of: isCompactLandscape) { _, compact in
            if !compact {
                showRackInLandscape = false
            }
        }
        .onDisappear {
            savedBadgeTask?.cancel()
            savedBadgeTask = nil
            onRegisterSaveHandler(nil)
            onRegisterDiscardHandler(nil)
            onDirtyStateChanged(false)
        }
        .confirmationDialog(
            "Unsaved Changes",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save") {
                if saveDraft() {
                    dismissStudio()
                }
            }
            Button("Discard Changes", role: .destructive) {
                discardChangesAndDismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved studio edits. Save before closing?")
        }
    }

    // MARK: - Top Studio Navigation & Transport Bar

    private var topStudioBar: some View {
        HStack(spacing: 8) {
            Button {
                requestDismiss()
            } label: {
                let cancelOrDoneKey: LocalizedStringKey = isDirty ? "Cancel" : "Done"
                Text(cancelOrDoneKey)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDirty ? StudioTheme.secondaryText : StudioTheme.primaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            // Live Transport + Dominant Band Pill
            HStack(spacing: 8) {
                Button {
                    haptics.prepare()
                    engine.togglePlayPause()
                    haptics.fireStep()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.chassisGraphite)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(engine.isPlaying ? "Pause" : "Play"))

                Text(verbatim: "\(StudioTheme.formatTime(engine.currentTime)) / \(StudioTheme.formatTime(draft.durationSec))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)

                if !isCompactLandscape {
                    BrainwaveBandBadge(
                        band: engine.dominantBand,
                        beatHz: engine.dominantBeatHz,
                        compact: true
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(StudioTheme.recessedWell))
            .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))

            Spacer(minLength: 4)

            if isCompactLandscape {
                Button {
                    showRackInLandscape.toggle()
                    haptics.fireModeShift()
                } label: {
                    let toggleTitleKey: LocalizedStringKey = showRackInLandscape ? "Curves" : "Rack"
                    Label(
                        toggleTitleKey,
                        systemImage: showRackInLandscape ? "chart.xyaxis.line" : "slider.horizontal.3"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            saveButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .studioGlassSurface(cornerRadius: 16, tint: accentColor.opacity(0.1), interactive: true)
    }

    private var saveButton: some View {
        let labelKey: LocalizedStringKey = if showSavedBadge {
            "Saved"
        } else if draft.isBuiltIn {
            "Save Copy"
        } else {
            "Save"
        }
        let isHighlighted = isDirty || draft.isBuiltIn || !hasSavedInStore

        return Button {
            _ = saveDraft()
        } label: {
            HStack(spacing: 4) {
                if showSavedBadge {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(labelKey)
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(showSavedBadge ? StudioTheme.chassisGraphite : (isHighlighted ? StudioTheme.chassisGraphite : StudioTheme.secondaryText))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(showSavedBadge ? StudioTheme.ledGreen : (isHighlighted ? accentColor : Color.white.opacity(0.08)))
            }
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StudioTheme.ledRed)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(StudioTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                validationErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .studioRackCard(cornerRadius: 12, borderColor: StudioTheme.ledRed.opacity(0.5))
    }

    // MARK: - Preset Metadata Section

    private var presetMetadataSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "slider.vertical.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)

                TextField("Preset Name", text: $draft.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .autocorrectionDisabled()
                    .focused($isPresetNameFocused)
                    .focusedValue(\.isTextInputFocused, isPresetNameFocused)
                    .focusedSceneValue(\.isTextInputFocused, isPresetNameFocused ? true : nil)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioTheme.recessedWell))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isPresetMetadataExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: StudioTheme.formatTime(draft.durationSec))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                        Image(systemName: isPresetMetadataExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(StudioTheme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(StudioTheme.recessedWell))
                    .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Preset"))
            }

            if isPresetMetadataExpanded {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Category")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioTheme.secondaryText)

                        Spacer()

                        if draft.isBuiltIn {
                            Text("Saving creates a Custom copy")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(StudioTheme.betaColor)
                        } else {
                            Picker("Category", selection: $draft.category) {
                                ForEach(PresetCategory.allCases, id: \.self) { category in
                                    Text(categoryTitleKey(for: category)).tag(category)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(accentColor)
                        }
                    }

                    // Duration (60...7200s)
                    VStack(spacing: 5) {
                        HStack {
                            Text("Duration")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StudioTheme.secondaryText)
                            Spacer()
                            Text(verbatim: StudioTheme.formatTime(draft.durationSec))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(StudioTheme.primaryText)

                            Stepper(
                                "Duration",
                                value: durationBinding,
                                in: PresetLimits.durationRange,
                                step: 60.0
                            )
                            .labelsHidden()
                            .scaleEffect(0.82)
                        }

                        HStack(spacing: 6) {
                            ForEach([15, 30, 40, 45, 60], id: \.self) { minutes in
                                let seconds = Double(minutes * 60)
                                let isActive = abs(draft.durationSec - seconds) < 1.0
                                Button {
                                    draft.durationSec = seconds
                                    haptics.fireStep()
                                } label: {
                                    Text("\(minutes)m")
                                        .font(.caption2.weight(isActive ? .bold : .medium).monospacedDigit())
                                        .foregroundStyle(isActive ? StudioTheme.chassisGraphite : StudioTheme.secondaryText)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(isActive ? accentColor : StudioTheme.recessedWell))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Fade In & Fade Out (0...120s)
                    HStack(spacing: 12) {
                        fadeControl(
                            titleKey: "Fade In",
                            value: $draft.fadeInSec
                        )
                        fadeControl(
                            titleKey: "Fade Out",
                            value: $draft.fadeOutSec
                        )
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .studioRackCard(cornerRadius: 14)
    }

    private func fadeControl(titleKey: LocalizedStringKey, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(titleKey)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))s")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
            }
            Slider(value: value, in: PresetLimits.fadeRange, step: 1.0)
                .tint(accentColor)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Voice Channel Strip Rack (1...10 Voices)

    private var voiceRackSection: some View {
        let canAddVoice = draft.voices.count < PresetLimits.voiceCountRange.upperBound
        let canDeleteSelected = draft.voices.count > PresetLimits.voiceCountRange.lowerBound

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Voices")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textCase(.uppercase)

                Text(verbatim: "\(draft.voices.count)/\(PresetLimits.voiceCountRange.upperBound)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(canAddVoice ? accentColor : StudioTheme.betaColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(StudioTheme.recessedWell))

                if !canAddVoice {
                    Text("Max 10 Voices")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.betaColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    duplicateVoice(at: safeVoiceIndex)
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(canAddVoice ? StudioTheme.primaryText : StudioTheme.mutedText)
                        .frame(width: 28, height: 26)
                        .background(Capsule().fill(StudioTheme.recessedWell))
                }
                .buttonStyle(.plain)
                .disabled(!canAddVoice)
                .accessibilityLabel(Text("Duplicate"))

                Button {
                    deleteVoice(at: safeVoiceIndex)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(canDeleteSelected ? StudioTheme.ledRed : StudioTheme.mutedText)
                        .frame(width: 28, height: 26)
                        .background(Capsule().fill(StudioTheme.recessedWell))
                }
                .buttonStyle(.plain)
                .disabled(!canDeleteSelected)
                .accessibilityLabel(Text("Delete"))

                Button {
                    addVoice()
                } label: {
                    Label("Add Voice", systemImage: "plus")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(canAddVoice ? StudioTheme.chassisGraphite : StudioTheme.mutedText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(canAddVoice ? accentColor : StudioTheme.recessedWell))
                }
                .buttonStyle(.plain)
                .disabled(!canAddVoice)
            }

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !engine.isPlaying)) { _ in
                let masterLevels = currentMasterLevels()
                let hasSolo = draft.voices.contains { $0.isEnabled && $0.isSolo }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(draft.voices.enumerated()), id: \.element.id) { index, _ in
                            VoiceChannelStrip(
                                voice: $draft.voices[index],
                                index: index,
                                isSelected: safeVoiceIndex == index,
                                hasActiveSoloInRack: hasSolo,
                                isPlaying: engine.isPlaying,
                                currentTime: engine.currentTime,
                                masterLevels: masterLevels,
                                canDuplicate: canAddVoice,
                                canDelete: canDeleteSelected,
                                onSelect: {
                                    selectedVoiceIndex = index
                                    if activeTab == .noise {
                                        activeTab = .voice
                                    }
                                    haptics.fireModeShift()
                                },
                                onDuplicate: {
                                    duplicateVoice(at: index)
                                },
                                onDelete: {
                                    deleteVoice(at: index)
                                }
                            )
                        }

                        if canAddVoice {
                            addVoiceTile
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(height: 174)
        }
        .padding(10)
        .studioRackCard(cornerRadius: 16)
    }

    private var addVoiceTile: some View {
        Button {
            addVoice()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(accentColor)
                Text("Add Voice")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 72, height: 170)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StudioTheme.recessedWell.opacity(0.65))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(StudioTheme.hairlineHighlight)
            }
        }
        .buttonStyle(.plain)
    }

    private func currentMasterLevels() -> StripMasterLevels {
        guard engine.isPlaying else { return .zero }
        engine.telemetryBuffer.readLatest(into: &telemetryBox.frame)
        return StripMasterLevels(
            rmsL: telemetryBox.frame.rmsL,
            rmsR: telemetryBox.frame.rmsR,
            peakL: telemetryBox.frame.peakL,
            peakR: telemetryBox.frame.peakR
        )
    }

    // MARK: - Responsive Body & Inspector / Curve Editor Bay

    private func studioBodyContent(useDualPane: Bool) -> some View {
        VStack(spacing: isCompactLandscape ? 8 : 10) {
            topStudioBar

            if let validationErrorMessage {
                errorBanner(message: validationErrorMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isCompactLandscape && !showRackInLandscape {
                CurveEditorView(
                    preset: $draft,
                    selectedVoiceIndex: $selectedVoiceIndex,
                    selectedParameter: $selectedCurveParameter,
                    currentTime: engine.currentTime,
                    accentColor: nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if useDualPane {
                presetMetadataSection
                voiceRackSection

                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 10) {
                        detailTabsBar(tabs: [.voice, .noise], selectedTab: dualPaneInspectorTab)
                        inspectorTabContent(for: dualPaneInspectorTab, switchToCurvesOnEdit: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: 350)
                    .frame(maxHeight: .infinity)

                    CurveEditorView(
                        preset: $draft,
                        selectedVoiceIndex: $selectedVoiceIndex,
                        selectedParameter: $selectedCurveParameter,
                        currentTime: engine.currentTime,
                        accentColor: nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                presetMetadataSection
                voiceRackSection
                detailTabsBar(tabs: StudioDetailTab.allCases, selectedTab: activeTab)
                detailTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, isCompactLandscape ? 12 : 14)
        .padding(.top, isCompactLandscape ? 6 : 8)
        .padding(.bottom, isCompactLandscape ? 8 : 12)
    }

    private func detailTabsBar(tabs: [StudioDetailTab], selectedTab: StudioDetailTab) -> some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                let isSelected = selectedTab == tab
                Button {
                    haptics.prepare()
                    withAnimation(.easeOut(duration: 0.16)) {
                        activeTab = tab
                    }
                    haptics.fireModeShift()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.caption2.weight(.semibold))
                        Text(tab.titleKey)
                            .font(.caption.weight(isSelected ? .bold : .medium))
                    }
                    .foregroundStyle(isSelected ? StudioTheme.primaryText : StudioTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? accentColor.opacity(0.22) : StudioTheme.recessedWell)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? accentColor.opacity(0.65) : StudioTheme.hairlineHighlight,
                                lineWidth: isSelected ? 1.0 : 0.75
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var detailTabContent: some View {
        switch activeTab {
        case .voice, .noise:
            inspectorTabContent(for: activeTab, switchToCurvesOnEdit: true)

        case .curves:
            CurveEditorView(
                preset: $draft,
                selectedVoiceIndex: $selectedVoiceIndex,
                selectedParameter: $selectedCurveParameter,
                currentTime: engine.currentTime,
                accentColor: nil
            )
        }
    }

    @ViewBuilder
    private func inspectorTabContent(
        for tab: StudioDetailTab,
        switchToCurvesOnEdit: Bool
    ) -> some View {
        let onEditCurve: (CurveEditorParameter) -> Void = { parameter in
            selectedCurveParameter = parameter
            if switchToCurvesOnEdit {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeTab = .curves
                }
            }
        }

        switch tab {
        case .voice:
            ScrollView(.vertical, showsIndicators: false) {
                if draft.voices.indices.contains(safeVoiceIndex) {
                    VoiceInspectorView(
                        voice: $draft.voices[safeVoiceIndex],
                        voiceIndex: safeVoiceIndex,
                        allVoices: draft.voices,
                        currentTime: engine.currentTime,
                        accentColor: accentColor,
                        onEditCurve: onEditCurve
                    )
                    .padding(.bottom, 8)
                }
            }

        case .noise:
            ScrollView(.vertical, showsIndicators: false) {
                NoiseInspectorView(
                    noise: $draft.noise,
                    voices: draft.voices,
                    currentTime: engine.currentTime,
                    accentColor: StudioTheme.thetaColor,
                    onEditCurve: onEditCurve
                )
                .padding(.bottom, 8)
            }

        case .curves:
            EmptyView()
        }
    }

    // MARK: - Voice Rack & Preset Mutations

    private var durationBinding: Binding<Double> {
        Binding(
            get: { draft.durationSec },
            set: { newValue in
                let clamped = newValue.isFinite
                    ? min(PresetLimits.durationRange.upperBound, max(PresetLimits.durationRange.lowerBound, newValue))
                    : 1800.0
                draft.durationSec = clamped
            }
        )
    }

    private func handleDraftChanged(_ updatedDraft: Preset) {
        isDirty = (updatedDraft != baselinePreset)

        if let synced = engineSyncedDraft {
            engineSyncedDraft = nil
            if synced == updatedDraft {
                return
            }
        }

        var runtimeDraft = updatedDraft
        runtimeDraft.recommendedOutput = AudioRoutePolicy.hasActiveBinauralVoices(in: updatedDraft)
            ? .headphones
            : .any

        if runtimeDraft != engine.currentPreset {
            engine.applyEditedPreset(runtimeDraft)
        }
    }

    private func syncFromEngine() {
        let current = engine.currentPreset
        baselinePreset = current
        if draft != current {
            engineSyncedDraft = current
        }
        draft = current
        hasSavedInStore = current.isBuiltIn || presetStore.allPresets().contains { $0.id == current.id }
        isDirty = false
        validationErrorMessage = nil
        showSavedBadge = false
        savedBadgeTask?.cancel()
        savedBadgeTask = nil
        selectedVoiceIndex = 0
        onDirtyStateChanged(false)
    }

    private func addVoice() {
        guard draft.voices.count < PresetLimits.voiceCountRange.upperBound else { return }
        let nextNumber = draft.voices.count + 1
        let newVoice = Voice(
            id: UUID(),
            name: String(localized: "Voice \(nextNumber)"),
            isEnabled: true,
            isMuted: false,
            isSolo: false,
            mode: .binaural,
            waveform: .sine,
            isochronicSoftness: 0.5,
            isochronicDutyCycle: 0.5,
            pan: 0.0,
            carrierCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0.0, value: 200.0)], interpolation: .linear),
            beatCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0.0, value: 10.0)], interpolation: .linear),
            volumeCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0.0, value: 0.5)], interpolation: .linear),
            trackingRule: nil
        )
        draft.voices.append(newVoice)
        selectedVoiceIndex = draft.voices.count - 1
        haptics.fireStep()
    }

    private func duplicateVoice(at index: Int) {
        guard draft.voices.count < PresetLimits.voiceCountRange.upperBound,
              draft.voices.indices.contains(index) else {
            return
        }
        var copy = draft.voices[index]
        copy.id = UUID()
        copy.isSolo = false
        let baseName = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = baseName.isEmpty
            ? String(localized: "Voice \(draft.voices.count + 1)")
            : "\(baseName) (\(draft.voices.count + 1))"
        draft.voices.append(copy)
        selectedVoiceIndex = draft.voices.count - 1
        haptics.fireStep()
    }

    private func deleteVoice(at index: Int) {
        guard draft.voices.count > PresetLimits.voiceCountRange.lowerBound,
              draft.voices.indices.contains(index) else {
            return
        }

        draft.voices.remove(at: index)

        // Remap tracking source indices cleanly so remaining tracking rules stay valid and cycle-free.
        for idx in draft.voices.indices {
            guard var rule = draft.voices[idx].trackingRule else { continue }
            if rule.sourceVoiceIndex == index {
                draft.voices[idx].trackingRule = nil
            } else if rule.sourceVoiceIndex > index {
                rule.sourceVoiceIndex -= 1
                draft.voices[idx].trackingRule = rule
            }
        }

        if let pulseSource = draft.noise.pulseSourceVoiceIndex {
            if pulseSource == index {
                draft.noise.pulseSourceVoiceIndex = nil
            } else if pulseSource > index {
                draft.noise.pulseSourceVoiceIndex = pulseSource - 1
            }
        }

        selectedVoiceIndex = min(selectedVoiceIndex, max(0, draft.voices.count - 1))
        haptics.fireReset()
    }

    @discardableResult
    private func saveDraft() -> Bool {
        var toSave = draft
        let trimmedName = toSave.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            toSave.name = baselinePreset.name
        } else {
            toSave.name = trimmedName
        }
        toSave.recommendedOutput = AudioRoutePolicy.hasActiveBinauralVoices(in: toSave) ? .headphones : .any

        let errors = PresetValidator.validate(toSave)
        guard errors.isEmpty else {
            validationErrorMessage = validationMessage(for: errors)
            return false
        }

        do {
            let saved = try presetStore.saveEdited(toSave)
            validationErrorMessage = nil
            baselinePreset = saved
            if draft != saved {
                engineSyncedDraft = saved
            }
            draft = saved
            hasSavedInStore = true
            isDirty = false
            engine.applyEditedPreset(saved)
            onSavedPreset(saved)
            haptics.fireStep()

            showSavedBadge = true
            savedBadgeTask?.cancel()
            savedBadgeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                showSavedBadge = false
            }
            return true
        } catch {
            validationErrorMessage = error.localizedDescription
            return false
        }
    }

    private func requestDismiss() {
        if isDirty {
            showDiscardConfirmation = true
        } else {
            dismissStudio()
        }
    }

    private func revertDraftToBaseline() {
        if draft != baselinePreset {
            engineSyncedDraft = baselinePreset
        }
        draft = baselinePreset
        isDirty = false
        engine.applyEditedPreset(baselinePreset)
    }

    private func discardChangesAndDismiss() {
        revertDraftToBaseline()
        dismissStudio()
    }

    private func dismissStudio() {
        if let onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    private func validationMessage(for errors: [PresetValidationError]) -> String {
        guard let first = errors.first else {
            return String(localized: "Invalid preset configuration")
        }
        switch first {
        case .invalidDuration:
            return "\(String(localized: "Duration")): \(String(localized: "60–7200s"))"
        case .invalidVoiceCount:
            return String(localized: "Max 10 Voices")
        case .cyclicTracking:
            return "\(String(localized: "Tracking")): \(String(localized: "All other voices form a tracking chain back to this voice"))"
        default:
            return String(localized: "Invalid preset configuration")
        }
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

// MARK: - Voice Channel Strip

private struct VoiceChannelStrip: View {
    @Binding var voice: Voice
    let index: Int
    let isSelected: Bool
    let hasActiveSoloInRack: Bool
    let isPlaying: Bool
    let currentTime: Double
    let masterLevels: StripMasterLevels
    let canDuplicate: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private var safeTime: Double {
        currentTime.isFinite ? max(0.0, currentTime) : 0.0
    }

    private var currentBeatHz: Double {
        voice.beatCurve.evaluate(at: safeTime)
    }

    private var currentVolume: Double {
        let raw = voice.volumeCurve.evaluate(at: safeTime)
        return raw.isFinite ? min(1.0, max(0.0, raw)) : 0.0
    }

    private var bandColor: Color {
        BrainwaveBand.from(frequencyHz: currentBeatHz).accentColor
    }

    private var isAudible: Bool {
        voice.isEnabled && !voice.isMuted && (!hasActiveSoloInRack || voice.isSolo)
    }

    private var meterLevels: (leftRMS: Float, rightRMS: Float, leftPeak: Float, rightPeak: Float) {
        guard isPlaying && isAudible else {
            return (0, 0, 0, 0)
        }
        let vol = Float(currentVolume)
        let gainL: Float
        let gainR: Float
        if voice.mode == .binaural {
            gainL = 1.0
            gainR = 1.0
        } else {
            let clampedPan = min(1.0, max(-1.0, voice.pan))
            let angle = (clampedPan + 1.0) * 0.25 * .pi
            gainL = Float(cos(angle) * 1.41421356)
            gainR = Float(sin(angle) * 1.41421356)
        }
        return (
            min(1.0, masterLevels.rmsL * vol * gainL),
            min(1.0, masterLevels.rmsR * vol * gainR),
            min(1.0, masterLevels.peakL * vol * gainL),
            min(1.0, masterLevels.peakR * vol * gainR)
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            // Channel Header + Context Menu
            HStack(spacing: 4) {
                Text("Ch \(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? StudioTheme.chassisGraphite : StudioTheme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isSelected ? bandColor : StudioTheme.recessedWell))

                Spacer(minLength: 2)

                if voice.trackingRule != nil {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioTheme.betaColor)
                }

                Menu {
                    Button(action: onDuplicate) {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .disabled(!canDuplicate)

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!canDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.vertical, -11)
                .padding(.horizontal, -10)
                .accessibilityLabel(Text("Voice"))
            }

            // Voice Name + Mode/Waveform Glyphs
            HStack(spacing: 4) {
                ModeGlyphShape(mode: voice.mode)
                    .stroke(bandColor, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 10)

                WaveformGlyphShape(waveform: voice.waveform)
                    .stroke(StudioTheme.secondaryText, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 9)

                Text(verbatim: voice.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(voice.isEnabled ? StudioTheme.primaryText : StudioTheme.mutedText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Mute & Solo Hardware Buttons
            HStack(spacing: 5) {
                stripToggleButton(
                    symbol: "M",
                    accessibilityKey: "Mute",
                    isActive: voice.isMuted,
                    activeColor: StudioTheme.ledRed
                ) {
                    voice.isMuted.toggle()
                }

                stripToggleButton(
                    symbol: "S",
                    accessibilityKey: "Solo",
                    isActive: voice.isSolo,
                    activeColor: StudioTheme.betaColor
                ) {
                    voice.isSolo.toggle()
                }
            }

            // Fader & Live Stereo LED Meter
            let levels = meterLevels
            HStack(spacing: 6) {
                StudioFader(
                    value: volumeBinding,
                    range: PresetLimits.unitRange,
                    defaultValue: 0.7,
                    title: nil,
                    accentColor: isAudible ? bandColor : StudioTheme.mutedText,
                    orientation: .vertical,
                    showsScaleMarks: false
                )
                .frame(width: 34)

                LEDMeterView(
                    leftLevel: levels.leftRMS,
                    rightLevel: levels.rightRMS,
                    leftPeak: levels.leftPeak,
                    rightPeak: levels.rightPeak,
                    orientation: .vertical,
                    segmentCount: 12,
                    showsLabels: false
                )
                .frame(width: 22)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(7)
        .frame(width: 96, height: 170)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? StudioTheme.elevatedSurface : StudioTheme.recessedWell.opacity(0.85))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? bandColor.opacity(0.85) : StudioTheme.hairlineHighlight,
                    lineWidth: isSelected ? 1.4 : 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onSelect()
        }
    }

    private func stripToggleButton(
        symbol: String,
        accessibilityKey: LocalizedStringKey,
        isActive: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(verbatim: symbol)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? StudioTheme.chassisGraphite : StudioTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? activeColor : StudioTheme.recessedWell)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            isActive ? activeColor.opacity(0.9) : StudioTheme.hairlineHighlight,
                            lineWidth: 0.75
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityKey))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { currentVolume },
            set: { newValue in
                voice.volumeCurve = StudioCurveAdjustment.adjustVolumeCurve(
                    voice.volumeCurve,
                    toNewValue: newValue,
                    at: safeTime
                )
            }
        )
    }
}
