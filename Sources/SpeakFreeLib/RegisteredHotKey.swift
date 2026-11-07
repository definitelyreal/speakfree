import Carbon.HIToolbox
import Foundation

/// A key combination registered with macOS, which then tells the app when it is pressed
/// and released. Unlike a keyboard monitor, this never sees any other typing, needs no
/// Accessibility access, and keeps working while Secure Input is on (a password field,
/// or an app that has left Secure Input stuck).
final class RegisteredHotKey {
    struct Combination: Equatable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    /// F1–F20, which are safe to claim with no modifier.
    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// The combination to register for a shortcut, or nil when it must not be registered:
    /// a modifier used alone is not a combination, and a plain character key would be
    /// taken away from ordinary typing everywhere.
    static func combination(keyCode: UInt16, modifierFlags flags: UInt64) -> Combination? {
        guard !modifierKeyCodes.contains(keyCode) else { return nil }
        let strong = UInt64(1 << 20) | UInt64(1 << 18) | UInt64(1 << 19)  // cmd, ctrl, option
        guard flags & strong != 0 || functionKeyCodes.contains(keyCode) else { return nil }
        var carbon = 0
        if flags & UInt64(1 << 20) != 0 { carbon |= cmdKey }
        if flags & UInt64(1 << 17) != 0 { carbon |= shiftKey }
        if flags & UInt64(1 << 18) != 0 { carbon |= controlKey }
        if flags & UInt64(1 << 19) != 0 { carbon |= optionKey }
        return Combination(keyCode: UInt32(keyCode), carbonModifiers: UInt32(carbon))
    }

    private let id: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?

    /// `id` tells this shortcut apart from the app's other registered shortcuts.
    init(id: UInt32) {
        self.id = id
    }

    var isRegistered: Bool { hotKey != nil }

    /// Ask macOS for the combination. Returns false when it is refused, usually because
    /// another app has already claimed it. Callbacks arrive on the main thread.
    @discardableResult
    func register(_ combination: Combination,
                  onPressed: @escaping () -> Void,
                  onReleased: @escaping () -> Void) -> Bool {
        unregister()
        self.onPressed = onPressed
        self.onReleased = onReleased
        if handler == nil {
            var specs = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let me = Unmanaged<RegisteredHotKey>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr, pressed.id == me.id else { return OSStatus(eventNotHandledErr) }
                if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                    me.onPressed?()
                } else {
                    me.onReleased?()
                }
                return noErr
            }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5346_504C), id: id)  // "SFPL"
        let status = RegisterEventHotKey(combination.keyCode, combination.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
            DiagnosticLogger.shared.log("RegisteredHotKey: macOS refused the shortcut (status \(status))")
        }
        return status == noErr
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}
