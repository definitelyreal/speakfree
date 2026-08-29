import Foundation

/// Key Mode: how the dictation hotkey behaves (Michael, 2026-08-28 — Edit Mode).
///
///   .hold   — record while the key is held, insert on release (the historical default)
///   .toggle — tap to start, tap to stop, insert on stop
///   .edit   — tap opens the editing window and records a segment; more taps append more
///             segments; the text lands in the window (not the target app) and is committed
///             on Return
///
/// Key Mode was a single `toggleMode` boolean before this enum. A config predating `keyMode`
/// resolves through `Config.effectiveKeyMode`: `toggleMode == true` means `.toggle`, otherwise
/// `.hold`. The `PunctuationMode` bool→enum migration (Config.swift) is the precedent; like it,
/// decode is LENIENT so a value written by a future build (an unknown mode) degrades to the safe
/// default rather than failing the entire Config decode — an optional whose stored value fails to
/// decode throws the whole struct, which would brick every setting.
public enum KeyMode: String, Codable, Equatable {
    case hold
    case toggle
    case edit

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch (try? container.decode(String.self))?.lowercased() {
        case "hold":   self = .hold
        case "toggle": self = .toggle
        case "edit":   self = .edit
        default:       self = .hold   // unknown/wrong shape → safest mode, never throws
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension Config {
    /// THE single resolution of Key Mode across the legacy `toggleMode` boolean and the new
    /// `keyMode` key. A config predating `keyMode` keeps its historical behavior (toggleMode true
    /// → toggle, else hold). When both keys are present `keyMode` wins, and Settings keeps
    /// `toggleMode` synced for downgrade safety (SettingsViewModel.toConfig). Every consumer —
    /// handleKeyDown, handleKeyUp, the Globe-key advice — resolves through this and never a
    /// site-local default, for the same reason `effectivePunctuationMode` exists: site-local
    /// `??` defaults are exactly how display-vs-runtime drift happens.
    var effectiveKeyMode: KeyMode {
        keyMode ?? ((toggleMode?.value == true) ? .toggle : .hold)
    }
}
