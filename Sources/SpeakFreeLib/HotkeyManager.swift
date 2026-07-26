import AppKit
import Foundation
import CoreGraphics

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private var globalMonitor: Any?
    private var keyDownMonitor: Any?
    private var interactionMonitor: Any?
    private let keyCode: UInt16
    private let requiredModifiers: UInt64
    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?
    private var onAbort: (() -> Void)?
    private var onUserInteraction: (() -> Void)?
    private var modifierPressed = false
    /// Consecutive swallowed phantom fn-ups (failsafe cap 4; reset on honored release).
    private var phantomUpStreak = 0
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

    func start(
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void,
        onAbort: (() -> Void)? = nil,
        onUserInteraction: (() -> Void)? = nil
    ) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onAbort = onAbort
        self.onUserInteraction = onUserInteraction
        startInteractionMonitor()

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
        if let monitor = interactionMonitor {
            NSEvent.removeMonitor(monitor)
            interactionMonitor = nil
        }
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
        // L3: the tap is the primary (and self-suppressing) path now. If an earlier tap-creation
        // failure had installed the global-monitor fallback, it is superseded — leaving it running
        // would double-dispatch every fn transition (handleNSEvent AND handleCGEvent). Remove it.
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
            DiagnosticLogger.shared.log("HotkeyManager: event tap up — removed superseded global-monitor fallback")
        }
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
            // Phantom-release guard (2026-07-26): mid-hold, the tap can deliver a
            // spurious fn-up + fn-down flap (two dictations truncated mid-clause at
            // 00:33 while the key never moved). Ask the HID HARDWARE state whether
            // fn is really still down — .hidSystemState, NOT .combinedSessionState:
            // this tap CONSUMES fn events, so the session state never sees releases
            // and reported "still down" for every genuine up, stranding a recording
            // that could never stop (Michael, 00:52). Failsafe: never swallow more
            // than 4 consecutive ups — if the HID read is ever wrong on some
            // keyboard, the release goes through rather than recording forever.
            let physicalFlags = CGEventSource.flagsState(.hidSystemState)
            if physicalFlags.contains(.maskSecondaryFn) && phantomUpStreak < 4 {
                phantomUpStreak += 1
                DiagnosticLogger.shared.log(
                    "HotkeyManager: phantom fn-up swallowed (HID reports key still down, streak \(phantomUpStreak))")
                return nil
            }
            phantomUpStreak = 0
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

    // MARK: - Cursor-context invalidation monitor

    /// Observe only interactions that can move the cursor/focus between two
    /// dictations. This is a passive global monitor: it never suppresses events.
    /// The configured hotkey and SpeakFree's own synthetic insertion events are
    /// excluded, so a genuine back-to-back continuation keeps its remembered tail.
    private func startInteractionMonitor() {
        guard interactionMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            let sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
            guard Self.shouldCountAsUserInteraction(
                eventType: event.type,
                // NSEvent.keyCode is only defined for key events; reading it on a
                // mouse-down can raise on some AppKit versions — and this closure runs
                // for every click anywhere in the OS.
                eventKeyCode: event.type == .keyDown ? event.keyCode : 0,
                eventModifiers: UInt64(event.modifierFlags.rawValue),
                sourcePID: sourcePID,
                currentPID: Int64(ProcessInfo.processInfo.processIdentifier),
                hotkeyKeyCode: self.keyCode,
                requiredModifiers: self.requiredModifiers,
                automationPID: Self.systemEventsPID()
            ) else { return }
            self.onUserInteraction?()
        }
        if interactionMonitor == nil {
            DiagnosticLogger.shared.log(
                "HotkeyManager: cursor-context interaction monitor unavailable")
        }
    }

    static func shouldCountAsUserInteraction(
        eventType: NSEvent.EventType,
        eventKeyCode: UInt16,
        eventModifiers: UInt64,
        sourcePID: Int64?,
        currentPID: Int64,
        hotkeyKeyCode: UInt16,
        requiredModifiers: UInt64,
        automationPID: Int64? = nil
    ) -> Bool {
        let relevantTypes: Set<NSEvent.EventType> = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        guard relevantTypes.contains(eventType) else { return false }
        if sourcePID == currentPID { return false }
        // The remote-desktop insertion path pastes via System Events ("keystroke v"
        // at +0.4s), so that synthetic Cmd-V carries System Events' PID, not ours —
        // without this exclusion it lands after the insertion generation is captured
        // and self-invalidates the remembered context that remote-desktop apps
        // (AX-opaque) depend on. Real typing never originates from System Events.
        if let automationPID, sourcePID == automationPID { return false }
        if eventType == .keyDown, eventKeyCode == hotkeyKeyCode {
            let modifiers = eventModifiers & 0x00FF0000
            if requiredModifiers == 0 || modifiers & requiredModifiers == requiredModifiers {
                return false
            }
        }
        return true
    }

    /// PID of System Events, cached briefly — the interaction monitor consults this on
    /// every global keystroke/click and must not run a launch-services query each time.
    private static var systemEventsPIDCache: (pid: Int64?, at: Date) = (nil, .distantPast)
    private static let systemEventsPIDCacheLock = NSLock()
    private static func systemEventsPID() -> Int64? {
        systemEventsPIDCacheLock.lock()
        defer { systemEventsPIDCacheLock.unlock() }
        let now = Date()
        if now.timeIntervalSince(systemEventsPIDCache.at) > 30 {
            let pid = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systemevents")
                .first.map { Int64($0.processIdentifier) }
            systemEventsPIDCache = (pid, now)
        }
        return systemEventsPIDCache.pid
    }

    // MARK: - NSEvent global monitor (non-modifier keys)

    private func startGlobalMonitor() {
        // L3: never double-install. `start()`, the tap-creation-failure fallback, and a retry can
        // all reach here; without this guard a second install leaks the first monitor AND makes
        // every event dispatch handleNSEvent twice (a latent double-fire of onKeyDown/onKeyUp).
        guard globalMonitor == nil else { return }
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
