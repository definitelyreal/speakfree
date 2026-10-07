// ai-suggestion:unverified · session:unknown/agent:astra_capture_final · 2026-10-05
import Carbon
import Foundation

/// System registration and common app usage are different kinds of evidence.
/// These checks cannot identify another app's global-hotkey owner or prove a key free.
enum ShortcutConflictHints {
    struct SystemKey: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    enum SystemSnapshot: Equatable {
        case available(Set<SystemKey>)
        case unavailable

        func conflict(for shortcut: HistorySettings.Shortcut) -> String? {
            guard shortcut.isAssigned, case .available(let keys) = self,
                  keys.contains(SystemKey(keyCode: UInt32(shortcut.keyCode),
                                          modifiers: ShortcutConflictHints.carbonFlags(shortcut.modifiers))) else { return nil }
            return "\(shortcut.label) is used by a macOS keyboard shortcut. Change it in System Settings → Keyboard → Keyboard Shortcuts, or choose another."
        }
    }

    /// Call at configuration/UI boundaries, not for each event. Carbon documents this
    /// query as not thread safe; the caller must stay on the main run loop.
    static func systemSnapshot() -> SystemSnapshot {
        precondition(Thread.isMainThread)
        var result: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&result)
        let entries = result?.takeRetainedValue() as? [[String: Any]]
        guard status == noErr, let entries else { return .unavailable }
        return systemSnapshot(entries: entries)
    }

    /// Pure parsing seam. Only enabled, fully specified symbolic shortcuts are evidence.
    static func systemSnapshot(entries: [[String: Any]]) -> SystemSnapshot {
        var keys = Set<SystemKey>()
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber,
                  let keyCode = UInt32(exactly: code.int64Value),
                  let flags = UInt32(exactly: modifiers.int64Value) else { continue }
            keys.insert(SystemKey(keyCode: keyCode, modifiers: flags & UInt32(cmdKey | shiftKey | optionKey | controlKey)))
        }
        return .available(keys)
    }

    static func carbonFlags(_ modifiers: [String]) -> UInt32 {
        let values = HistorySettings.normalizedModifiers(modifiers)
        var flags: UInt32 = 0
        if values.contains("cmd") { flags |= UInt32(cmdKey) }
        if values.contains("shift") { flags |= UInt32(shiftKey) }
        if values.contains("option") { flags |= UInt32(optionKey) }
        if values.contains("ctrl") { flags |= UInt32(controlKey) }
        return flags
    }

    static func distinctErrors(_ errors: [String?]) -> [String] {
        var seen = Set<String>()
        return errors.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    static func remainingRegistrationError(_ error: String?, inlineErrors: [String]) -> String? {
        guard let error else { return nil }
        let inline = Set(inlineErrors)
        let remaining = error.components(separatedBy: "\n").filter { !inline.contains($0) }
        return remaining.isEmpty ? nil : remaining.joined(separator: "\n")
    }

    static func registrationFailure(_ status: OSStatus, shortcut: HistorySettings.Shortcut) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "\(shortcut.label) is already registered elsewhere. Choose another shortcut."
        }
        return "Couldn’t register \(shortcut.label). Try another shortcut."
    }

    static func fieldLabel(_ shortcut: HistorySettings.Shortcut, recording: Bool) -> String {
        recording ? "Press shortcut…" : shortcut.isAssigned ? shortcut.label : "No shortcut"
    }

    static func commonUsage(_ shortcut: HistorySettings.Shortcut) -> String? {
        guard shortcut.matches(.init(keyCode: 9, modifiers: ["cmd", "shift"])) else { return nil }
        // Public default usage, not installed-app detection. Sources checked 2026-10-05:
        // chromium/chromium 89e69105f31834dd968673261a38176080c45d46,
        // chrome/browser/ui/cocoa/accelerators_cocoa.mm:88-89;
        // https://code.visualstudio.com/docs/reference/default-keybindings
        return "Common defaults: Paste and Match Style in Chrome; Markdown Preview in VS Code."
    }
}
