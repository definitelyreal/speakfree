import AppKit
import Foundation
import CoreGraphics

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private let keyCode: UInt16
    private let requiredModifiers: UInt64
    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?
    private var onAbort: (() -> Void)?
    private var modifierPressed = false
    /// When fn was pressed — used to distinguish keyboard shortcuts (key within 300ms) from dictation
    private var modifierPressedAt: UInt64 = 0

    init(keyCode: UInt16, modifiers: UInt64 = 0) {
        self.keyCode = keyCode
        self.requiredModifiers = modifiers
    }

    func start(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void, onAbort: (() -> Void)? = nil) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onAbort = onAbort

        // For modifier-only keys (like Fn), use a CGEventTap so we can suppress
        // the default system action (e.g. the emoji drawer that Fn normally opens).
        if isModifierOnlyKey(keyCode) {
            startEventTap()
        } else {
            startGlobalMonitor()
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - CGEventTap (modifier keys — suppresses default system action)

    private func startEventTap() {
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )

        // passUnretained: Swift already holds a strong reference via the HotkeyManager ivar.
        // The tap callback doesn't outlive HotkeyManager because stop() disables it in deinit.
        let selfPtr = Unmanaged.passUnretained(self)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                // macOS disables taps that stall — re-enable immediately when notified
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return nil
                }
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr.toOpaque()
        )

        guard let tap = tap else {
            startGlobalMonitor()
            return
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // If a real key is pressed shortly after fn (within 300ms), this is a keyboard shortcut
        // (e.g. fn+shift+F5), not dictation. Abort recording and let the key pass through.
        // After 300ms we're definitely in dictation mode — ignore stray keyDown events.
        if type == .keyDown && modifierPressed {
            let elapsed = mach_absolute_time() - modifierPressedAt
            var timebaseInfo = mach_timebase_info_data_t()
            mach_timebase_info(&timebaseInfo)
            let elapsedMs = (elapsed * UInt64(timebaseInfo.numer)) / (UInt64(timebaseInfo.denom) * 1_000_000)
            if elapsedMs < 300 {
                modifierPressed = false
                DispatchQueue.main.async { self.onAbort?() }
                return Unmanaged.passRetained(event)  // pass through so the shortcut works
            }
            return Unmanaged.passRetained(event)  // in dictation mode — ignore
        }

        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode) else {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)

        if fnDown && !modifierPressed {
            // Check required modifiers if any
            if requiredModifiers != 0 {
                let currentMods = UInt64(flags.rawValue) & 0x00FF0000
                guard currentMods & requiredModifiers == requiredModifiers else {
                    return Unmanaged.passRetained(event)
                }
            }
            modifierPressed = true
            modifierPressedAt = mach_absolute_time()
            DispatchQueue.main.async { self.onKeyDown?() }
            return nil  // consume — suppresses emoji drawer
        } else if !fnDown && modifierPressed {
            modifierPressed = false
            DispatchQueue.main.async { self.onKeyUp?() }
            return nil  // consume
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - NSEvent global monitor (non-modifier keys)

    private func startGlobalMonitor() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }
        if requiredModifiers != 0 {
            let currentMods = UInt64(event.modifierFlags.rawValue) & 0x00FF0000
            guard currentMods & requiredModifiers == requiredModifiers else { return }
        }
        if event.type == .keyDown {
            onKeyDown?()
        } else if event.type == .keyUp {
            onKeyUp?()
        }
    }

    private func isModifierOnlyKey(_ code: UInt16) -> Bool {
        return [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code)
    }
}
