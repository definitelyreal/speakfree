import AppKit

/// When the microphone is opened ahead of a dictation.
public enum PrelistenMode: String, CaseIterable {
    /// Always open, holding the last half-second. macOS shows its microphone indicator
    /// the whole time the app runs.
    case always
    /// Opened when the first key of the dictation shortcut goes down, closed again
    /// shortly after it comes up. The indicator appears only then.
    case onShortcut = "shortcut"
    /// Opened when a dictation starts.
    case off
}

/// Watches for the modifier keys of the dictation shortcut being held, which is the
/// earliest sign that a dictation is about to start, and asks for the microphone to be
/// opened ahead of the final key. A shortcut that is one key alone gives no such warning.
final class ShortcutArming {
    /// How long the microphone stays open after the modifiers are released.
    static let linger: TimeInterval = 0.6

    private static let modifierMask = UInt64(1 << 17) | UInt64(1 << 18) | UInt64(1 << 19) | UInt64(1 << 20)

    /// The shortcut's modifier flags (HotkeyConfig.modifierFlags); 0 = none.
    var required: UInt64 = 0

    private let schedule: (@escaping () -> Void) -> () -> Void
    private let onChange: (Bool) -> Void
    private var isOpen = false
    private var cancelClose: (() -> Void)?
    private var monitors: [Any] = []

    /// `schedule` runs work after `linger` and returns a way to cancel it.
    init(schedule: @escaping (@escaping () -> Void) -> () -> Void = ShortcutArming.afterLinger,
         onChange: @escaping (Bool) -> Void) {
        self.schedule = schedule
        self.onChange = onChange
    }

    static func canArm(required: UInt64) -> Bool {
        required & modifierMask != 0
    }

    /// True when exactly the shortcut's modifiers are held: one more or one fewer is some
    /// other shortcut.
    static func isArmed(flags: UInt64, required: UInt64) -> Bool {
        canArm(required: required) && flags & modifierMask == required & modifierMask
    }

    func modifiersChanged(_ flags: UInt64) {
        if Self.isArmed(flags: flags, required: required) {
            cancelClose?()
            cancelClose = nil
            setOpen(true)
        } else if isOpen, cancelClose == nil {
            cancelClose = schedule { [weak self] in
                self?.cancelClose = nil
                self?.setOpen(false)
            }
        }
    }

    /// Start watching the keyboard. Safe to call again.
    func start() {
        guard monitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in
            self?.modifiersChanged(UInt64(event.modifierFlags.rawValue))
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        reset()
    }

    /// Close the microphone now and forget any pending close.
    func reset() {
        cancelClose?()
        cancelClose = nil
        setOpen(false)
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        onChange(open)
    }

    static func afterLinger(_ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: item)
        return { item.cancel() }
    }
}
