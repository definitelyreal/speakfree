import Foundation
import Combine

/// Bridges the Config struct to SwiftUI-friendly @Published properties.
/// Use with ObservableObject for macOS 13+ (Ventura) compatibility.
public class SettingsViewModel: ObservableObject {

    // MARK: - Published properties

    @Published public var hotkeyKeyCode: UInt16
    @Published public var hotkeyModifiers: [String]
    @Published public var toggleMode: Bool
    @Published public var modelSize: String
    @Published public var language: String
    @Published public var punctuationMode: PunctuationMode
    @Published public var maxRecordings: Int
    @Published public var screenContext: Bool
    @Published public var rememberWords: Bool
    @Published public var preBuffer: Bool
    @Published public var keepModelLoaded: String
    @Published public var diagnosticLogging: Bool
    @Published public var streamingEnabled: Bool
    @Published public var languageModels: [String: String]
    @Published public var engine: String
    @Published public var parakeetModel: String

    // MARK: - Callback

    /// Called after save() writes the config to disk.
    /// AppDelegate can use this to reload the running configuration.
    public var onSave: (() -> Void)?

    // MARK: - Init

    /// Initialize from an existing Config, or load from disk.
    public init(config: Config? = nil) {
        let c = config ?? Config.load()

        self.hotkeyKeyCode = c.hotkey.keyCode
        self.hotkeyModifiers = c.hotkey.modifiers
        self.toggleMode = c.toggleMode?.value ?? false
        self.modelSize = c.modelSize
        self.language = c.language
        self.punctuationMode = c.spokenPunctuation ?? .hybrid
        self.maxRecordings = c.maxRecordings ?? Config.defaultMaxRecordings
        self.screenContext = c.screenContext?.value ?? true
        self.rememberWords = c.rememberWords?.value ?? true
        self.preBuffer = c.preBuffer?.value ?? true
        self.keepModelLoaded = c.keepModelLoaded ?? "auto"
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        self.diagnosticLogging = c.diagnosticLogging?.value ?? isBeta
        self.streamingEnabled = c.streamingEnabled?.value ?? false
        self.languageModels = c.languageModels ?? [:]
        self.engine = c.engine ?? "whisper"
        self.parakeetModel = c.parakeetModel ?? "parakeet-tdt-0.6b-v3"
    }

    // MARK: - Conversion

    /// Convert the current view model state back to a Config struct.
    public func toConfig() -> Config {
        var config = Config(
            hotkey: HotkeyConfig(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers),
            modelPath: nil,
            modelSize: modelSize,
            language: language,
            spokenPunctuation: punctuationMode,
            maxRecordings: maxRecordings,
            toggleMode: FlexBool(toggleMode),
            screenContext: FlexBool(screenContext),
            rememberWords: FlexBool(rememberWords),
            preBuffer: FlexBool(preBuffer),
            keepModelLoaded: keepModelLoaded,
            diagnosticLogging: FlexBool(diagnosticLogging),
            streamingEnabled: FlexBool(streamingEnabled),
            languageModels: languageModels.isEmpty ? nil : languageModels
        )
        config.engine = engine
        config.parakeetModel = parakeetModel
        return config
    }

    /// Save the current settings to disk and notify the callback.
    public func save() {
        let config = toConfig()
        try? config.save()
        onSave?()
    }

    // MARK: - Engine-aware model list

    /// Returns the selectable model identifiers for the currently-selected engine.
    /// Whisper: size-string IDs (English variants when language=="en", except large);
    /// Parakeet: the IDs from EngineCatalog.parakeetModels.
    /// Does not break the existing whisper availableModels(language:) in SettingsWindow.
    public func availableModelIDs() -> [String] {
        if engine == "parakeet" {
            return EngineCatalog.parakeetModels.map(\.id)
        }
        return SettingsViewModel.whisperModelIDs(language: language)
    }

    /// Whisper model IDs for the given language. Mirrors the ID derivation in
    /// SettingsWindow.availableModels(language:): English-specific variants for
    /// non-large bases when language=="en", multilingual IDs otherwise.
    static func whisperModelIDs(language: String) -> [String] {
        let isEnglish = (language == "en")
        let raw: [(enId: String, multiId: String, base: String)] = [
            ("tiny.en",       "tiny",           "tiny"),
            ("base.en",       "base",           "base"),
            ("small.en",      "small",          "small"),
            ("medium.en",     "medium",         "medium"),
            ("large-v3-turbo", "large-v3-turbo", "turbo"),
            ("large-v3",      "large-v3",       "large"),
        ]
        return raw.map { (isEnglish && $0.base != "large") ? $0.enId : $0.multiId }
    }

    // MARK: - Model description helpers

    /// Returns an estimated RAM usage string for the given Whisper model size.
    /// Benchmarked on M3 Max.
    public static func modelMemoryDescription(_ model: String) -> String {
        if model == "large-v3-turbo" { return "~1.2 GB" }
        switch normalizedModelBase(model) {
        case "tiny":   return "~230 MB"
        case "base":   return "~330 MB"
        case "small":  return "~800 MB"
        case "medium": return "~2.1 GB"
        case "large":  return "~3.9 GB"
        default:       return "Unknown"
        }
    }

    /// Returns an estimated transcription speed string for the given Whisper model size.
    /// Benchmarked on M3 Max.
    public static func modelSpeedDescription(_ model: String) -> String {
        if model == "large-v3-turbo" { return "~0.7s" }
        switch normalizedModelBase(model) {
        case "tiny":   return "~0.6s"
        case "base":   return "~0.6s"
        case "small":  return "~0.6s"
        case "medium": return "~1.3s"
        case "large":  return "~2.1s"
        default:       return "Unknown"
        }
    }

    /// Returns an estimated model load time string for the given Whisper model size.
    public static func modelLoadTimeDescription(_ model: String) -> String {
        if model == "large-v3-turbo" { return "~0.8s" }
        switch normalizedModelBase(model) {
        case "tiny":   return "~0.2s"
        case "base":   return "~0.3s"
        case "small":  return "~0.5s"
        case "medium": return "~1.0s"
        case "large":  return "~2.0s"
        default:       return "unknown"
        }
    }

    /// Returns the download size string for the given Whisper model size.
    public static func modelDownloadSize(_ model: String) -> String {
        if model == "large-v3-turbo" { return "1.5 GB" }
        switch normalizedModelBase(model) {
        case "tiny":   return "75 MB"
        case "base":   return "142 MB"
        case "small":  return "466 MB"
        case "medium": return "1.5 GB"
        case "large":  return "3.1 GB"
        default:       return "unknown"
        }
    }

    /// Returns true if this model is the recommended choice for new users.
    public static func isRecommendedModel(_ model: String) -> Bool {
        return model == "large-v3-turbo"
    }

    /// Check if a model file exists on disk.
    public static func modelExists(_ modelSize: String) -> Bool {
        let modelFileName = "ggml-\(modelSize).bin"
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let destPath = modelsDir.appendingPathComponent(modelFileName)
        return FileManager.default.fileExists(atPath: destPath.path)
    }

    /// Returns the path to the models directory.
    public static var modelsDirectory: URL {
        Config.configDir.appendingPathComponent("models")
    }

    // MARK: - Private helpers

    /// Normalize model identifiers like "small.en", "large-v3" to their base name.
    static func normalizedModelBase(_ model: String) -> String {
        let lowered = model.lowercased()
        // Strip language suffixes like ".en"
        let withoutLang = lowered.components(separatedBy: ".").first ?? lowered
        // Strip version suffixes like "-v3"
        let withoutVersion = withoutLang.components(separatedBy: "-").first ?? withoutLang
        return withoutVersion
    }
}
