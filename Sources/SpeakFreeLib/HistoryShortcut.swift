// ai-suggestion:unverified · session:unknown · 2026-10-05
// ai-suggestion:unverified · session:unknown/agent:audio_file_integrity · 2026-10-03
import Carbon
import Foundation

/// Independent Carbon registrations report occupied global shortcuts without another event tap.
final class HistoryShortcut {
    typealias Action = HistorySettings.Action
    typealias Register = (Action, UInt16, UInt32) -> (OSStatus, EventHotKeyRef?)
    private struct Registration { let shortcut: HistorySettings.Shortcut; let key: EventHotKeyRef }
    private var registrations: [Action: Registration] = [:]
    private var handler: EventHandlerRef?
    var onPress: ((Action) -> Void)?
    var onAvailabilityChanged: ((String?) -> Void)?
    private(set) var availabilityErrors: [Action: String] = [:]
    private let register: Register
    private let unregister: (EventHotKeyRef) -> Void
    private let systemShortcuts: () -> ShortcutConflictHints.SystemSnapshot
    private let recordingGate: ShortcutRecordingGate
    private var recordingObserver: NSObjectProtocol?
    private var latestSettings: HistorySettings?
    private var latestDictation: HotkeyConfig?

    init(recordingGate: ShortcutRecordingGate = .shared,
         register: @escaping Register = HistoryShortcut.registerGlobally,
         unregister: @escaping (EventHotKeyRef) -> Void = { _ = UnregisterEventHotKey($0) },
         systemShortcuts: (() -> ShortcutConflictHints.SystemSnapshot)? = nil,
         installEventHandler: Bool = true) {
        self.recordingGate = recordingGate; self.register = register; self.unregister = unregister
        // An inert test environment must not query the host's actual shortcut settings.
        if let systemShortcuts { self.systemShortcuts = systemShortcuts }
        else if installEventHandler { self.systemShortcuts = { ShortcutConflictHints.systemSnapshot() } }
        else { self.systemShortcuts = { .available([]) } }
        recordingObserver = recordingGate.notificationCenter.addObserver(
            forName: ShortcutRecordingGate.changed, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? ShortcutRecordingGate) === self.recordingGate,
                  let settings = self.latestSettings, let dictation = self.latestDictation else { return }
            self.onAvailabilityChanged?(self.configure(settings, dictation: dictation))
        }
        guard installEventHandler else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53464849 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HistoryShortcut>.fromOpaque(context).takeUnretainedValue().receive(actionID: id.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// The Carbon handler and deterministic tests share this dispatch boundary.
    func receive(actionID: UInt32) {
        guard !recordingGate.snapshot.isActive,
              let action = Action.allCases.first(where: { $0.carbonID == actionID }),
              registrations[action] != nil else { return }
        onPress?(action)
    }

    func configure(_ settings: HistorySettings, dictation: HotkeyConfig) -> String? {
        latestSettings = settings; latestDictation = dictation; availabilityErrors = [:]
        guard !recordingGate.snapshot.isActive, settings.retention != .off else {
            for action in Action.allCases { remove(action) }
            return nil
        }
        let clipboardEnabled = settings.policy.captureClipboard
        let system = systemShortcuts()
        // Preserve unchanged valid registrations: a failed edit to one action must not
        // release another action's working shortcut to a competing application.
        for action in Action.allCases {
            // Keep the configured chord for later, but release its global reservation
            // whenever clipboard capture is disabled.
            if action == .clipboard && !clipboardEnabled { remove(action); continue }
            let desired = settings.shortcut(for: action)
            if !desired.isAssigned || desired.validationError != nil || desired.conflictsWithDictation(dictation)
                || system.conflict(for: desired) != nil
                || registrations[action].map({ !$0.shortcut.matches(desired) }) == true { remove(action) }
        }
        // Existing registrations win conflicts. On migration, Clipboard's legacy custom
        // shortcut wins over the newly introduced Dictations default.
        let priority: [Action] = [.clipboard, .dictation, .all]
        let order = priority.filter { registrations[$0] != nil } + priority.filter { registrations[$0] == nil }
        for action in order {
            guard action != .clipboard || clipboardEnabled else { continue }
            let desired = settings.shortcut(for: action)
            guard desired.isAssigned else { continue }
            if let error = desired.validationError { availabilityErrors[action] = error; continue }
            if let error = system.conflict(for: desired) { availabilityErrors[action] = error; continue }
            if desired.conflictsWithDictation(dictation) {
                availabilityErrors[action] = "\(desired.label) conflicts with your dictation key. Choose a different shortcut."
                continue
            }
            if let owner = Action.allCases.first(where: { $0 != action && registrations[$0]?.shortcut.matches(desired) == true }) {
                availabilityErrors[action] = "\(desired.label) is already used by \(owner.title). Choose a different shortcut."
                continue
            }
            if registrations[action] != nil { continue }
            let (status, key) = register(action, desired.keyCode, ShortcutConflictHints.carbonFlags(desired.modifiers))
            if status == noErr, let key { registrations[action] = .init(shortcut: desired, key: key) }
            else {
                if let key { unregister(key) }
                availabilityErrors[action] = ShortcutConflictHints.registrationFailure(status, shortcut: desired)
            }
        }
        let errors = Action.allCases.compactMap { action in availabilityErrors[action].map { "\(action.title): \($0)" } }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func remove(_ action: Action) {
        if let registration = registrations.removeValue(forKey: action) { unregister(registration.key) }
    }
    private static func registerGlobally(_ action: Action, _ code: UInt16, _ flags: UInt32) -> (OSStatus, EventHotKeyRef?) {
        var key: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), flags, EventHotKeyID(signature: 0x53464849, id: action.carbonID),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &key)
        return (status, key)
    }
    deinit {
        if let recordingObserver { recordingGate.notificationCenter.removeObserver(recordingObserver) }
        for registration in registrations.values { unregister(registration.key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
