import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// An optional global shortcut that inserts a remembered dictation, wherever the cursor
/// is: the most recent one, or the most recently cancelled one. The text goes in through
/// the normal insertion path, so it is never left on the clipboard. There is no shortcut
/// until the user chooses one in Settings.
final class PasteLastDictation {
    enum Kind: UInt32 {
        case pasteLast = 1
        case recoverDiscarded = 2
    }

    struct Registration: Equatable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    /// Called on the main queue when the shortcut is pressed.
    var onTrigger: (() -> Void)?

    private let kind: Kind
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(kind: Kind = .pasteLast) {
        self.kind = kind
    }

    var hotKeyID: UInt32 { kind.rawValue }

    /// Every instance sees every registered shortcut's press; each answers only its own.
    func answers(hotKeyID: UInt32) -> Bool {
        hotKeyID == self.hotKeyID
    }

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
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<PasteLastDictation>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr, me.answers(hotKeyID: pressed.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { me.onTrigger?() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5346_504C), id: hotKeyID)  // "SFPL"
        let status = RegisterEventHotKey(registration.keyCode, registration.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            DiagnosticLogger.shared.log("PasteLastDictation: could not register shortcut (status \(status))")
        }
    }
}
