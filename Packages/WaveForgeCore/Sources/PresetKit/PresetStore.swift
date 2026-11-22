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

    /// Creates a store rooted at `storageDirectory`, loading any valid persisted `.waveforge` files.
    public init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
        self.customPresetsByID = Self.loadCustomPresets(from: storageDirectory)
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

        let targetURL = fileURL(for: id)
        try lock.withLock {
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            customPresetsByID.removeValue(forKey: id)
        }
    }

    // MARK: - Persistence Helpers

    private func persistCustom(_ preset: Preset) throws {
        let validationErrors = PresetValidator.validate(preset)
        guard validationErrors.isEmpty else {
            throw PresetStoreError.invalidPreset(validationErrors)
        }

        let encoded = try PresetCodec.encode(preset)
        let destination = fileURL(for: preset.id)

        try lock.withLock {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try encoded.write(to: destination, options: [.atomic])
            customPresetsByID[preset.id] = preset
        }
    }

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(id.uuidString).waveforge", isDirectory: false)
    }

    private static func loadCustomPresets(from directory: URL) -> [UUID: Preset] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var loaded: [UUID: Preset] = [:]
        for url in urls where url.pathExtension.lowercased() == "waveforge" {
            guard let data = try? Data(contentsOf: url),
                  let preset = try? PresetCodec.decode(data),
                  !preset.isBuiltIn,
                  !builtInIDs.contains(preset.id),
                  PresetValidator.validate(preset).isEmpty else {
                continue
            }
            loaded[preset.id] = preset
        }
        return loaded
    }
}
