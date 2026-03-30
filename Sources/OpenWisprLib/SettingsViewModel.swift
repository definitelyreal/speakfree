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
    @Published public var languageModels: [String: String]

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
        self.screenContext = c.screenContext?.value ?? false
        self.rememberWords = c.rememberWords?.value ?? false
        self.preBuffer = c.preBuffer?.value ?? true
        self.keepModelLoaded = c.keepModelLoaded ?? "auto"
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        self.diagnosticLogging = c.diagnosticLogging?.value ?? isBeta
        self.languageModels = c.languageModels ?? [:]
    }

    // MARK: - Conversion

    /// Convert the current view model state back to a Config struct.
    public func toConfig() -> Config {
        Config(
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
            languageModels: languageModels.isEmpty ? nil : languageModels
        )
    }

    /// Save the current settings to disk and notify the callback.
    public func save() {
        let config = toConfig()
        try? config.save()
        onSave?()
    }

    // MARK: - Model description helpers

    /// Returns an estimated RAM usage string for the given Whisper model size.
    /// Benchmarked on M3 Max.
    public static func modelMemoryDescription(_ model: String) -> String {
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
        switch normalizedModelBase(model) {
        case "tiny":   return "75 MB"
        case "base":   return "142 MB"
        case "small":  return "466 MB"
        case "medium": return "1.5 GB"
        case "large":  return "3.1 GB"
        default:       return "unknown"
        }
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
