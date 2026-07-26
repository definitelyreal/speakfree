// Claude · 2026-07-26 · Session: ec24b5ef-be6a-4c4b-be38-a3b84ca63074
//
// Pure predicates for "the hotkey you picked has a consequence you should know about".
// Kept out of the SwiftUI view so the conditions are testable without a window.

import Foundation

public enum HotkeyAdvice {

    /// True when the chosen hotkey costs the user the macOS Globe-key action.
    ///
    /// fn is the only hotkey macOS binds its own behavior to (System Settings → Keyboard →
    /// "Press 🌐 key to", which defaults to the emoji drawer). speakfree's event tap consumes
    /// every fn transition while fn is the hotkey, so that action cannot fire.
    ///
    /// True of the steady state, which is what the user needs to know. It is not an absolute:
    /// during a tap outage (a rebuild window, the creation-retry ladder, or the NSEvent fallback,
    /// which structurally cannot suppress) macOS can see a complete fn down+up and the drawer can
    /// open. Those are error paths measured in fractions of a second, and hedging the sentence
    /// would cost more clarity than it buys.
    ///
    /// Surfaced for TOGGLE mode only, by Michael's call (2026-07-26). The suppression is real
    /// in both modes, but only toggle mode makes it noticeable: macOS fires the globe action on
    /// a quick TAP, and a tap is exactly what toggle mode asks the user to do, so that is the
    /// configuration where someone reaches for emoji and finds the key inert. Warning every
    /// hold-mode user about a key press they never make would be noise.
    public static func suppressesGlobeKeyAction(keyCode: UInt16, toggleMode: Bool) -> Bool {
        keyCode == KeyCodes.fnKeyCode && toggleMode
    }

    /// Wording note (2026-07-26 adversarial review, MAJOR, found by two reviewers): this used to
    /// read "Using the fn key in TOGGLE MODE disables the emoji drawer", which blamed the mode.
    /// The mode is not the cause — HotkeyManager has no concept of it and consumes fn in both.
    /// A user would read that, switch to Hold (one click away, in the same row), watch the banner
    /// vanish, and still have a dead emoji key with nothing left to explain it. The condition
    /// stays toggle-only per Michael; the sentence now blames the right thing.
    public static let globeKeyNotice =
        "speakfree is using the fn key, so it can't open the \u{1F310} emoji drawer."

    public static let globeKeyFixLabel = "Switch to the Right Option key"

    /// The hotkey the fix link switches to. Right Option carries no macOS action, so nothing
    /// has to be traded away for it.
    public static let globeKeyFixKeyCode = KeyCodes.rightOptionKeyCode
}
