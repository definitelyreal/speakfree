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

    /// v3 default first (multilingual), then v2 (English-only). Sizes are approximate and
    /// vendor-reported. Language lists are a short representative set, not exhaustive.
    public static let parakeetModels: [ParakeetModelInfo] = [
        ParakeetModelInfo(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet v3 (multilingual)",
            version: "v3",
            sizeDescription: "~600 MB",
            supportedLanguages: ["en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "uk"]
        ),
        ParakeetModelInfo(
            id: "parakeet-tdt-0.6b-v2",
            displayName: "Parakeet v2 (English)",
            version: "v2",
            sizeDescription: "~600 MB",
            supportedLanguages: ["en"]
        )
    ]
}
