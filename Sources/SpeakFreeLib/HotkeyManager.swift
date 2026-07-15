import AppKit
import Foundation
import CoreGraphics

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private var globalMonitor: Any?
    private var keyDownMonitor: Any?
    private let keyCode: UInt16
    private let requiredModifiers: UInt64
    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?
    private var onAbort: (() -> Void)?
    private var modifierPressed = false
    /// When fn was pressed — used to distinguish keyboard shortcuts (key within 300ms) from dictation
    private var modifierPressedAt: UInt64 = 0
    /// Track tap re-enables to detect runaway loops
    private var tapReEnableCount = 0
    private var tapReEnableWindowStart: UInt64 = 0
    /// Track tap creation retries after TCC propagation delay
    private var tapRetryCount = 0

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
        tearDownEventTap()
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        stopKeyDownMonitor()
    }

    /// Verify the event tap is alive. If it died, recreate it.
    func ensureTapHealthy() {
        guard isModifierOnlyKey(keyCode) else { return } // only event tap keys need this
        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                DiagnosticLogger.shared.log("HotkeyManager: event tap disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        } else {
            DiagnosticLogger.shared.log("HotkeyManager: event tap missing — recreating")
            startEventTap()
        }
    }

    deinit {
        stop()
    }

    // MARK: - CGEventTap (modifier keys — suppresses default system action)

    private func startEventTap() {
        tearDownEventTap()
        // Only listen for flagsChanged + tap-disabled events.
        // keyDown is NOT included here — intercepting every keyDown system-wide
        // breaks modifier handling (e.g. option+delete deletes by char instead of word).
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )

        let selfPtr = Unmanaged.passUnretained(self)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                // macOS disables taps that stall — destroy and recreate from scratch
                // to prevent degraded event delivery over time (affects option+delete etc.)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Rate-limit re-enables: if we've re-enabled >5 times in 10 seconds,
                    // something is wrong — tear down and recreate after a delay to avoid
                    // freezing the input pipeline.
                    let now = mach_absolute_time()
                    var timebaseInfo = mach_timebase_info_data_t()
                    mach_timebase_info(&timebaseInfo)
                    let elapsedNs = (now - manager.tapReEnableWindowStart) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
                    let elapsedSec = Double(elapsedNs) / 1_000_000_000

                    if elapsedSec > 10 {
                        manager.tapReEnableCount = 0
                        manager.tapReEnableWindowStart = now
                    }
                    manager.tapReEnableCount += 1

                    if manager.tapReEnableCount > 5 {
                        // Too many re-enables — tear down and recreate after a delay
                        DiagnosticLogger.shared.log("HotkeyManager: tap disabled \(manager.tapReEnableCount) times in \(Int(elapsedSec))s — rebuilding after delay")
                        manager.tapReEnableCount = 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            manager.tearDownEventTap()
                            manager.startEventTap()
                        }
                        return Unmanaged.passUnretained(event)
                    }

                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr.toOpaque()
        )

        guard let tap = tap else {
            // Tap creation failed — accessibility may not be fully propagated yet.
            if tapRetryCount < 10 {
                tapRetryCount += 1
                let delay = Double(tapRetryCount) * 1.0
                DiagnosticLogger.shared.log("HotkeyManager: event tap creation failed — retry \(tapRetryCount)/10 in \(Int(delay))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.eventTap == nil else { return }
                    self.startEventTap()
                }
            } else {
                DiagnosticLogger.shared.log("HotkeyManager: event tap failed after 10 attempts — falling back to global monitor")
                startGlobalMonitor()
            }
            return
        }
        tapRetryCount = 0  // Success — reset counter

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src

        // Run the tap callback on a dedicated high-priority thread, not the main run loop.
        // A .headInsertEventTap on the main run loop means ANY main-thread work
        // (AX semaphore waits, animations) delays system-wide modifier key delivery —
        // causing Shift+click selection failures and cursor flicker in other apps.
        let startSema = DispatchSemaphore(value: 0)
        let thread = Thread {
            self.eventTapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            startSema.signal()
            CFRunLoopRun()  // blocks until tearDownEventTap calls CFRunLoopStop
        }
        thread.name = "com.speakfree.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        startSema.wait()  // ensure run loop is live before enabling

        CGEvent.tapEnable(tap: tap, enable: true)
        DiagnosticLogger.shared.log("HotkeyManager: event tap created on dedicated thread")
    }

    private func tearDownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let src = runLoopSource, let rl = eventTapRunLoop {
            CFRunLoopRemoveSource(rl, src, .commonModes)
            CFRunLoopStop(rl)  // causes the dedicated thread's CFRunLoopRun() to return
            eventTapRunLoop = nil
        }
        runLoopSource = nil
    }

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode) else {
            // IMPORTANT: pass through ALL non-fn flagsChanged events unmodified.
            // This includes Option, Command, Shift, Control key presses/releases.
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)

        if fnDown && !modifierPressed {
            // Check required modifiers if any
            if requiredModifiers != 0 {
                let currentMods = UInt64(flags.rawValue) & 0x00FF0000
                guard currentMods & requiredModifiers == requiredModifiers else {
                    return Unmanaged.passUnretained(event)
                }
            }
            modifierPressed = true
            modifierPressedAt = mach_absolute_time()
            DispatchQueue.main.async {
                self.startKeyDownMonitor()
                self.onKeyDown?()
            }
            return nil  // consume fn press — suppresses emoji drawer
        } else if !fnDown && modifierPressed {
            modifierPressed = false
            DispatchQueue.main.async {
                self.stopKeyDownMonitor()
                self.onKeyUp?()
            }
            return nil  // consume — suppresses emoji drawer / system dictation on fn release
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - KeyDown monitor (only active while fn is held)

    private func startKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.modifierPressed else { return }
            let elapsed = mach_absolute_time() - self.modifierPressedAt
            var timebaseInfo = mach_timebase_info_data_t()
            mach_timebase_info(&timebaseInfo)
            let elapsedMs = (elapsed * UInt64(timebaseInfo.numer)) / (UInt64(timebaseInfo.denom) * 1_000_000)
            // If a key arrives within 300ms of fn press, it's a keyboard shortcut — abort
            if elapsedMs < 300 {
                self.modifierPressed = false
                self.stopKeyDownMonitor()
                self.onAbort?()
            }
        }
    }

    private func stopKeyDownMonitor() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
    }

    // MARK: - NSEvent global monitor (non-modifier keys)

    private func startGlobalMonitor() {
        // .flagsChanged is required for the modifier-only fallback (I5): when the CGEventTap can't
        // be created, a fn hotkey arrives here as flagsChanged, never keyDown/keyUp. Without it the
        // fallback monitor is silently dead for fn even though it looks installed.
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
    }

    /// The fn transition implied by a flagsChanged event in the global-monitor fallback, given the
    /// currently-observed fn state and whether we already consider the modifier pressed. Mirrors the
    /// CGEventTap logic (handleCGEvent) so the fallback path behaves identically. Pure so it is
    /// unit-testable without posting real flagsChanged events (I5).
    enum FnTransition: Equatable { case keyDown, keyUp, none }

    static func fnTransition(fnDown: Bool, modifierPressed: Bool) -> FnTransition {
        if fnDown && !modifierPressed { return .keyDown }
        if !fnDown && modifierPressed { return .keyUp }
        return .none
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            handleModifierFlagsChanged(event)
            return
        }
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

    /// Fallback fn handling for the global monitor (I5). Only relevant for modifier-only hotkeys —
    /// non-modifier keys already come through as keyDown/keyUp and ignore flagsChanged.
    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard isModifierOnlyKey(keyCode), event.keyCode == keyCode else { return }
        let fnDown = event.modifierFlags.contains(.function)
        switch Self.fnTransition(fnDown: fnDown, modifierPressed: modifierPressed) {
        case .keyDown:
            // Gate required modifiers only on the down transition (mirrors handleCGEvent); on
            // release the modifiers are already gone.
            if requiredModifiers != 0 {
                let currentMods = UInt64(event.modifierFlags.rawValue) & 0x00FF0000
                guard currentMods & requiredModifiers == requiredModifiers else { return }
            }
            modifierPressed = true
            onKeyDown?()
        case .keyUp:
            modifierPressed = false
            onKeyUp?()
        case .none:
            break
        }
    }

    private func isModifierOnlyKey(_ code: UInt16) -> Bool {
        return [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code)
    }
}
