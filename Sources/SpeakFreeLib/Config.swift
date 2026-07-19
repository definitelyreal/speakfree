import Foundation

public struct Config: Codable {
    public var hotkey: HotkeyConfig
    public var modelPath: String?
    public var modelSize: String
    public var language: String
    public var spokenPunctuation: PunctuationMode?
    public var maxRecordings: Int?
    // PR-A marker: was maxRecordings set by an explicit user choice (Settings cap picker
    // or the one-time legacy migration), or is it a pre-2026-06 build's DEFAULT of 30?
    // nil = never confirmed. Pre-2026-06 builds wrote maxRecordings=30 as a default (not a
    // user choice) and prune runs unconditionally at launch, which silently auto-deletes
    // recordings — violating the keep-forever-by-default contract below. The migration in
    // load() clears a legacy 30 and stamps this marker so a user who deliberately re-picks
    // 30 in Settings still sticks.
    public var maxRecordingsUserConfirmed: Bool?
    public var toggleMode: FlexBool?
    public var screenContext: FlexBool?
    // Deprecated 2026-06-11: the correction learner was removed (it polluted the
    // glossary with truncations and quote-style noise). Key is kept so old configs
    // decode and the value round-trips, but nothing reads it.
    public var rememberWords: FlexBool?
    // Mostly redundant since 2026-06-11: keep-everything is now the DEFAULT (nil/0
    // maxRecordings). Still honored for old configs that set it alongside an explicit
    // maxRecordings cap.
    public var preserveAllRecordings: FlexBool?
    public var preBuffer: FlexBool?  // nil = default (on)
    public var keepModelLoaded: String?  // "auto", "always", "off" — nil = "auto"
    public var diagnosticLogging: FlexBool?  // nil = default (off for production, on for beta)
    public var streamingEnabled: FlexBool?  // nil = default (true) — show live preview while recording
    // T2.3 — kill-switch for reusing the last streaming partial on short utterances (skip the
    // redundant final inference when release lands <300ms after the last streaming pass and the
    // recording barely grew). nil = default (true). Set false to always run the final pass.
    public var reuseStreamingPartial: FlexBool?
    public var languageModels: [String: String]?  // e.g. ["en": "small.en", "auto": "small"]
    public var engine: String?  // "whisper" | "parakeet" — nil = "whisper"
    public var parakeetModel: String?  // e.g. "parakeet-tdt-0.6b-v3" — nil = "parakeet-tdt-0.6b-v3"
    public var localAPI: FlexBool?  // nil = false — expose local transcription API
    public var localAPIPort: Int?   // nil = 5765
    // Experimental local API hardening. The server is loopback-only regardless of these.
    public var localAPIAllowBrowser: FlexBool?  // nil = false — gate any CORS (Access-Control-*) headers
    public var localAPIToken: String?           // nil = no auth — when set, require "Authorization: Bearer <token>"

    // Recordings privacy (Michael, 2026-07-14): persisting dictation audio + transcript
    // sidecars is OPT-IN. nil/false = nothing persists — the wav is deleted once the
    // dictation finalizes and no sidecars are written. Saving was accidentally
    // on-by-default for every user through v1.7.1 (it was meant as a dev-machine
    // debugging corpus); the apology notice below tells users and lets them choose.
    public var saveRecordings: FlexBool?
    // Resolution of the recordings apology notice: "keep" | "delete" | "none-found".
    // nil = undecided — the notice returns every launch and every few hours until the
    // user chooses. Never shown again once set.
    public var recordingsNoticeDecision: String?

    // Microphone pin (2026-07-14): CoreAudio device UID the recorder captures from.
    // nil = follow the system default input (historical behavior). Set from the
    // menu-bar microphone selector; falls back to the default if the device vanishes.
    public var inputDeviceUID: String?

    // Dual-mic capture prototype (2026-07-14, flag-gated, default OFF): when the
    // default input is Bluetooth, pin the always-on engine to the built-in mic
    // (pre-roll + A2DP release) and record a second comparison track from the
    // Bluetooth mic during dictation. See DualCapture.swift.
    public var dualMicCapture: FlexBool?

    // Recordings are kept forever by DEFAULT — they are the dictation corpus that
    // makes accuracy regressions diagnosable (and ~1 MB per 30 s of speech is cheap).
    // Pruning happens ONLY when the user explicitly picks a cap in Settings.
    // 0 = keep everything.
    public static func effectiveMaxRecordings(_ value: Int?) -> Int {
        guard let raw = value, raw > 0 else { return 0 }
        return min(raw, 100)
    }

    // MARK: - Product defaults (Michael, 2026-06-11)
    //
    // The default engine for NEW users is Parakeet ENGLISH: parakeet-tdt-0.6b-v2.
    // v2 is the English-only variant (faster, more accurate for English); v3 is
    // the multilingual variant — the welcome flow and Settings switch to v3 when
    // a non-English language is selected.
    //
    // Back-compat split — DELIBERATE, do not "clean up":
    //   • defaultConfig writes `engine` and `parakeetModel` EXPLICITLY, so every
    //     config created from it carries both keys on disk.
    //   • The `?? "whisper"` / `?? "parakeet-tdt-0.6b-v3"` nil-coalescing at use
    //     sites serves LEGACY configs written before these keys existed. Changing
    //     those fallbacks to the new defaults would silently switch existing
    //     whisper-era users' engine on upgrade.
    public static let defaultEngine = "parakeet"
    public static let defaultParakeetModel = "parakeet-tdt-0.6b-v2"  // English-only

    public static let defaultConfig = Config(
        hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
        modelPath: nil,
        // Whisper default for when the user switches engine to whisper.
        modelSize: "large-v3-turbo",
        language: "en",
        spokenPunctuation: .hybrid,
        maxRecordings: nil,
        toggleMode: FlexBool(false),
        engine: Config.defaultEngine,
        parakeetModel: Config.defaultParakeetModel
    )

    /// Test seam: when set, all config/vocabulary/recordings paths resolve under this
    /// directory instead of the real ~/.config/speakfree. Tests that write config MUST
    /// set this in setUp — a test once overwrote the developer's live config.json with
    /// a fixture (base.en), which knocked the configured model off disk-reality and
    /// silently degraded dictation to tiny.en for days (2026-06-11 collapse).
    public static var configDirOverride: URL?

    public static var configDir: URL {
        if let override = configDirOverride { return override }
        // Integration-test seam: launching a whole app instance against a scratch config
        // dir. HOME env is NOT enough — homeDirectoryForCurrentUser reads passwd and
        // ignores it (verified 2026-07-14 when a "scratch" test instance wrote to the
        // real config). Same trust domain as configDirOverride: user-level, local-only.
        if let env = ProcessInfo.processInfo.environment["SPEAKFREE_CONFIG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Use bundle identifier to isolate beta from production
        let dirName: String
        if let bundleId = Bundle.main.bundleIdentifier, bundleId.hasSuffix(".beta") {
            dirName = "speakfree-beta"
        } else {
            dirName = "speakfree"
        }
        return home.appendingPathComponent(".config/\(dirName)")
    }

    public static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    public static var vocabularyFile: URL {
        configDir.appendingPathComponent("vocabulary.txt")
    }

    public static var overridesFile: URL {
        configDir.appendingPathComponent("overrides.json")
    }

    // mtime-checked parse cache for vocabulary.txt / overrides.json. These are read on
    // main every finalize; the parse is pure so a (mtime, size) stamp lets us skip re-reading
    // an unchanged file. Keyed on the file's absolute path so a different Config.configDirOverride
    // (each test uses its own scratch dir) never returns another dir's cached value — this is
    // load-bearing for the suite's isolation. Guarded by a lock: load() has off-main callers.
    private static let fileCacheLock = NSLock()
    private static var overridesCache: [String: (stamp: FileStamp, value: [String: String])] = [:]
    private static var vocabularyCache: [String: (stamp: FileStamp, value: String?)] = [:]

    private struct FileStamp: Equatable {
        let mtime: Date
        let size: Int
        let inode: Int
    }

    /// (modificationDate, size, inode) of `url`, or nil if it can't be stat'd (missing file).
    /// A change in any field invalidates the cache. size guards against a same-instant rewrite
    /// whose mtime granularity didn't move; the inode (fileSystemFileNumber) guards against a
    /// timestamp-PRESERVING replacement — a Dropbox sync/restore or `mv` swaps the file to a new
    /// inode while keeping the same mtime and size, which (mtime,size) alone would serve stale.
    private static func fileStamp(_ url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(mtime: mtime,
                         size: (attrs[.size] as? Int) ?? -1,
                         inode: (attrs[.systemFileNumber] as? Int) ?? -1)
    }

    /// Load curated exact garble→correct overrides from ~/.config/speakfree/overrides.json
    /// (a flat JSON object, lowercased keys). For recurring mistranscriptions the fuzzy
    /// GlossaryCorrector can't safely fix — real-word-colliding garbles ("kama"→"Karma")
    /// or short tokens ("crf"→"CRM"). Curated only; nothing auto-learns into it.
    public static func loadOverrides() -> [String: String] {
        let url = overridesFile
        let stamp = fileStamp(url)
        if let stamp = stamp {
            fileCacheLock.lock()
            let cached = overridesCache[url.path]
            fileCacheLock.unlock()
            if let cached = cached, cached.stamp == stamp { return cached.value }
        }
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        // Normalize keys to lowercase (the corrector matches on lowercased tokens).
        var out: [String: String] = [:]
        for (k, v) in raw { out[k.lowercased()] = v }
        if let stamp = stamp {
            fileCacheLock.lock()
            overridesCache[url.path] = (stamp, out)
            fileCacheLock.unlock()
        }
        return out
    }

    /// Load custom vocabulary words from ~/.config/speakfree/vocabulary.txt
    /// One word or phrase per line. Used to prime Whisper's prompt AND to drive
    /// GlossaryCorrector on every engine (incl. Parakeet, which ignores the prompt).
    ///
    /// Lines may carry an inline provenance comment — ` # manual` / ` # contacts` /
    /// ` # brain` / ` # auto` — which is stripped here. Full-line comments (starting
    /// with `#`) are dropped.
    public static func loadVocabulary() -> String? {
        let url = vocabularyFile
        let stamp = fileStamp(url)
        if let stamp = stamp {
            fileCacheLock.lock()
            let cached = vocabularyCache[url.path]
            fileCacheLock.unlock()
            if let cached = cached, cached.stamp == stamp { return cached.value }
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let words = content.components(separatedBy: .newlines)
            .map { stripInlineComment($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let result: String? = words.isEmpty ? nil : words.joined(separator: ", ")
        if let stamp = stamp {
            fileCacheLock.lock()
            vocabularyCache[url.path] = (stamp, result)
            fileCacheLock.unlock()
        }
        return result
    }

    /// Strip an inline ` # <provenance>` comment from a vocabulary line, leaving the
    /// term. A line that is entirely a comment (`# ...`) is returned unchanged so the
    /// caller's `hasPrefix("#")` filter drops it.
    static func stripInlineComment(_ line: String) -> String {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard !l.hasPrefix("#") else { return l }
        if let range = l.range(of: " #") {
            return String(l[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return l
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: configFile) else {
            let config = Config.defaultConfig
            try? config.save()
            return config
        }

        do {
            var config = try JSONDecoder().decode(Config.self, from: data)
            migrateLegacyMaxRecordings(&config)
            return config
        } catch {
            fputs("Warning: unable to parse \(configFile.path): \(error.localizedDescription)\n", stderr)
            // Back up the corrupted file so user can recover it
            let backupFile = configDir.appendingPathComponent("config.json.bak")
            try? FileManager.default.removeItem(at: backupFile)
            try? FileManager.default.copyItem(at: configFile, to: backupFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupFile.path)
            return Config.defaultConfig
        }
    }

    /// Guards the one-shot migration log line. The migration itself re-runs (in-memory) on
    /// every load; only the diagnostic line is throttled to once per process.
    private static var didLogLegacyMigration = false

    /// Migration (PR-A): a pre-2026-06 build wrote maxRecordings=30 as a DEFAULT (not a user
    /// choice). Because prune runs unconditionally at launch, those on-disk configs silently
    /// auto-delete recordings, contradicting the keep-forever-by-default contract. When we see
    /// the legacy 30 with no user-confirmation marker, clear the cap and stamp the marker so a
    /// user who later re-picks 30 in Settings still sticks.
    ///
    /// P3: this mutates ONLY the in-memory config — it must NOT save() inside load(). load()
    /// has ~20 call sites, several off-main; a non-atomic write racing a concurrent load could
    /// truncate config.json and reset every setting to defaults. The transform is pure and
    /// idempotent, so re-deriving it on every load is free; the nil cap is persisted the next
    /// time the user saves Settings (SettingsViewModel.toConfig stamps maxRecordingsUserConfirmed).
    /// Static + pure so it's unit-testable.
    static func migrateLegacyMaxRecordings(_ config: inout Config) {
        guard config.maxRecordings == 30, config.maxRecordingsUserConfirmed == nil else { return }
        config.maxRecordings = nil
        config.maxRecordingsUserConfirmed = true
        if !didLogLegacyMigration {
            didLogLegacyMigration = true
            DiagnosticLogger.shared.log(
                "Config: legacy default cap cleared in-memory — recordings will not be auto-pruned "
                    + "(persists on next Settings save)")
        }
    }

    public static func decode(from data: Data) throws -> Config {
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Config.configDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        // P3: write atomically (temp file + rename) so a concurrent Config.load() can never
        // observe a half-written config.json and fall into the corrupt-file reset-to-defaults
        // path. load() has ~20 call sites, several off-main.
        try data.write(to: Config.configFile, options: .atomic)
        // config.json carries localAPIToken; the dir attribute above only applies on
        // first creation, so re-assert both on every save.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Config.configDir.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.configFile.path)
    }
}

/// Punctuation mode:
///   .off     — whisper auto-punct only, no spoken word conversion  (spokenPunctuation: false)
///   .spoken  — suppress whisper auto-punct, convert spoken words   (spokenPunctuation: true)
///   .hybrid  — whisper auto-punct + convert spoken words           (spokenPunctuation: "hybrid")
public enum PunctuationMode: Codable, Equatable, Hashable {
    case off
    case spoken
    case hybrid

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = b ? .spoken : .off
        } else if let s = try? c.decode(String.self) {
            switch s.lowercased() {
            case "hybrid": self = .hybrid
            case "true", "on", "yes", "1", "spoken": self = .spoken
            default: self = .off
            }
        } else {
            self = .off
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .off:    try c.encode(false)
        case .spoken: try c.encode(true)
        case .hybrid: try c.encode("hybrid")
        }
    }
}

public struct FlexBool: Codable {
    public let value: Bool

    public init(_ value: Bool) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let s = try? container.decode(String.self) {
            value = ["true", "yes", "1"].contains(s.lowercased())
        } else if let i = try? container.decode(Int.self) {
            value = i != 0
        } else {
            value = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct HotkeyConfig: Codable {
    public var keyCode: UInt16
    public var modifiers: [String]

    public init(keyCode: UInt16, modifiers: [String]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var modifierFlags: UInt64 {
        var flags: UInt64 = 0
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command": flags |= UInt64(1 << 20)
            case "shift": flags |= UInt64(1 << 17)
            case "ctrl", "control": flags |= UInt64(1 << 18)
            case "opt", "option", "alt": flags |= UInt64(1 << 19)
            default: break
            }
        }
        return flags
    }
}
