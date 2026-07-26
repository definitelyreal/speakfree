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

    // MARK: - Whisper models

    /// One selectable Whisper model, in both its English-only and multilingual forms.
    ///
    /// Moved here 2026-07-26. This table used to live as a `private let raw` inside
    /// `availableModels(language:)` in SettingsWindow.swift, and the Help window carried its own
    /// hand-typed copy — which drifted badly: Help listed a bare `large` (not selectable since
    /// the large row resolves to `large-v3`), omitted `large-v3` and `large-v3-turbo` entirely,
    /// and marked `small.en` "Recommended" when the recommendation is RAM-dependent. Duplicated
    /// reference data was the root cause of the whole help audit, so there is now one table and
    /// both surfaces read it.
    public struct WhisperModelInfo: Identifiable, Hashable {
        public let englishID: String
        public let multilingualID: String
        /// Family key used for the RAM-based recommendation and for English/multilingual choice.
        public let base: String
        public let memoryDescription: String
        public let loadTimeDescription: String

        public var id: String { base }

        /// The id actually selected for a given language. The large family has no `.en` build.
        public func id(forLanguage language: String) -> String {
            (language == "en" && base != "large") ? englishID : multilingualID
        }
    }

    public static let whisperModels: [WhisperModelInfo] = [
        WhisperModelInfo(englishID: "tiny.en", multilingualID: "tiny", base: "tiny",
                         memoryDescription: "~230 MB", loadTimeDescription: "~0.2s"),
        WhisperModelInfo(englishID: "base.en", multilingualID: "base", base: "base",
                         memoryDescription: "~330 MB", loadTimeDescription: "~0.3s"),
        WhisperModelInfo(englishID: "small.en", multilingualID: "small", base: "small",
                         memoryDescription: "~800 MB", loadTimeDescription: "~0.5s"),
        WhisperModelInfo(englishID: "medium.en", multilingualID: "medium", base: "medium",
                         memoryDescription: "~2.1 GB", loadTimeDescription: "~1.0s"),
        WhisperModelInfo(englishID: "large-v3-turbo", multilingualID: "large-v3-turbo",
                         base: "turbo",
                         memoryDescription: "~1.6 GB", loadTimeDescription: "~1.1s"),
        WhisperModelInfo(englishID: "large-v3", multilingualID: "large-v3", base: "large",
                         memoryDescription: "~3.9 GB", loadTimeDescription: "~2.0s"),
    ]

    /// Look up a model by either of its ids. Also resolves the legacy bare `"large"` that old
    /// configs and the CLI still accept but the picker never offers.
    public static func whisperModel(forID id: String) -> WhisperModelInfo? {
        if let exact = whisperModels.first(where: { $0.englishID == id || $0.multilingualID == id }) {
            return exact
        }
        // Fall back to the family, so a hand-edited or quantized id ("large-v2", "base.en-q5_1")
        // still yields real figures instead of putting "Unknown" in the Settings UI. The old
        // per-function switch statements normalized like this; losing it was a regression the
        // delegation introduced (2026-07-26 round-3 review).
        let family = normalizedFamily(id)
        return whisperModels.first { $0.base == family }
    }

    /// Reduce a model id to its family key: strip a language suffix (".en") and any version or
    /// quantization suffix ("-v3", "-q5_1"), then map the turbo special case.
    static func normalizedFamily(_ id: String) -> String {
        let lowered = id.lowercased()
        if lowered.contains("turbo") { return "turbo" }
        let withoutLanguage = lowered.components(separatedBy: ".").first ?? lowered
        return withoutLanguage.components(separatedBy: "-").first ?? withoutLanguage
    }

    /// Which model family is recommended on THIS Mac. The recommendation is RAM-dependent, so
    /// there is no single "recommended model" to name in prose.
    public static func recommendedWhisperBase(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> String {
        let ramGB = physicalMemoryBytes / (1024 * 1024 * 1024)
        if ramGB >= 16 { return "turbo" }
        if ramGB > 8 { return "small" }
        return "base"
    }
}
