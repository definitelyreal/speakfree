// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import Carbon
import Foundation

/// Carbon registration reports an occupied global shortcut without adding another
/// event tap. It cannot discover every app-local shortcut; the user can change it.
final class HistoryShortcut {
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    var onAvailabilityChanged: ((String?) -> Void)?
    typealias Register = (UInt16, UInt32) -> (OSStatus, EventHotKeyRef?)
    private let register: Register
    private let unregister: (EventHotKeyRef) -> Void
    private let recordingGate: ShortcutRecordingGate
    private var recordingObserver: NSObjectProtocol?
    private var latestSettings: HistorySettings?
    private var latestDictation: HotkeyConfig?

    init(recordingGate: ShortcutRecordingGate = .shared,
         register: @escaping Register = HistoryShortcut.registerGlobally,
         unregister: @escaping (EventHotKeyRef) -> Void = { _ = UnregisterEventHotKey($0) },
         installEventHandler: Bool = true) {
        self.recordingGate = recordingGate
        self.register = register
        self.unregister = unregister
        recordingObserver = recordingGate.notificationCenter.addObserver(
            forName: ShortcutRecordingGate.changed, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? ShortcutRecordingGate) === self.recordingGate,
                  let settings = self.latestSettings, let dictation = self.latestDictation else { return }
            let error = self.configure(settings, dictation: dictation)
            self.onAvailabilityChanged?(error)
        }
        guard installEventHandler else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53464849 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<HistoryShortcut>.fromOpaque(context).takeUnretainedValue()
            guard !shortcut.recordingGate.snapshot.isActive else { return noErr }
            shortcut.onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func configure(_ settings: HistorySettings, dictation: HotkeyConfig) -> String? {
        latestSettings = settings
        latestDictation = dictation
        if let key { unregister(key); self.key = nil }
        guard !recordingGate.snapshot.isActive else { return nil }
        guard settings.retention != .off, !settings.shortcutModifiers.isEmpty else { return nil }
        guard HistorySettings.isSafeShortcut(settings.shortcutModifiers) else {
            return "Use Command, Option, or Control with the history key."
        }
        let mods = HistorySettings.normalizedModifiers(settings.shortcutModifiers)
        if settings.shortcutKeyCode == dictation.keyCode && mods == HistorySettings.normalizedModifiers(dictation.modifiers) {
            return "History and dictation need different shortcuts. Change History's shortcut in Settings."
        }
        var flags: UInt32 = 0
        if mods.contains("cmd") || mods.contains("command") { flags |= UInt32(cmdKey) }
        if mods.contains("shift") { flags |= UInt32(shiftKey) }
        if mods.contains("option") || mods.contains("alt") { flags |= UInt32(optionKey) }
        if mods.contains("ctrl") || mods.contains("control") { flags |= UInt32(controlKey) }
        guard flags != 0 else { return "That shortcut uses an unsupported modifier." }
        let (status, registeredKey) = register(settings.shortcutKeyCode, flags)
        key = registeredKey
        return status == noErr ? nil : "The history shortcut is unavailable. Choose another in Settings → Clipboard."
    }

    private static func registerGlobally(_ code: UInt16, _ flags: UInt32) -> (OSStatus, EventHotKeyRef?) {
        var key: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), flags, EventHotKeyID(signature: 0x53464849, id: 1),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &key)
        return (status, key)
    }

    deinit {
        if let recordingObserver { recordingGate.notificationCenter.removeObserver(recordingObserver) }
        if let key { unregister(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
