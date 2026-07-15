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
    @Published public var preBuffer: Bool
    @Published public var keepModelLoaded: String
    @Published public var diagnosticLogging: Bool
    @Published public var streamingEnabled: Bool
    @Published public var languageModels: [String: String]
    @Published public var engine: String
    @Published public var parakeetModel: String
    @Published public var localAPIEnabled: Bool
    @Published public var localAPIPort: Int
    @Published public var saveRecordings: Bool

    // MARK: - Callback

    /// Called after save() writes the config to disk.
    /// AppDelegate can use this to reload the running configuration.
    public var onSave: (() -> Void)?

    /// The config this view model was initialized from. toConfig() overlays the
    /// published fields onto this, so config keys the Settings UI doesn't manage
    /// (preserveAllRecordings, reuseStreamingPartial, localAPIToken, modelPath, …)
    /// survive a Settings save. Building a fresh Config used to drop them silently.
    private var baseConfig: Config

    // MARK: - Init

    /// Initialize from an existing Config, or load from disk.
    public init(config: Config? = nil) {
        let c = config ?? Config.load()
        self.baseConfig = c

        self.hotkeyKeyCode = c.hotkey.keyCode
        self.hotkeyModifiers = c.hotkey.modifiers
        self.toggleMode = c.toggleMode?.value ?? false
        self.modelSize = c.modelSize
        self.language = c.language
        self.punctuationMode = c.spokenPunctuation ?? .hybrid
        self.maxRecordings = c.maxRecordings ?? 0  // 0 = keep everything (default)
        self.screenContext = c.screenContext?.value ?? false
        self.preBuffer = c.preBuffer?.value ?? true
        self.keepModelLoaded = c.keepModelLoaded ?? "auto"
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        self.diagnosticLogging = c.diagnosticLogging?.value ?? isBeta
        self.streamingEnabled = c.streamingEnabled?.value ?? false
        self.languageModels = c.languageModels ?? [:]
        self.engine = c.engine ?? "whisper"
        self.parakeetModel = c.parakeetModel ?? "parakeet-tdt-0.6b-v3"
        self.localAPIEnabled = c.localAPI?.value ?? false
        self.localAPIPort = c.localAPIPort ?? 5765
        self.saveRecordings = c.saveRecordings?.value ?? false
    }

    /// Re-read config from disk and refresh baseConfig plus every published field.
    /// PR-B: AppDelegate caches ONE long-lived SettingsViewModel. The recordings notice can
    /// flip saveRecordings on disk while that view model holds a stale snapshot; a later
    /// Settings save would then overlay the stale value back on. Re-syncing when the Settings
    /// window (re)opens keeps the view model consistent with what's actually on disk.
    public func refreshFromDisk() {
        let c = Config.load()
        self.baseConfig = c
        self.hotkeyKeyCode = c.hotkey.keyCode
        self.hotkeyModifiers = c.hotkey.modifiers
        self.toggleMode = c.toggleMode?.value ?? false
        self.modelSize = c.modelSize
        self.language = c.language
        self.punctuationMode = c.spokenPunctuation ?? .hybrid
        self.maxRecordings = c.maxRecordings ?? 0
        self.screenContext = c.screenContext?.value ?? false
        self.preBuffer = c.preBuffer?.value ?? true
        self.keepModelLoaded = c.keepModelLoaded ?? "auto"
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        self.diagnosticLogging = c.diagnosticLogging?.value ?? isBeta
        self.streamingEnabled = c.streamingEnabled?.value ?? false
        self.languageModels = c.languageModels ?? [:]
        self.engine = c.engine ?? "whisper"
        self.parakeetModel = c.parakeetModel ?? "parakeet-tdt-0.6b-v3"
        self.localAPIEnabled = c.localAPI?.value ?? false
        self.localAPIPort = c.localAPIPort ?? 5765
        self.saveRecordings = c.saveRecordings?.value ?? false
    }

    // MARK: - Conversion

    /// Convert the current view model state back to a Config struct.
    /// Overlays the published fields onto baseConfig — see baseConfig doc.
    public func toConfig() -> Config {
        var config = baseConfig
        config.hotkey = HotkeyConfig(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
        config.modelSize = modelSize
        config.language = language
        config.spokenPunctuation = punctuationMode
        config.maxRecordings = maxRecordings
        // PR-A: any Settings save is an explicit user choice — stamp the marker so the
        // legacy-30 migration never re-fires (a user re-picking 30 sticks; a non-30 legacy
        // value gets confirmed on next save).
        config.maxRecordingsUserConfirmed = true
        config.toggleMode = FlexBool(toggleMode)
        config.screenContext = FlexBool(screenContext)
        config.preBuffer = FlexBool(preBuffer)
        config.keepModelLoaded = keepModelLoaded
        config.diagnosticLogging = FlexBool(diagnosticLogging)
        config.streamingEnabled = FlexBool(streamingEnabled)
        config.languageModels = languageModels.isEmpty ? nil : languageModels
        config.engine = engine
        config.parakeetModel = parakeetModel
        config.localAPI = FlexBool(localAPIEnabled)
        config.localAPIPort = localAPIPort
        config.saveRecordings = FlexBool(saveRecordings)
        return config
    }

    /// Save the current settings to disk and notify the callback.
    public func save() {
        let config = toConfig()
        try? config.save()
        baseConfig = config
        onSave?()
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
