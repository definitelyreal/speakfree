// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import Foundation

public struct HistorySettings: Codable, Equatable {
    public enum Retention: String, Codable, CaseIterable { case off, session, week }
    public var retention: Retention = .session
    public var includeClipboard = false
    public var shortcutKeyCode: UInt16 = 9
    public var shortcutModifiers: [String] = ["cmd", "shift"]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case retention, includeClipboard, shortcutKeyCode, shortcutModifiers
    }

    /// A newly added or future history field must never make Config.load discard the
    /// unrelated microphone, engine, and dictation settings. Unknown explicit retention
    /// fails closed; a missing field keeps the session-only default for older configs.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else {
            retention = .off
            return
        }
        if values.contains(.retention) {
            retention = (try? values.decode(Retention.self, forKey: .retention)) ?? .off
        }
        includeClipboard = (try? values.decode(Bool.self, forKey: .includeClipboard)) ?? false
        shortcutKeyCode = (try? values.decode(UInt16.self, forKey: .shortcutKeyCode)) ?? 9
        if values.contains(.shortcutModifiers) {
            let modifiers = (try? values.decode([String].self, forKey: .shortcutModifiers)) ?? []
            var seen = Set<String>()
            shortcutModifiers = modifiers.map { $0.lowercased() }.filter {
                ["cmd", "command", "shift", "ctrl", "control", "alt", "option"].contains($0) && seen.insert($0).inserted
            }
        }
        if !Self.isSafeShortcut(shortcutModifiers) { shortcutModifiers = [] }
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
        !normalizedModifiers(values).isDisjoint(with: ["cmd", "ctrl", "option"])
    }

    var policy: HistoryStore.Policy {
        .init(captureDictations: retention != .off,
              captureClipboard: retention != .off && includeClipboard,
              persistent: retention == .week,
              maximumAge: retention == .week ? 7 * 24 * 60 * 60 : .greatestFiniteMagnitude)
    }

    var shortcutLabel: String {
        guard !shortcutModifiers.isEmpty else { return "Choose shortcut…" }
        let modifiers = Self.normalizedModifiers(shortcutModifiers)
        let prefix = [("ctrl", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined()
        let key: String
        switch shortcutKeyCode {
        case 36: key = "↩"
        case 48: key = "⇥"
        case 49: key = "␣"
        case 51: key = "⌫"
        case 53: key = "⎋"
        case 115: key = "↖"
        case 116: key = "⇞"
        case 117: key = "⌦"
        case 119: key = "↘"
        case 121: key = "⇟"
        case 123: key = "←"
        case 124: key = "→"
        case 125: key = "↓"
        case 126: key = "↑"
        default: key = KeyCodes.codeToName[shortcutKeyCode]?.uppercased() ?? "Key \(shortcutKeyCode)"
        }
        return prefix + key
    }
}
