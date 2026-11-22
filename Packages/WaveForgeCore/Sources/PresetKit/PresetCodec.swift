import Foundation

/// Errors thrown by `PresetCodec` when decoding `.waveforge` JSON documents.
public enum PresetCodecError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

/// Versioned `.waveforge` JSON envelope wrapping a `Preset`.
public struct PresetDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var preset: Preset

    public init(schemaVersion: Int = PresetDocument.currentSchemaVersion, preset: Preset) {
        self.schemaVersion = schemaVersion
        self.preset = preset
    }
}

/// Encodes and decodes `.waveforge` JSON documents deterministically.
public enum PresetCodec {
    /// Encodes `preset` into pretty-printed, sorted-keys `.waveforge` JSON data.
    public static func encode(_ preset: Preset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PresetDocument(preset: preset))
    }

    /// Decodes `.waveforge` JSON `data` into a `Preset`, verifying schema compatibility.
    public static func decode(_ data: Data) throws -> Preset {
        let decoder = JSONDecoder()
        let document = try decoder.decode(PresetDocument.self, from: data)
        guard document.schemaVersion == PresetDocument.currentSchemaVersion else {
            throw PresetCodecError.unsupportedSchemaVersion(document.schemaVersion)
        }
        return document.preset
    }
}
