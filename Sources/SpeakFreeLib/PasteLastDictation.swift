import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// An optional global shortcut that inserts the most recent dictation again, wherever the
/// cursor is. The text goes in through the normal insertion path, so it is never left on
/// the clipboard. There is no shortcut until the user chooses one in Settings.
final class PasteLastDictation {
    struct Registration: Equatable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    /// Called on the main queue when the shortcut is pressed.
    var onTrigger: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    static func textToPaste(last: String?) -> String? {
        guard let last, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return last
    }

    /// A usable shortcut is a real key plus Command, Control or Option. Anything less
    /// would swallow ordinary typing system-wide.
    static func isUsable(_ hotkey: HotkeyConfig) -> Bool {
        let strong = UInt64(1 << 20) | UInt64(1 << 18) | UInt64(1 << 19)  // cmd, ctrl, option
        return !modifierKeyCodes.contains(hotkey.keyCode) && hotkey.modifierFlags & strong != 0
    }

    static func registration(for hotkey: HotkeyConfig?) -> Registration? {
        guard let hotkey, isUsable(hotkey) else { return nil }
        let flags = hotkey.modifierFlags
        var carbon = 0
        if flags & UInt64(1 << 20) != 0 { carbon |= cmdKey }
        if flags & UInt64(1 << 17) != 0 { carbon |= shiftKey }
        if flags & UInt64(1 << 18) != 0 { carbon |= controlKey }
        if flags & UInt64(1 << 19) != 0 { carbon |= optionKey }
        return Registration(keyCode: UInt32(hotkey.keyCode), carbonModifiers: UInt32(carbon))
    }

    /// Inserting while the shortcut's modifiers are still down would turn the synthetic
    /// paste or typed characters into other shortcuts, so insertion waits for a clean keyboard.
    static func modifiersReleased(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty
    }

    /// Replace the registered shortcut; nil (or an unusable one) leaves none registered.
    func apply(_ hotkey: HotkeyConfig?) {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let registration = Self.registration(for: hotkey) else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<PasteLastDictation>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.onTrigger?() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5346_504C), id: 1)  // "SFPL"
        let status = RegisterEventHotKey(registration.keyCode, registration.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            DiagnosticLogger.shared.log("PasteLastDictation: could not register shortcut (status \(status))")
        }
    }
}
