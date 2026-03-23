import Foundation

public struct Config: Codable {
    public var hotkey: HotkeyConfig
    public var modelPath: String?
    public var modelSize: String
    public var language: String
    public var spokenPunctuation: PunctuationMode?
    public var maxRecordings: Int?
    public var toggleMode: FlexBool?

    public static let defaultMaxRecordings = 0

    public static func effectiveMaxRecordings(_ value: Int?) -> Int {
        let raw = value ?? Config.defaultMaxRecordings
        if raw == 0 { return 0 }
        return min(max(1, raw), 100)
    }

    public static let defaultConfig = Config(
        hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
        modelPath: nil,
        modelSize: "base.en",
        language: "en",
        spokenPunctuation: .hybrid,
        maxRecordings: 30,
        toggleMode: FlexBool(false)
    )

    public static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/speakfree")
    }

    public static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    public static var vocabularyFile: URL {
        configDir.appendingPathComponent("vocabulary.txt")
    }

    /// Load custom vocabulary words from ~/.config/speakfree/vocabulary.txt
    /// One word or phrase per line. Prepended to whisper's prompt to prime recognition.
    public static func loadVocabulary() -> String? {
        guard let content = try? String(contentsOf: vocabularyFile, encoding: .utf8) else { return nil }
        let words = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: ", ")
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: configFile) else {
            let config = Config.defaultConfig
            try? config.save()
            return config
        }

        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            fputs("Warning: unable to parse \(configFile.path): \(error.localizedDescription)\n", stderr)
            // Back up the corrupted file so user can recover it
            let backupFile = configDir.appendingPathComponent("config.json.bak")
            try? FileManager.default.removeItem(at: backupFile)
            try? FileManager.default.copyItem(at: configFile, to: backupFile)
            return Config.defaultConfig
        }
    }

    public static func decode(from data: Data) throws -> Config {
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: Config.configFile)
    }
}

/// Punctuation mode:
///   .off     — whisper auto-punct only, no spoken word conversion  (spokenPunctuation: false)
///   .spoken  — suppress whisper auto-punct, convert spoken words   (spokenPunctuation: true)
///   .hybrid  — whisper auto-punct + convert spoken words           (spokenPunctuation: "hybrid")
public enum PunctuationMode: Codable, Equatable {
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
