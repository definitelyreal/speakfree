import Foundation

/// Static metadata describing a selectable transcription engine. Pure data — no FluidAudio
/// import. Drives the engine picker in Settings.
public struct EngineInfo: Identifiable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Static metadata describing a downloadable Parakeet model variant. Pure data — the actual
/// download/load is owned by ParakeetModelManager.
public struct ParakeetModelInfo: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let version: String
    public let sizeDescription: String
    public let supportedLanguages: [String]

    public init(id: String,
                displayName: String,
                version: String,
                sizeDescription: String,
                supportedLanguages: [String]) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.sizeDescription = sizeDescription
        self.supportedLanguages = supportedLanguages
    }
}

/// Engine + model catalog. Pure reference data consumed by the Settings UI; no engine logic.
public enum EngineCatalog {
    public static let engines: [EngineInfo] = [
        EngineInfo(id: "whisper", displayName: "Whisper (local, CPU/GPU)"),
        EngineInfo(id: "parakeet", displayName: "Parakeet (NVIDIA, Neural Engine)")
    ]

    /// v2 (English-only, the product DEFAULT) listed FIRST so it's the top of the model
    /// dropdown, then v3 (multilingual). Selection is by id everywhere, so order is purely
    /// presentational. Sizes are approximate/vendor-reported; language lists are a short
    /// representative set, not exhaustive.
    public static let parakeetModels: [ParakeetModelInfo] = [
        ParakeetModelInfo(
            id: "parakeet-tdt-0.6b-v2",
            displayName: "Parakeet v2 (English)",
            version: "v2",
            sizeDescription: "~600 MB",
            supportedLanguages: ["en"]
        ),
        ParakeetModelInfo(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet v3 (multilingual)",
            version: "v3",
            sizeDescription: "~600 MB",
            supportedLanguages: ["en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "uk"]
        )
    ]

    /// Single source of truth for the model-id -> version-string ("v2"/"v3") mapping.
    /// Returns the matching model's `version` from `parakeetModels`, defaulting to "v3"
    /// for unknown ids.
    public static func versionString(forParakeetModelID id: String) -> String {
        parakeetModels.first { $0.id == id }?.version ?? "v3"
    }
}
