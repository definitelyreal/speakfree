// ai-suggestion:unverified · session:unknown/agent:audio_file_integrity · 2026-10-03
import Foundation

public struct HistorySettings: Codable, Equatable {
    public enum Retention: String, Codable, CaseIterable { case off, session, week }
    public enum Action: String, CaseIterable, Identifiable {
        case dictation, clipboard, all
        public var id: Self { self }
        var title: String {
            switch self {
            case .dictation: return "Dictations"
            case .clipboard: return "Clipboard"
            case .all: return "All"
            }
        }
        var carbonID: UInt32 {
            switch self {
            case .dictation: return 1
            case .clipboard: return 2
            case .all: return 3
            }
        }
        var defaultShortcut: Shortcut {
            switch self {
            case .dictation: return .init(keyCode: 9, modifiers: ["option", "shift"])
            case .clipboard: return .init(keyCode: 9, modifiers: ["cmd", "shift"])
            case .all: return .unassigned
            }
        }
    }

    public struct Shortcut: Codable, Equatable {
        public var keyCode: UInt16
        public var modifiers: [String]
        public init(keyCode: UInt16, modifiers: [String]) { self.keyCode = keyCode; self.modifiers = modifiers }
        public static let unassigned = Shortcut(keyCode: 9, modifiers: [])
        private enum CodingKeys: String, CodingKey { case keyCode, modifiers }
        public init(from decoder: Decoder) throws {
            self = .unassigned
            guard let values = try? decoder.container(keyedBy: CodingKeys.self),
                  let code = try? values.decode(UInt16.self, forKey: .keyCode), code < 128,
                  let modifiers = try? values.decode([String].self, forKey: .modifiers),
                  modifiers.isEmpty || HistorySettings.isSafeShortcut(modifiers) else { return }
            self.init(keyCode: code, modifiers: modifiers)
        }
        var isAssigned: Bool { !modifiers.isEmpty }
        func matches(_ other: Shortcut) -> Bool {
            if !isAssigned && !other.isAssigned { return true }
            return keyCode == other.keyCode && HistorySettings.normalizedModifiers(modifiers) == HistorySettings.normalizedModifiers(other.modifiers)
        }
        /// HotkeyManager accepts modifier supersets. A sided modifier primary can
        /// start on its own press before this chord's letter; Carbon cannot require
        /// the opposite side, so any use of that modifier class is a collision.
        func conflictsWithDictation(_ dictation: HotkeyConfig) -> Bool {
            guard isAssigned else { return false }
            let flags = HotkeyConfig(keyCode: keyCode, modifiers: modifiers).modifierFlags
            let required = dictation.modifierFlags
            guard flags & required == required else { return false }
            let primaryModifier: String
            switch dictation.keyCode {
            case 54, 55: primaryModifier = "cmd"
            case 56, 60: primaryModifier = "shift"
            case 58, 61: primaryModifier = "option"
            case 59, 62: primaryModifier = "ctrl"
            case 63: return false // History chords do not support Fn as a modifier.
            default: return keyCode == dictation.keyCode
            }
            let primaryFlag = HotkeyConfig(keyCode: dictation.keyCode, modifiers: [primaryModifier]).modifierFlags
            return flags & primaryFlag != 0
        }
        var validationError: String? {
            guard isAssigned else { return nil }
            guard keyCode < 128, ![54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode),
                  HistorySettings.isSafeShortcut(modifiers) else { return "Use a key with Command, Option, or Control." }
            return nil
        }
        var label: String {
            guard isAssigned else { return "Not set" }
            let normalized = HistorySettings.normalizedModifiers(modifiers)
            let prefix = [("ctrl", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
                .filter { normalized.contains($0.0) }.map(\.1).joined()
            return prefix + HistorySettings.keyGlyph(keyCode)
        }
    }

    public var retention: Retention = .session
    public var includeClipboard = false
    // Keep these legacy fields as Clipboard's storage so an existing custom binding migrates intact.
    public var shortcutKeyCode: UInt16 = 9
    public var shortcutModifiers: [String] = ["cmd", "shift"]
    public var dictationShortcut: Shortcut = Action.dictation.defaultShortcut
    public var allShortcut: Shortcut = .unassigned

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case retention, includeClipboard, shortcutKeyCode, shortcutModifiers, dictationShortcut, allShortcut
    }

    /// Decode each field independently: malformed/future history fields must not reset
    /// the user's unrelated microphone, model or dictation settings.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { retention = .off; return }
        if values.contains(.retention) { retention = (try? values.decode(Retention.self, forKey: .retention)) ?? .off }
        includeClipboard = (try? values.decode(Bool.self, forKey: .includeClipboard)) ?? false
        if values.contains(.shortcutKeyCode) {
            if let code = try? values.decode(UInt16.self, forKey: .shortcutKeyCode), code < 128 { shortcutKeyCode = code }
            else { shortcutModifiers = [] }
        }
        if values.contains(.shortcutModifiers) {
            let modifiers = (try? values.decode([String].self, forKey: .shortcutModifiers)) ?? []
            shortcutModifiers = Self.isSafeShortcut(modifiers) ? modifiers : []
        }
        if values.contains(.shortcutKeyCode), (try? values.decode(UInt16.self, forKey: .shortcutKeyCode)).map({ $0 < 128 }) != true {
            shortcutModifiers = []
        }
        if values.contains(.dictationShortcut) { dictationShortcut = (try? values.decode(Shortcut.self, forKey: .dictationShortcut)) ?? .unassigned }
        if values.contains(.allShortcut) { allShortcut = (try? values.decode(Shortcut.self, forKey: .allShortcut)) ?? .unassigned }
        // Preserve an explicitly disabled legacy shortcut, and let a legacy custom
        // Clipboard binding win over the newly introduced Dictations default.
        let legacyDisabled = (try? values.decode([String].self, forKey: .shortcutModifiers))?.isEmpty == true
        if !values.contains(.dictationShortcut), legacyDisabled || shortcut(for: .clipboard).matches(dictationShortcut) {
            dictationShortcut = .unassigned
        }
    }

    func shortcut(for action: Action) -> Shortcut {
        switch action {
        case .dictation: return dictationShortcut
        case .clipboard: return .init(keyCode: shortcutKeyCode, modifiers: shortcutModifiers)
        case .all: return allShortcut
        }
    }
    mutating func setShortcut(_ shortcut: Shortcut, for action: Action) {
        switch action {
        case .dictation: dictationShortcut = shortcut
        case .clipboard: shortcutKeyCode = shortcut.keyCode; shortcutModifiers = shortcut.modifiers
        case .all: allShortcut = shortcut
        }
    }
    func validationError(for shortcut: Shortcut, action: Action, dictation: HotkeyConfig) -> String? {
        guard shortcut.isAssigned else { return nil }
        if let error = shortcut.validationError { return error }
        if shortcut.conflictsWithDictation(dictation) {
            return "This shortcut can also start dictation. Choose a different combination."
        }
        if let other = Action.allCases.first(where: { $0 != action && self.shortcut(for: $0).matches(shortcut) }) {
            return "\(other.title) already uses \(shortcut.label). Choose a different shortcut."
        }
        return nil
    }

    static func normalizedModifiers(_ values: [String]) -> Set<String> {
        Set(values.map { value in
            switch value.lowercased() {
            case "command": return "cmd"
            case "control": return "ctrl"
            case "alt": return "option"
            default: return value.lowercased()
            }
        })
    }
    static func isSafeShortcut(_ values: [String]) -> Bool {
        let normalized = normalizedModifiers(values)
        return normalized.isSubset(of: ["cmd", "ctrl", "option", "shift"])
            && !normalized.isDisjoint(with: ["cmd", "ctrl", "option"])
    }
    var policy: HistoryStore.Policy {
        .init(captureDictations: retention != .off, captureClipboard: retention != .off && includeClipboard,
              persistent: retention == .week, maximumAge: retention == .week ? 7 * 24 * 60 * 60 : .greatestFiniteMagnitude)
    }
    var shortcutLabel: String { shortcutModifiers.isEmpty ? "Choose shortcut…" : shortcut(for: .clipboard).label }
    private static func keyGlyph(_ code: UInt16) -> String {
        switch code {
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 49: return "␣"
        case 51: return "⌫"
        case 53: return "⎋"
        case 57: return "⇪"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return KeyCodes.codeToName[code]?.uppercased() ?? "Key \(code)"
        }
    }
}
