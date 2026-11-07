import CoreGraphics
import Foundation

/// Swallows a bare Escape while a dictation is live and reports it, so Escape discards
/// the dictation instead of also reaching the frontmost app. The tap exists once and is
/// only switched on while the overlay is showing; every other key always passes through.
final class EscapeCancelTap {
    enum Action: Equatable { case abortRecording, discardPendingText, ignore }

    /// Called on the main queue for each swallowed Escape.
    var onEscape: (() -> Void)?

    private var tap: CFMachPort?
    private var active = false

    static func isBareEscape(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 53
            && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    static func action(isRecording: Bool, overlayVisible: Bool) -> Action {
        if isRecording { return .abortRecording }
        return overlayVisible ? .discardPendingText : .ignore
    }

    func setActive(_ wanted: Bool) {
        active = wanted
        if wanted && tap == nil { install() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: wanted) }
    }

    private func install() {
        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue))
        let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EscapeCancelTap>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if me.active, let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard me.active, type == .keyDown,
                      EscapeCancelTap.isBareEscape(
                        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                        flags: event.flags) else {
                    return Unmanaged.passUnretained(event)
                }
                DispatchQueue.main.async { me.onEscape?() }
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let created else {
            DiagnosticLogger.shared.log("EscapeCancelTap: could not create the event tap")
            return
        }
        tap = created
        // Its own thread: a tap on the main run loop would delay every keystroke
        // system-wide whenever the main thread is busy.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.speakfree.escape-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
