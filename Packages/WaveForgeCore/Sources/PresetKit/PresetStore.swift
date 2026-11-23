import Foundation

/// Errors thrown by `PresetStore` when persisting or deleting presets.
public enum PresetStoreError: Error, Equatable, Sendable {
    case cannotModifyBuiltIn
    case invalidPreset([PresetValidationError])
}

/// Thread-safe local `.waveforge` preset repository combining the 18 immutable built-in presets
/// with user-created, imported, and edited custom presets persisted on disk.
public final class PresetStore: @unchecked Sendable {
    private static let builtInIDs: Set<UUID> = Set(PresetCatalog.builtInPresets.map(\.id))

    private let storageDirectory: URL
    private let lock = NSLock()
    private var customPresetsByID: [UUID: Preset]
    private var customFileURLsByID: [UUID: URL]

    /// Creates a store rooted at `storageDirectory`, loading any valid persisted `.waveforge` files.
    public init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
        let loaded = Self.loadCustomPresets(from: storageDirectory)
        self.customPresetsByID = loaded.presets
        self.customFileURLsByID = loaded.fileURLs
    }

    /// Returns all 18 built-in presets followed by deterministically sorted custom presets.
    public func allPresets() -> [Preset] {
        let custom = lock.withLock {
            customPresetsByID.values.sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        return PresetCatalog.builtInPresets + custom
    }

    /// Persists a custom preset atomically to `<id>.waveforge`.
    /// Rejects built-in presets or presets failing `PresetValidator`.
    public func saveCustom(_ preset: Preset) throws {
        guard !preset.isBuiltIn, !Self.builtInIDs.contains(preset.id) else {
            throw PresetStoreError.cannotModifyBuiltIn
        }
        try persistCustom(preset)
    }

    /// Saves edits to `preset`.
    /// Any built-in preset (by `isBuiltIn` or matching a catalog ID) is automatically forked
    /// into a new `UUID`, `isBuiltIn = false`, and `category = .custom` before saving atomically.
    @discardableResult
    public func saveEdited(_ preset: Preset) throws -> Preset {
        var toSave = preset
        if preset.isBuiltIn || Self.builtInIDs.contains(preset.id) {
            toSave.id = UUID()
            toSave.isBuiltIn = false
            toSave.category = .custom
        } else {
            toSave.isBuiltIn = false
        }

        try persistCustom(toSave)
        return toSave
    }

    /// Deletes a custom preset by `id` from both memory and disk.
    /// Built-in presets cannot be deleted and throw `PresetStoreError.cannotModifyBuiltIn`.
    public func deleteCustom(id: UUID) throws {
        guard !Self.builtInIDs.contains(id) else {
            throw PresetStoreError.cannotModifyBuiltIn
        }

        let canonicalURL = fileURL(for: id)
        try lock.withLock {
            let trackedURL = customFileURLsByID[id] ?? canonicalURL
            if FileManager.default.fileExists(atPath: trackedURL.path) {
                try FileManager.default.removeItem(at: trackedURL)
            }
            if trackedURL != canonicalURL, FileManager.default.fileExists(atPath: canonicalURL.path) {
                try FileManager.default.removeItem(at: canonicalURL)
            }
            customPresetsByID.removeValue(forKey: id)
            customFileURLsByID.removeValue(forKey: id)
        }
    }

    // MARK: - Persistence Helpers

    private func persistCustom(_ preset: Preset) throws {
        let validationErrors = PresetValidator.validate(preset)
        guard validationErrors.isEmpty else {
            throw PresetStoreError.invalidPreset(validationErrors)
        }

        let encoded = try PresetCodec.encode(preset)
        let defaultURL = fileURL(for: preset.id)

        try lock.withLock {
            let destination = customFileURLsByID[preset.id] ?? defaultURL
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try encoded.write(to: destination, options: [.atomic])
            customPresetsByID[preset.id] = preset
            customFileURLsByID[preset.id] = destination
        }
    }

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(id.uuidString).waveforge", isDirectory: false)
    }

    private static func loadCustomPresets(from directory: URL) -> (presets: [UUID: Preset], fileURLs: [UUID: URL]) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([:], [:])
        }

        var loadedPresets: [UUID: Preset] = [:]
        var loadedURLs: [UUID: URL] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension.lowercased() == "waveforge" {
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true,
                  (resourceValues?.fileSize ?? 0) <= PresetLimits.maxImportFileBytes,
                  let data = try? Data(contentsOf: url),
                  let preset = try? PresetCodec.decode(data),
                  !preset.isBuiltIn,
                  !builtInIDs.contains(preset.id),
                  PresetValidator.validate(preset).isEmpty else {
                continue
            }
            loadedPresets[preset.id] = preset
            loadedURLs[preset.id] = url
        }
        return (loadedPresets, loadedURLs)
    }
}
