import Foundation
import PresetKit
import SwiftUI
import SynthCore
import UniformTypeIdentifiers
import WaveForgeExport

/// Screen 3: Searchable preset library with category filter chips, brainwave sparklines,
/// `+ New Preset` template creation, `.bwg` / `.waveforge` file import, and duplicate/export/delete actions.
public struct LibraryView: View {
    private let engine: AudioEngineController
    private let presetStore: PresetStore
    private let presetsRevision: Int
    private let adaptiveDesktopGrid: Bool
    private let hidesDoneButton: Bool
    private let loadsDirectlyOnSelect: Bool
    private let onPresetsChanged: () -> Void
    private let onSelectPreset: (Preset) -> Void
    private let onDoubleClickPreset: ((Preset) -> Void)?
    private let onCreateNewTemplate: ((Preset) -> Void)?
    private let onOpenStudioForNewPreset: () -> Void
    private let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var environmentDismiss
    @FocusState private var isSearchFocused: Bool

    @State private var presets: [Preset] = []
    @State private var sparklineCache: [UUID: PresetSparklineSummary] = [:]
    @State private var selectedCategory: PresetCategory? = nil
    @State private var searchText: String = ""
    @State private var isShowingFileImporter: Bool = false
    #if os(macOS)
    @State private var presetDocumentToExport: WaveForgePresetFileDocument? = nil
    @State private var presetExportFilename: String = ""
    @State private var isShowingPresetExporter: Bool = false
    #endif
    @State private var importAlert: ImportAlertContent? = nil
    @State private var confirmationToastPresetName: String? = nil
    @State private var toastTask: Task<Void, Never>? = nil
    @State private var haptics = StudioControlHaptics()

    public init(
        engine: AudioEngineController,
        presetStore: PresetStore,
        presetsRevision: Int = 0,
        adaptiveDesktopGrid: Bool = false,
        hidesDoneButton: Bool = false,
        loadsDirectlyOnSelect: Bool = true,
        onPresetsChanged: @escaping () -> Void = {},
        onSelectPreset: @escaping (Preset) -> Void = { _ in },
        onDoubleClickPreset: ((Preset) -> Void)? = nil,
        onCreateNewTemplate: ((Preset) -> Void)? = nil,
        onOpenStudioForNewPreset: @escaping () -> Void = {},
        onDismiss: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.presetStore = presetStore
        self.presetsRevision = presetsRevision
        self.adaptiveDesktopGrid = adaptiveDesktopGrid
        self.hidesDoneButton = hidesDoneButton
        self.loadsDirectlyOnSelect = loadsDirectlyOnSelect
        self.onPresetsChanged = onPresetsChanged
        self.onSelectPreset = onSelectPreset
        self.onDoubleClickPreset = onDoubleClickPreset
        self.onCreateNewTemplate = onCreateNewTemplate
        self.onOpenStudioForNewPreset = onOpenStudioForNewPreset
        self.onDismiss = onDismiss
    }

    private var accentColor: Color {
        engine.dominantBand.accentColor
    }

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPresets: [Preset] {
        let query = trimmedSearchQuery
        return presets.filter { preset in
            if let selectedCategory, preset.category != selectedCategory {
                return false
            }
            guard !query.isEmpty else { return true }

            if preset.name.localizedCaseInsensitiveContains(query) {
                return true
            }
            if Self.localizedSummary(for: preset).localizedCaseInsensitiveContains(query) {
                return true
            }
            if Self.localizedCategoryName(for: preset.category).localizedCaseInsensitiveContains(query) {
                return true
            }
            if let summary = sparklineCache[preset.id],
               summary.dominantBand.localizedTitle.localizedCaseInsensitiveContains(query) {
                return true
            }
            return false
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                StudioTheme.rackBackgroundGradient
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    categoryFilterBar
                    quickActionsBar
                    presetListContent
                }
                .padding(.top, 6)

                if let toastName = confirmationToastPresetName {
                    ImportConfirmationToast(presetName: toastName) {
                        dismissConfirmationToast()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .navigationTitle("Library")
            .wfInlineNavigationBarDark()
            .wfSearchable(text: $searchText, prompt: Text("Search Presets"))
            .searchFocused($isSearchFocused)
            .toolbar {
                if !hidesDoneButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismissLibrary()
                        }
                        .foregroundStyle(accentColor)
                    }
                }
            }
        }
        .focusedValue(\.isTextInputFocused, isSearchFocused)
        .focusedSceneValue(\.isTextInputFocused, isSearchFocused)
        .preferredColorScheme(.dark)
        .onAppear {
            reloadPresets()
        }
        .onChange(of: presetsRevision) { _, _ in
            reloadPresets()
        }
        .onDisappear {
            toastTask?.cancel()
            toastTask = nil
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.waveForgePreset, .brainWaveGenerator],
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
        #if os(macOS)
        .fileExporter(
            isPresented: $isShowingPresetExporter,
            document: presetDocumentToExport,
            contentType: .waveForgePreset,
            defaultFilename: presetExportFilename
        ) { result in
            presetDocumentToExport = nil
            if case .failure(let error) = result {
                if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                    return
                }
                importAlert = ImportAlertContent(kind: .failure(message: error.localizedDescription))
            }
        }
        #endif
        .importResultAlert($importAlert)
        .animation(.easeInOut(duration: 0.22), value: confirmationToastPresetName != nil)
    }

    // MARK: - Category Filter Chips

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(
                    titleKey: "All",
                    count: presets.count,
                    isSelected: selectedCategory == nil
                ) {
                    selectCategory(nil)
                }

                ForEach(PresetCategory.allCases, id: \.self) { category in
                    let count = presets.count { $0.category == category }
                    categoryChip(
                        titleKey: Self.categoryTitleKey(for: category),
                        count: count,
                        isSelected: selectedCategory == category
                    ) {
                        selectCategory(category)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func categoryChip(
        titleKey: LocalizedStringKey,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(titleKey)
                    .font(.caption.weight(isSelected ? .bold : .semibold))
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .opacity(isSelected ? 0.8 : 0.65)
            }
            .foregroundStyle(isSelected ? StudioTheme.chassisGraphite : StudioTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(isSelected ? accentColor : StudioTheme.obsidianSurface)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? accentColor.opacity(0.95) : StudioTheme.hairlineHighlight,
                        lineWidth: isSelected ? 1.0 : 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Quick Studio Action Bar (+ New Preset & Import)

    private var quickActionsBar: some View {
        HStack(spacing: 10) {
            Button {
                createNewTemplatePreset()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("New Preset")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundStyle(StudioTheme.chassisGraphite)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background {
                    Capsule()
                        .fill(accentColor)
                }
            }
            .buttonStyle(.plain)

            Button {
                haptics.prepare()
                isShowingFileImporter = true
                haptics.fireModeShift()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                    Text("Import Preset")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundStyle(StudioTheme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .studioGlassCapsule(tint: accentColor.opacity(0.12), interactive: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Preset List & Empty State

    @ViewBuilder
    private var presetListContent: some View {
        let items = filteredPresets
        if items.isEmpty {
            emptyStateView
        } else if adaptiveDesktopGrid {
            GeometryReader { proxy in
                let columnCount = proxy.size.width >= 640 ? 2 : 1
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                    count: columnCount
                )
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { preset in
                            presetCard(for: preset, stretchHeight: columnCount > 1)
                                .contextMenu {
                                    presetMenuItems(for: preset)
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
        } else {
            List {
                ForEach(items) { preset in
                    presetCard(for: preset, stretchHeight: false)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                duplicatePreset(preset)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(StudioTheme.alphaColor)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !preset.isBuiltIn {
                                Button(role: .destructive) {
                                    deleteCustomPreset(preset)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            presetMenuItems(for: preset)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func presetCard(for preset: Preset, stretchHeight: Bool) -> some View {
        let isActive = engine.currentPreset.id == preset.id
        let sparkline = sparklineCache[preset.id] ?? PresetSparklineSummary.analyze(preset)

        return PresetLibraryCard(
            preset: preset,
            localizedSummary: Self.localizedSummary(for: preset),
            sparkline: sparkline,
            isActive: isActive,
            isPlaying: isActive && engine.isPlaying,
            stretchHeight: stretchHeight,
            onSelect: {
                selectPreset(preset)
            },
            onDoubleClick: onDoubleClickPreset != nil ? {
                doubleClickPreset(preset)
            } : nil,
            menuItems: {
                presetMenuItems(for: preset)
            }
        )
    }

    @ViewBuilder
    private func presetMenuItems(for preset: Preset) -> some View {
        Button {
            duplicatePreset(preset)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        #if os(macOS)
        Button {
            exportPresetAsWaveForge(preset)
        } label: {
            Label("Save .waveforge…", systemImage: "arrow.down.doc")
        }
        #endif

        ShareLink(
            item: WaveForgePresetDocument(preset: preset),
            preview: SharePreview(
                preset.name,
                image: Image(systemName: "waveform.path.ecg")
            )
        ) {
            Label("Export .waveforge", systemImage: "square.and.arrow.up")
        }

        if !preset.isBuiltIn {
            Divider()
            Button(role: .destructive) {
                deleteCustomPreset(preset)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var emptyStateView: some View {
        let isCustomEmpty = selectedCategory == .custom && trimmedSearchQuery.isEmpty
        return VStack(spacing: 12) {
            Spacer(minLength: 24)

            Image(systemName: isCustomEmpty ? "slider.horizontal.3" : "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(StudioTheme.secondaryText)

            Text(isCustomEmpty ? "No Custom Presets Yet" : "No Matching Presets")
                .font(.headline)
                .foregroundStyle(StudioTheme.primaryText)

            Text(
                isCustomEmpty
                    ? "Create a new preset in Studio or import a .bwg / .waveforge file."
                    : "Try a different search term or category filter."
            )
            .font(.subheadline)
            .foregroundStyle(StudioTheme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)

            if !trimmedSearchQuery.isEmpty || selectedCategory != nil {
                Button {
                    searchText = ""
                    selectedCategory = nil
                    haptics.fireModeShift()
                } label: {
                    Text("Reset")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.chassisGraphite)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(accentColor))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func reloadPresets() {
        let loaded = presetStore.allPresets()
        guard loaded != presets else { return }
        presets = loaded

        var updatedCache: [UUID: PresetSparklineSummary] = [:]
        updatedCache.reserveCapacity(loaded.count)
        for preset in loaded {
            updatedCache[preset.id] = PresetSparklineSummary.analyze(preset)
        }
        sparklineCache = updatedCache
    }

    private func selectCategory(_ category: PresetCategory?) {
        guard selectedCategory != category else { return }
        haptics.prepare()
        withAnimation(.easeOut(duration: 0.16)) {
            selectedCategory = category
        }
        haptics.fireModeShift()
    }

    private func selectPreset(_ preset: Preset) {
        haptics.prepare()
        if loadsDirectlyOnSelect {
            engine.load(preset)
        }
        onSelectPreset(preset)
        haptics.fireStep()
        if !hidesDoneButton {
            dismissLibrary()
        }
    }

    private func doubleClickPreset(_ preset: Preset) {
        haptics.prepare()
        if loadsDirectlyOnSelect {
            engine.load(preset)
            engine.play()
        }
        if let onDoubleClickPreset {
            onDoubleClickPreset(preset)
        } else {
            onSelectPreset(preset)
        }
        haptics.fireStep()
    }

    private func createNewTemplatePreset() {
        haptics.prepare()
        let template = Self.makeTemplatePreset()
        if loadsDirectlyOnSelect {
            engine.load(template)
        }
        haptics.fireStep()
        if let onCreateNewTemplate {
            onCreateNewTemplate(template)
        } else {
            if !loadsDirectlyOnSelect {
                engine.load(template)
            }
            onOpenStudioForNewPreset()
        }
    }

    #if os(macOS)
    private func exportPresetAsWaveForge(_ preset: Preset) {
        presetExportFilename = WaveForgePresetDocument.sanitizedFileName(for: preset.name)
        presetDocumentToExport = WaveForgePresetFileDocument(preset: preset)
        isShowingPresetExporter = true
    }
    #endif

    private func duplicatePreset(_ preset: Preset) {
        haptics.prepare()
        var copy = preset
        copy.id = UUID()
        copy.isBuiltIn = false
        if preset.isBuiltIn {
            copy.category = .custom
        }
        copy.name = "\(preset.name) (\(String(localized: "Copy")))"
        copy.voices = preset.voices.map { voice in
            var duplicatedVoice = voice
            duplicatedVoice.id = UUID()
            return duplicatedVoice
        }
        copy.recommendedOutput = AudioRoutePolicy.hasActiveBinauralVoices(in: copy) ? .headphones : .any

        do {
            try presetStore.saveCustom(copy)
            reloadPresets()
            onPresetsChanged()
            haptics.fireStep()
        } catch {
            importAlert = ImportAlertContent.fromError(error)
        }
    }

    private func deleteCustomPreset(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        haptics.prepare()
        do {
            try Self.performCustomPresetDeletion(
                preset,
                presetStore: presetStore,
                engine: engine,
                loadsDirectlyOnSelect: loadsDirectlyOnSelect,
                onSelectPreset: onSelectPreset
            )
            reloadPresets()
            onPresetsChanged()
            haptics.fireReset()
        } catch {
            importAlert = ImportAlertContent.fromError(error)
        }
    }

    internal static func performCustomPresetDeletion(
        _ preset: Preset,
        presetStore: PresetStore,
        engine: AudioEngineController,
        loadsDirectlyOnSelect: Bool,
        onSelectPreset: (Preset) -> Void
    ) throws {
        guard !preset.isBuiltIn else { return }
        try presetStore.deleteCustom(id: preset.id)
        if engine.currentPreset.id == preset.id {
            let fallbackPreset = PresetCatalog.builtInPresets[0]
            if loadsDirectlyOnSelect {
                engine.load(fallbackPreset)
            } else {
                onSelectPreset(fallbackPreset)
            }
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let outcome = try PresetImportCoordinator.importFile(at: url, into: presetStore)
                reloadPresets()
                onPresetsChanged()
                if loadsDirectlyOnSelect {
                    engine.load(outcome.preset)
                } else {
                    onSelectPreset(outcome.preset)
                }
                haptics.fireStep()

                if let alert = ImportAlertContent.fromOutcome(outcome) {
                    importAlert = alert
                } else {
                    showConfirmationToast(for: outcome.preset.name)
                }
            } catch {
                importAlert = ImportAlertContent.fromError(error)
            }

        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            importAlert = ImportAlertContent.fromError(error)
        }
    }

    private func showConfirmationToast(for presetName: String) {
        toastTask?.cancel()
        confirmationToastPresetName = presetName
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            confirmationToastPresetName = nil
        }
    }

    private func dismissConfirmationToast() {
        toastTask?.cancel()
        toastTask = nil
        confirmationToastPresetName = nil
    }

    private func dismissLibrary() {
        if let onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    // MARK: - Template & Localization Helpers

    /// Builds a valid starter custom preset (30 min Alpha 10 Hz Binaural) ready for immediate Studio editing.
    public static func makeTemplatePreset() -> Preset {
        let starterVoice = Voice(
            id: UUID(),
            name: String(localized: "Voice \(1)"),
            isEnabled: true,
            isMuted: false,
            isSolo: false,
            mode: .binaural,
            waveform: .sine,
            isochronicSoftness: 0.5,
            isochronicDutyCycle: 0.5,
            pan: 0.0,
            carrierCurve: EnvelopeCurve(
                points: [CurvePoint(timeSec: 0.0, value: 200.0)],
                interpolation: .linear
            ),
            beatCurve: EnvelopeCurve(
                points: [CurvePoint(timeSec: 0.0, value: 10.0)],
                interpolation: .smoothStep
            ),
            volumeCurve: EnvelopeCurve(
                points: [CurvePoint(timeSec: 0.0, value: 0.7)],
                interpolation: .linear
            ),
            trackingRule: nil
        )

        let starterNoise = NoiseLayer(
            isEnabled: false,
            volumeCurve: EnvelopeCurve(
                points: [CurvePoint(timeSec: 0.0, value: 0.15)],
                interpolation: .linear
            ),
            smoothnessCurve: EnvelopeCurve(
                points: [CurvePoint(timeSec: 0.0, value: 0.5)],
                interpolation: .linear
            ),
            pulseEnabled: false,
            pulseDepth: 0.0,
            pulseSourceVoiceIndex: nil
        )

        return Preset(
            id: UUID(),
            name: String(localized: "New Preset"),
            category: .custom,
            summary: "Custom studio session",
            durationSec: 1800.0,
            recommendedOutput: .headphones,
            masterGain: 0.85,
            fadeInSec: 15.0,
            fadeOutSec: 20.0,
            noise: starterNoise,
            voices: [starterVoice],
            isBuiltIn: false
        )
    }

    private static let localizablePresetSummaries: Set<String> = {
        var summaries = Set(PresetCatalog.builtInPresets.map(\.summary))
        summaries.insert("Imported from BrainWave Generator (.bwg)")
        summaries.insert("Custom studio session")
        return summaries
    }()

    static func localizedSummary(for preset: Preset) -> String {
        if preset.isBuiltIn || localizablePresetSummaries.contains(preset.summary) {
            return String(localized: String.LocalizationValue(preset.summary))
        }
        return preset.summary
    }

    static func categoryTitleKey(for category: PresetCategory) -> LocalizedStringKey {
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

    static func localizedCategoryName(for category: PresetCategory) -> String {
        switch category {
        case .focus: return String(localized: "Focus")
        case .relax: return String(localized: "Relax")
        case .sleep: return String(localized: "Sleep")
        case .meditation: return String(localized: "Meditation")
        case .study: return String(localized: "Study")
        case .creative: return String(localized: "Creative")
        case .custom: return String(localized: "Custom")
        }
    }
}

// MARK: - Preset Library Card

private struct PresetLibraryCard<MenuItems: View>: View {
    let preset: Preset
    let localizedSummary: String
    let sparkline: PresetSparklineSummary
    let isActive: Bool
    let isPlaying: Bool
    let stretchHeight: Bool
    let onSelect: () -> Void
    let onDoubleClick: (() -> Void)?
    @ViewBuilder let menuItems: () -> MenuItems

    private var bandColor: Color {
        sparkline.dominantBand.accentColor
    }

    var body: some View {
        let cardContent = VStack(alignment: .leading, spacing: 10) {
            headerRow

            if !localizedSummary.isEmpty {
                Text(verbatim: localizedSummary)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if stretchHeight {
                Spacer(minLength: 0)
            }

            PresetSparklineView(summary: sparkline)
                .frame(height: 44)

            metadataFooterRow
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: stretchHeight ? .infinity : nil, alignment: .topLeading)
        .studioRackCard(
            cornerRadius: 16,
            borderColor: isActive ? bandColor.opacity(0.75) : StudioTheme.hairlineHighlight
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        if let onDoubleClick {
            cardContent
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { onDoubleClick() }
                        .exclusively(before: TapGesture(count: 1).onEnded { onSelect() })
                )
        } else {
            cardContent
                .onTapGesture {
                    onSelect()
                }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: preset.name)
                        .font(.headline)
                        .foregroundStyle(StudioTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isActive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(bandColor)
                                .frame(width: 6, height: 6)
                                .shadow(color: bandColor.opacity(0.85), radius: 3)
                            Text(isPlaying ? "Playing" : "Active")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(bandColor)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(bandColor.opacity(0.16)))
                    }
                }

                HStack(spacing: 6) {
                    Text(LibraryView.categoryTitleKey(for: preset.category))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudioTheme.secondaryText)

                    Text(verbatim: "•")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.mutedText)

                    Text(preset.isBuiltIn ? "Built-in" : "Custom")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(preset.isBuiltIn ? StudioTheme.mutedText : bandColor.opacity(0.9))

                    Text(verbatim: "•")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.mutedText)

                    Text("\(preset.voices.count) Voices")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(StudioTheme.mutedText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                menuItems()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Preset Actions"))
        }
    }

    private var metadataFooterRow: some View {
        HStack(spacing: 8) {
            BrainwaveBandBadge(
                band: sparkline.dominantBand,
                beatHz: sparkline.dominantBeatHz,
                compact: true
            )

            Spacer(minLength: 4)

            // Duration badge
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: StudioTheme.formatTime(preset.durationSec))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(StudioTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(StudioTheme.recessedWell))
            .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.6))

            // Headphone / Output indicator
            let needsHeadphones = preset.recommendedOutput == .headphones
            HStack(spacing: 4) {
                Image(systemName: needsHeadphones ? "headphones" : "speaker.wave.2")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(needsHeadphones ? StudioTheme.alphaColor : StudioTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    needsHeadphones ? StudioTheme.alphaColor.opacity(0.14) : StudioTheme.recessedWell
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    needsHeadphones ? StudioTheme.alphaColor.opacity(0.4) : StudioTheme.hairlineHighlight,
                    lineWidth: 0.6
                )
            )
            .accessibilityLabel(Text(needsHeadphones ? "Headphones Recommended" : "Any Output"))
        }
    }
}

#if os(macOS)
private struct WaveForgePresetFileDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.waveForgePreset] }

    let preset: Preset

    init(preset: Preset) {
        self.preset = preset
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw PresetImportError.unreadableFile
        }
        self.preset = try PresetCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try PresetCodec.encode(preset)
        return FileWrapper(regularFileWithContents: data)
    }
}
#endif
