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

    /// End a take whose release was never observed.
    ///
    /// 2026-07-26 (Codex round 2, BLOCKER — pre-existing, not introduced by the sided-modifier
    /// work, and it hits fn too): while the tap is disabled it sees no events, and nothing
    /// replays them when it comes back. macOS gives no such guarantee. So a release during a
    /// tap outage — most reachably the deliberate 2s pause before a rebuild after 5 disables —
    /// was simply lost: `modifierPressed` stayed true, `onKeyUp` never fired, and the recording
    /// ran until the user pressed and released the key again.
    ///
    /// Every path that loses or replaces the tap now asks the hardware whether the key is still
    /// held, and ends the take if it is not. The read can only be wrong in the direction of
    /// ending a take slightly early, and only inside an outage window that is already an error
    /// path — which is the right way round: a truncated take is recoverable, a stranded one
    /// silently eats a dictation.
    private func reconcilePressedState(_ reason: String) {
        guard modifierPressed, !Self.hotkeyIsPhysicallyDown(keyCode: keyCode) else { return }
        modifierPressed = false
        phantomUpStreak = 0
        DiagnosticLogger.shared.log(
            "HotkeyManager: release missed during \(reason) — key is physically up, ending take")
        DispatchQueue.main.async {
            self.stopKeyDownMonitor()
            self.onKeyUp?()
        }
    }

    /// Verify the event tap is alive. If it died, recreate it.
    func ensureTapHealthy() {
        // Modifier-only keys run on a CGEventTap; everything else ("Other…" keys) runs on an
        // NSEvent global monitor. Both can die, but only the tap was ever healed — so an
        // "Other…" hotkey whose monitor was torn down stayed silently dead until relaunch
        // (2026-08-01). `start()` picks the mechanism the same way; this mirrors it.
        guard isModifierOnlyKey(keyCode) else {
            if globalMonitor == nil {
                DiagnosticLogger.shared.log("HotkeyManager: global monitor missing — recreating")
                startGlobalMonitor()
            }
            return
        }
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
                            // The tap was blind for those 2 seconds — a release in that window
                            // reached nobody.
                            manager.reconcilePressedState("tap rebuild")
                        }
                        return Unmanaged.passUnretained(event)
                    }

                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    manager.reconcilePressedState("tap disable")
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
        let fnDown = Self.hotkeyIsDown(flags, keyCode: keyCode)

        // Same reducer the global-monitor fallback uses, so the two paths cannot drift.
        let transition = Self.fnTransition(fnDown: fnDown, modifierPressed: modifierPressed)
        let modifiersSatisfied: Bool = {
            guard requiredModifiers != 0 else { return true }
            let currentMods = UInt64(flags.rawValue) & 0x00FF0000
            return currentMods & requiredModifiers == requiredModifiers
        }()

        // ONE decision function owns consume-vs-pass, and every exit below routes through it.
        // 2026-07-26 round-3 review proved this necessary by mutation: with the disposition
        // inlined as four separate `return`s, deleting the redundant-transition swallow entirely
        // — the whole globe-key fix — still left 30 tests green, because `handleCGEvent` is
        // private and nothing could observe a return value.
        let disposition = Self.tapDisposition(transition: transition,
                                              keyCode: keyCode,
                                              requiredModifiersSatisfied: modifiersSatisfied)
        func result() -> Unmanaged<CGEvent>? {
            disposition == .consume ? nil : Unmanaged.passUnretained(event)
        }

        switch transition {
        case .keyDown:
            guard modifiersSatisfied else { return result() }
            modifierPressed = true
            modifierPressedAt = mach_absolute_time()
            DispatchQueue.main.async {
                self.startKeyDownMonitor()
                self.onKeyDown?()
            }
            return result()  // consume fn press — suppresses emoji drawer

        case .keyUp:
            // Phantom-release guard (2026-07-26): mid-hold, the tap can deliver a
            // spurious fn-up + fn-down flap (two dictations truncated mid-clause at
            // 00:33 while the key never moved). Ask the HID HARDWARE state whether
            // the key is really still down — .hidSystemState, NOT .combinedSessionState:
            // this tap CONSUMES the events, so the session state never sees releases
            // and reported "still down" for every genuine up, stranding a recording
            // that could never stop (Michael, 00:52). Failsafe: never swallow more
            // than 4 consecutive ups — if the HID read is ever wrong on some
            // keyboard, the release goes through rather than recording forever.
            if Self.releaseIsPhantom(physicallyDown: Self.hotkeyIsPhysicallyDown(keyCode: keyCode),
                                     phantomUpStreak: phantomUpStreak) {
                phantomUpStreak += 1
                DiagnosticLogger.shared.log(
                    "HotkeyManager: phantom fn-up swallowed (HID reports key still down, streak \(phantomUpStreak))")
                return result()
            }
            phantomUpStreak = 0
            modifierPressed = false
            DispatchQueue.main.async {
                self.stopKeyDownMonitor()
                self.onKeyUp?()
            }
            return result()  // consume — suppresses emoji drawer / system dictation on fn release

        case .none:
            break
        }

        // FALL-THROUGH: a transition that does not change our state — a down while we already
        // consider the key pressed, or an up while we do not. Letting these reach the OS is
        // what leaks the globe action in TOGGLE mode: the phantom-up guard above can leave
        // `modifierPressed` true after swallowing a release, so the user's NEXT genuine press
        // lands here, macOS sees a bare fn tap, and the emoji drawer opens over their work
        // (2026-07-26). Hold mode never exposed it because macOS fires the globe action on a
        // quick tap, not a hold.
        //
        // Swallowed for fn ONLY. While fn is the hotkey speakfree owns it outright, and the
        // fn+arrow / fn+F-key remappings are applied below this tap, so nothing else is lost.
        // Every other modifier keeps passing through: those keys carry meaning for other apps
        // and must not have stray transitions eaten.
        //
        // A redundant DOWN is deliberately absorbed here rather than treated as evidence of a
        // release we missed. Two rounds of adversarial review on 2026-07-26 settled this, and
        // both halves cost a rewrite to learn:
        //
        //   - It is NOT proof of a missed release. A version of this code assumed it was, on the
        //     grounds that hardware cannot repeat a down without an up between. Commit d2f47dd
        //     disproves that: a spurious fn-up followed by an fn-down IN THE SAME SECOND, while
        //     the key was held continuously, truncating two dictations mid-clause. The guard
        //     above swallows that up, so the flap's down lands right here. Ending the take on it
        //     re-creates precisely the bug d2f47dd fixed, and
        //     `testPhantomUpIsSwallowedButTheRealReleaseStillEndsTheTake` pins against it. The
        //     hardware read cannot separate the two cases: the key is physically down in both,
        //     still held during a flap and freshly pressed after an outage. (`phantomUpStreak`
        //     plus `modifierPressedAt` could separate them by timing. That was tried and is not
        //     worth it — see the cost asymmetry at the bottom of this comment. The point is that
        //     acting on this event buys little and risks a truncated dictation.)
        //   - The case that reasoning was reaching for, a release lost while the tap was blind,
        //     mostly belongs to `reconcilePressedState`, which asks the HARDWARE whether the key
        //     is still held and so can only ever end a take that is genuinely over. It is called
        //     from the 5-in-10s rebuild, the tap-disable re-enable, and the global-monitor
        //     fallback. It is NOT called from `ensureTapHealthy`'s re-enable or recreate branches,
        //     from `startEventTap`'s retry ladder (up to 55s with no tap), or from `stop()`, and
        //     there is no sleep/wake or fast-user-switch handler at all. The 30s health poll that
        //     would reach the first two is itself gated on `!isPressed`, which is false for the
        //     whole duration of a stranded take. So the coverage is partial, by inspection
        //     (2026-07-26 round-3 review) — do not read it as a guarantee.
        //
        // Worst case if a release is missed and no reconcile path fires, walked in both modes:
        // in HOLD mode the next release is honored normally and the take ends one tap later. In
        // TOGGLE mode it costs TWO taps, and the first one is silent: the down is absorbed here,
        // the up hits `handleKeyUp` which returns early in toggle mode, and only the SECOND down
        // reaches `handleKeyDown` to stop the take. A stuck hardware read stretches that to five
        // taps before the streak cap forces the release through. Bounded either way — a take
        // cannot run indefinitely — and the alternative is a dictation cut off mid-sentence.
        return result()
    }

    /// Policy for the fall-through above, as a pure predicate so it can be pinned by tests.
    static func swallowsRedundantTransition(keyCode: UInt16) -> Bool {
        keyCode == KeyCodes.fnKeyCode
    }

    /// Whether the tap eats an event or lets it reach the OS. Pure, so the emoji-drawer
    /// suppression is actually testable — see the mutation note in `handleCGEvent`.
    enum TapDisposition: Equatable { case consume, passThrough }

    static func tapDisposition(transition: FnTransition,
                               keyCode: UInt16,
                               requiredModifiersSatisfied: Bool) -> TapDisposition {
        switch transition {
        case .keyDown:
            // An unsatisfied required modifier means this press is not the user's hotkey, so it
            // belongs to the OS. Note the asymmetry this creates for a hand-edited
            // `fn + modifiers` config: the down passes through while the matching up is eaten by
            // the `.none` arm below. Not reachable from the picker, which always clears modifiers.
            return requiredModifiersSatisfied ? .consume : .passThrough
        case .keyUp:
            return .consume
        case .none:
            return swallowsRedundantTransition(keyCode: keyCode) ? .consume : .passThrough
        }
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
        // Reaching here after a tap failure means events were unobserved for however long the
        // ten retries took. A release in that window is gone; don't leave a take running.
        reconcilePressedState("tap→global-monitor fallback")
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

    /// Should this key-up be swallowed as a phantom rather than ending the take?
    ///
    /// Pulled out as a pure function (Codex round 2, MAJOR: the guard was untestable inline).
    /// Two conditions, and the second is the one that matters: the streak cap means a run of
    /// swallowed ups always ends, so a wrong hardware read degrades into a late release rather
    /// than a permanent one.
    static func releaseIsPhantom(physicallyDown: Bool, phantomUpStreak: Int) -> Bool {
        physicallyDown && phantomUpStreak < 4
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
    ///
    /// 2026-07-26 (Codex round 1): this path had the SAME fn-only bug as `handleCGEvent`
    /// — it tested `.function` for every hotkey, so whenever tap creation failed and the
    /// app fell back here, all eight sided modifiers were silently dead. Fixed by routing
    /// through the same keycode→device-bit decision. `NSEvent.modifierFlags` carries the
    /// NX device bits in the same layout as `CGEventFlags`.
    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard isModifierOnlyKey(keyCode), event.keyCode == keyCode else { return }
        let fnDown = Self.hotkeyIsDown(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                                       keyCode: keyCode)
        switch Self.fnTransition(fnDown: fnDown, modifierPressed: modifierPressed) {
        case .keyDown:
            // Gate required modifiers only on the down transition (mirrors handleCGEvent); on
            // release the modifiers are already gone.
            if requiredModifiers != 0 {
                let currentMods = UInt64(event.modifierFlags.rawValue) & 0x00FF0000
                guard currentMods & requiredModifiers == requiredModifiers else { return }
            }
            modifierPressed = true
            // Parity with the tap path (Codex round 2, MAJOR). Without these the fallback
            // starts a take but installs no shortcut-abort, so on a Command hotkey the C of
            // Command-C never calls onAbort and the whole shortcut is transcribed as a
            // dictation. The gap already existed for fn; the sided modifiers this change
            // revives would have inherited it.
            modifierPressedAt = mach_absolute_time()
            startKeyDownMonitor()
            onKeyDown?()
        case .keyUp:
            modifierPressed = false
            stopKeyDownMonitor()
            onKeyUp?()
        case .none:
            break
        }
    }

    private func isModifierOnlyKey(_ code: UInt16) -> Bool {
        return [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code)
    }

    /// The flag bit a given modifier keycode raises in its own `flagsChanged` event.
    ///
    /// 2026-07-26 — `handleCGEvent` tested `.maskSecondaryFn` for EVERY modifier
    /// hotkey, so only fn (63) ever worked. Right Command raises `.maskCommand`, never
    /// the fn bit, so the press branch could not fire and selecting it silently did
    /// nothing (Michael: "i set it to right command and it didn't work"). Same for
    /// Option, Shift and Control — 8 of the 9 selectable modifier hotkeys were dead.
    ///
    /// These are the DEVICE-dependent bits, not the aggregate ones, so left and right
    /// are told apart: with left Command already held, a tap of right Command still
    /// shows the aggregate `.maskCommand` on release, and an aggregate test would miss
    /// the key-up entirely and strand a recording.
    static func modifierFlagBit(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 54: return 0x0000_0010          // NX_DEVICERCMDKEYMASK
        case 55: return 0x0000_0008          // NX_DEVICELCMDKEYMASK
        case 56: return 0x0000_0002          // NX_DEVICELSHIFTKEYMASK
        case 60: return 0x0000_0004          // NX_DEVICERSHIFTKEYMASK
        case 58: return 0x0000_0020          // NX_DEVICELALTKEYMASK
        case 61: return 0x0000_0040          // NX_DEVICERALTKEYMASK
        case 59: return 0x0000_0001          // NX_DEVICELCTLKEYMASK
        case 62: return 0x0000_2000          // NX_DEVICERCTLKEYMASK
        case 63: return UInt64(CGEventFlags.maskSecondaryFn.rawValue)   // fn has no sides
        default: return 0                    // unknown keycode owns no bit
        }
    }

    /// The opposite-side keycode for a sided modifier; nil for fn and unknown keys.
    /// Exists so the tests can assert left and right are never conflated.
    static func oppositeSide(of keyCode: UInt16) -> UInt16? {
        switch keyCode {
        case 54: return 55
        case 55: return 54
        case 56: return 60
        case 60: return 56
        case 58: return 61
        case 61: return 58
        case 59: return 62
        case 62: return 59
        default: return nil
        }
    }

    /// True when this hotkey's physical key is down in `flags`.
    ///
    /// Sided modifiers are decided by the DEVICE bit ALONE. There is deliberately no
    /// aggregate-bit fallback (Codex round 1, 2026-07-26, two BLOCKERs): the aggregate
    /// class bit stays set while the OPPOSITE side is held, so trusting it meant a
    /// right-Command release read as "still down" whenever left Command was down —
    /// `modifierPressed` never cleared and the recording could never be stopped. A key
    /// that never starts a take is visible and harmless; a take that never ends is the
    /// worst failure this app has. So this fails SAFE: an aggregate-only event stream
    /// (an exotic remapper) leaves a sided hotkey inert rather than stuck, which is
    /// exactly the pre-fix behavior, not a regression.
    ///
    /// fn (63) is unchanged and keeps the aggregate test: it has no left/right sides,
    /// and that path is the one already proven in production.
    static func hotkeyIsDown(_ flags: CGEventFlags, keyCode: UInt16) -> Bool {
        let bit = modifierFlagBit(for: keyCode)
        guard bit != 0 else { return false }        // unknown keycode owns no key
        return UInt64(flags.rawValue) & bit != 0
    }

    /// True when the hotkey's physical key is really held, per the HID hardware state.
    ///
    /// Used ONLY by the phantom-release guard, which needs hardware truth rather than
    /// what the event claimed. `CGEventSource.flagsState` returns `CGEventFlags`, whose
    /// public contract covers only the device-INDEPENDENT bits, so side-specific device
    /// bits are not guaranteed to be present there. `keyState(_:key:)` is the primitive
    /// that is side-specific by construction, so sided modifiers ask it directly. If it
    /// ever answers false on some keyboard, the guard simply declines to swallow and the
    /// release goes through — fail safe again.
    static func hotkeyIsPhysicallyDown(keyCode: UInt16) -> Bool {
        if keyCode == 63 {
            // Unchanged, proven path: fn is not exposed as a normal key state.
            return CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        }
        guard modifierFlagBit(for: keyCode) != 0 else { return false }
        return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }
}
