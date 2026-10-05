// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
import Foundation
import Combine

/// Bridges the Config struct to SwiftUI-friendly @Published properties.
/// Use with ObservableObject for macOS 13+ (Ventura) compatibility.
public class SettingsViewModel: ObservableObject {

    // MARK: - Published properties

    /// Presentation only; opening Clipboard preferences never changes saved settings.
    @Published var selectedSettingsTab = SettingsTab.dictation
    @Published public var historySettings: HistorySettings
    @Published public var hotkeyKeyCode: UInt16
    @Published public var hotkeyModifiers: [String]
    /// Legacy Hold/Toggle boolean, kept for back-compat readers and the round-trip tests. The
    /// three-way `keyMode` below is the authoritative field the picker binds to; `toConfig` derives
    /// `toggleMode` from it for downgrade safety.
    @Published public var toggleMode: Bool
    @Published public var keyMode: KeyMode
    /// Edit Mode: Claude cleanup switch (nil in config = on), model, and the consent date.
    @Published public var editModeCleanup: Bool
    @Published public var editModeModel: CleanupService.Model
    @Published public var editModeCloudConsent: String?
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
    /// Per-app insertion method (bundle ID -> method); never holds `.automatic`.
    @Published public var insertionOverrides: [String: InsertionMethod]
    @Published public var compatibilityReportEnabled: Bool
    /// "This works" confirmations from Report a Problem (read-only here; that window saves them).
    @Published public private(set) var insertionConfirmations: [String: InsertionConfirmation]
    /// "off", "tags", or "selectors" (Config.dictationTrace; nil on disk = "off").
    @Published public var dictationTrace: String
    @Published public var saveError: String?

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
        self.historySettings = c.history ?? HistorySettings()

        self.hotkeyKeyCode = c.hotkey.keyCode
        self.hotkeyModifiers = c.hotkey.modifiers
        self.toggleMode = c.toggleMode?.value ?? false
        self.keyMode = c.effectiveKeyMode
        self.editModeCleanup = c.editModeCleanup?.value ?? true
        self.editModeModel = CleanupService.Model.resolve(c.editModeCleanupModel)
        self.editModeCloudConsent = c.editModeCloudConsent
        self.modelSize = c.modelSize
        self.language = c.language
        self.punctuationMode = c.effectivePunctuationMode
        self.maxRecordings = c.preserveAllRecordings?.value == true ? 0 : (c.maxRecordings ?? 0)
        self.screenContext = c.screenContext?.value ?? false
        self.preBuffer = c.preBuffer?.value ?? true
        self.keepModelLoaded = c.keepModelLoaded ?? "auto"
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        self.diagnosticLogging = c.diagnosticLogging?.value ?? isBeta
        // Must match AppDelegate's runtime gate (`?? true`) and Config's documented
        // "nil = default (true)". It read `?? false`, so on any config that never set the
        // key — every fresh install — Live Preview was RUNNING while this checkbox showed
        // unchecked (2026-07-26 adversarial review). Same dishonesty as the dev-mode
        // recordings checkbox: show the state the app is actually in.
        self.streamingEnabled = c.streamingEnabled?.value ?? true
        self.languageModels = c.languageModels ?? [:]
        self.engine = c.engine ?? "whisper"
        self.parakeetModel = c.parakeetModel ?? "parakeet-tdt-0.6b-v3"
        self.localAPIEnabled = c.localAPI?.value ?? false
        self.localAPIPort = c.localAPIPort ?? 5765
        self.saveRecordings = c.saveRecordings?.value ?? false
        self.insertionOverrides = c.effectiveInsertionOverrides
        self.compatibilityReportEnabled = c.compatibilityReport?.value ?? false
        self.insertionConfirmations = c.insertionConfirmations?.values ?? [:]
        self.dictationTrace = TraceGate.encoding(forSetting: c.dictationTrace)?.rawValue ?? "off"
    }

    /// Re-read config from disk and refresh baseConfig plus every published field.
    /// PR-B: AppDelegate caches ONE long-lived SettingsViewModel. The recordings notice can
    /// flip saveRecordings on disk while that view model holds a stale snapshot; a later
    /// Settings save would then overlay the stale value back on. Re-syncing when the Settings
    /// window (re)opens keeps the view model consistent with what's actually on disk.
    public func refreshFromDisk() {
        let c = Config.load()
        self.baseConfig = c
        self.historySettings = c.history ?? HistorySettings()
        self.hotkeyKeyCode = c.hotkey.keyCode
        self.hotkeyModifiers = c.hotkey.modifiers
        self.toggleMode = c.toggleMode?.value ?? false
        self.keyMode = c.effectiveKeyMode
        self.editModeCleanup = c.editModeCleanup?.value ?? true
        self.editModeModel = CleanupService.Model.resolve(c.editModeCleanupModel)
        self.editModeCloudConsent = c.editModeCloudConsent
        self.modelSize = c.modelSize
        self.language = c.language
        self.punctuationMode = c.effectivePunctuationMode
        self.maxRecordings = c.preserveAllRecordings?.value == true ? 0 : (c.maxRecordings ?? 0)
        self.screenContext = c.screenContext?.value ?? false
        self.preBuffer = c.preBuffer?.value ?? true
        self.keepModelLoaded = c.keepModelLoaded ?? "auto"
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        self.diagnosticLogging = c.diagnosticLogging?.value ?? isBeta
        // Must match AppDelegate's runtime gate (`?? true`) and Config's documented
        // "nil = default (true)". It read `?? false`, so on any config that never set the
        // key — every fresh install — Live Preview was RUNNING while this checkbox showed
        // unchecked (2026-07-26 adversarial review). Same dishonesty as the dev-mode
        // recordings checkbox: show the state the app is actually in.
        self.streamingEnabled = c.streamingEnabled?.value ?? true
        self.languageModels = c.languageModels ?? [:]
        self.engine = c.engine ?? "whisper"
        self.parakeetModel = c.parakeetModel ?? "parakeet-tdt-0.6b-v3"
        self.localAPIEnabled = c.localAPI?.value ?? false
        self.localAPIPort = c.localAPIPort ?? 5765
        self.saveRecordings = c.saveRecordings?.value ?? false
        self.insertionOverrides = c.effectiveInsertionOverrides
        self.compatibilityReportEnabled = c.compatibilityReport?.value ?? false
        self.insertionConfirmations = c.insertionConfirmations?.values ?? [:]
        self.dictationTrace = TraceGate.encoding(forSetting: c.dictationTrace)?.rawValue ?? "off"
    }

    /// The edit window's Options saved new Edit Mode settings: take them, so a Settings window
    /// that stays open never writes the old values back. Consent first, so turning cleanup on
    /// here never re-asks for consent that was just given.
    public func applyEditModeSettings(from c: Config) {
        baseConfig.editModeCloudConsent = c.editModeCloudConsent
        baseConfig.editModeCleanup = c.editModeCleanup
        baseConfig.editModeCleanupModel = c.editModeCleanupModel
        baseConfig.editModeAnimation = c.editModeAnimation
        if editModeCloudConsent != c.editModeCloudConsent { editModeCloudConsent = c.editModeCloudConsent }
        let cleanup = c.editModeCleanup?.value ?? true
        if editModeCleanup != cleanup { editModeCleanup = cleanup }
        let model = CleanupService.Model.resolve(c.editModeCleanupModel)
        if editModeModel != model { editModeModel = model }
    }

    // MARK: - Conversion

    /// Convert the current view model state back to a Config struct.
    /// Overlays the published fields onto baseConfig — see baseConfig doc.
    public func toConfig() -> Config {
        var config = baseConfig
        config.history = historySettings
        config.hotkey = HotkeyConfig(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
        config.modelSize = modelSize
        config.language = language
        config.spokenPunctuation = punctuationMode
        config.maxRecordings = maxRecordings
        // The visible picker is now authoritative. Clear the legacy hidden override so
        // choosing Last 1,000/10,000 cannot continue to behave as Keep All.
        config.preserveAllRecordings = nil
        // PR-A: any Settings save is an explicit user choice — stamp the marker so the
        // legacy-30 migration never re-fires (a user re-picking 30 sticks; a non-30 legacy
        // value gets confirmed on next save).
        config.maxRecordingsUserConfirmed = true
        // keyMode is authoritative; keep the legacy toggleMode boolean synced so a downgrade to a
        // keyMode-unaware build still reads Hold vs Toggle correctly (Edit downgrades to Toggle's
        // tap behavior, the closest legacy match).
        config.keyMode = keyMode
        config.toggleMode = FlexBool(keyMode == .toggle)
        // Edit Mode keys are written only once they differ from "never set", so a Settings save
        // by someone who never touched Edit Mode leaves the config file as it was.
        if baseConfig.editModeCleanup != nil || !editModeCleanup {
            config.editModeCleanup = FlexBool(editModeCleanup)
        }
        if baseConfig.editModeCleanupModel != nil || editModeModel != .sonnet {
            config.editModeCleanupModel = editModeModel.rawValue
        }
        config.editModeCloudConsent = editModeCloudConsent
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
        let overrides = insertionOverrides.filter { !$0.key.isEmpty && $0.value != .automatic }
        // Keep entries a newer build wrote with a method this build does not know, unless the
        // user has since picked a method for that app here.
        let chosen = Set(overrides.keys.map { $0.lowercased() })
        let unknown = (baseConfig.insertionOverrides?.unknown ?? [:])
            .filter { !chosen.contains($0.key.lowercased()) }
        config.insertionOverrides = overrides.isEmpty && unknown.isEmpty
            ? nil : InsertionOverrideMap(overrides, unknown: unknown)
        config.compatibilityReport = FlexBool(compatibilityReportEnabled)
        config.dictationTrace = TraceGate.encoding(forSetting: dictationTrace)?.rawValue
        return config
    }

    /// Set (or, with `.automatic`, clear) the insertion method for one app and save.
    /// Replaces any existing entry for the same bundle ID regardless of letter case.
    public func setInsertionOverride(_ method: InsertionMethod, for bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = insertionOverrides.filter { $0.key.lowercased() != trimmed.lowercased() }
        if method != .automatic { updated[trimmed] = method }
        insertionOverrides = updated
        save()
    }

    /// Save the current settings to disk and notify the callback.
    public func save() {
        let config = toConfig()
        do {
            try config.save()
            baseConfig = config
            saveError = nil
            onSave?()
        } catch {
            saveError = "Settings could not be saved. Your previous saved settings are still active. \(error.localizedDescription)"
        }
    }

    func selectRecordingRetention(_ value: Int) {
        var config = toConfig()
        RecordingRetention.apply(value, to: &config)
        saveRecordings = config.saveRecordings?.value == true
        maxRecordings = config.maxRecordings ?? 0
        save()
    }

    // MARK: - Punctuation modes per engine

    /// The punctuation modes the picker offers for a given engine, in display order.
    ///
    /// Spoken Only (.spoken) is Whisper-only. Its ONLY distinguishing behavior is suppressing the
    /// engine's own automatic punctuation (Transcriber.suppressAutoPunctuation) so that only
    /// spoken words punctuate; the word-substitution is now identically guarded across .spoken and
    /// .hybrid. Parakeet ignores that suppression, so on Parakeet Spoken Only would be byte-for-byte
    /// identical to Automatic & Spoken (.hybrid) — redundant and misleading. It is therefore omitted
    /// for Parakeet. Whisper keeps all three modes.
    public static func availablePunctuationModes(engine: String) -> [PunctuationMode] {
        engine == "parakeet"
            ? [.hybrid, .off]
            : [.hybrid, .off, .spoken]
    }

    /// The picker label for a punctuation mode, matching the Settings UI wording.
    public static func punctuationModeLabel(_ mode: PunctuationMode) -> String {
        switch mode {
        case .hybrid: return "Automatic & Spoken"
        case .off:    return "Automatic Only"
        case .spoken: return "Spoken Only"
        }
    }

    // MARK: - Model description helpers

    /// Estimated RAM usage for a Whisper model, read from the same table the model picker uses.
    ///
    /// 2026-07-26: this held its own copy of the figures and disagreed with the picker on
    /// large-v3-turbo — "~1.2 GB" here against "~1.6 GB" there, both rendered in the SAME
    /// Settings window (the picker row, and the Performance footnote one scroll below). Reads
    /// EngineCatalog now, so there is one number.
    public static func modelMemoryDescription(_ model: String) -> String {
        EngineCatalog.whisperModel(forID: model)?.memoryDescription ?? "Unknown"
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

    /// Estimated model load time, from the same table the picker uses. See
    /// `modelMemoryDescription` for why this no longer keeps its own copy (it said "~0.8s" for
    /// large-v3-turbo while the picker said "~1.1s").
    public static func modelLoadTimeDescription(_ model: String) -> String {
        EngineCatalog.whisperModel(forID: model)?.loadTimeDescription ?? "unknown"
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

    /// Whether this model is the recommendation for THIS Mac. Was unconditionally
    /// `model == "large-v3-turbo"`, which contradicted the picker's RAM-dependent choice on any
    /// Mac under 16GB (2026-07-26).
    public static func isRecommendedModel(_ model: String) -> Bool {
        guard let info = EngineCatalog.whisperModel(forID: model) else { return false }
        return info.base == EngineCatalog.recommendedWhisperBase()
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
