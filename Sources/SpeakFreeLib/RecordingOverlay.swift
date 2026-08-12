import AppKit

// MARK: - Pure screen selection

/// Returns the index into `screenFrames` of the screen that best contains `windowFrame`.
///
/// Selection rules (in order):
///  1. The screen whose frame has the largest intersection area with `windowFrame`.
///  2. Returns `nil` when `windowFrame` is nil, `screenFrames` is empty, or no screen
///     overlaps `windowFrame` at all (caller falls back to its preferred default).
///
/// This function is purely geometric — it takes rects, not `NSScreen` objects — so it
/// is fully unit-testable without a display attached or any AppKit side effects.
func bestScreenIndex(windowFrame: NSRect?, screenFrames: [NSRect]) -> Int? {
    guard let frame = windowFrame, !screenFrames.isEmpty else { return nil }
    var bestIndex: Int? = nil
    var bestArea: CGFloat = 0
    for (i, screenFrame) in screenFrames.enumerated() {
        let intersection = frame.intersection(screenFrame)
        if !intersection.isNull {
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = i
            }
        }
    }
    return bestIndex
}

/// Returns the `NSScreen` that best contains `windowFrame`.
///
/// Wraps `bestScreenIndex` with real `NSScreen` objects; falls back to `mainScreen`
/// when no screen overlaps the window.
func overlayScreen(
    windowFrame: NSRect?,
    screens: [NSScreen],
    mainScreen: NSScreen?
) -> NSScreen? {
    let frames = screens.map { $0.frame }
    if let idx = bestScreenIndex(windowFrame: windowFrame, screenFrames: frames) {
        return screens[idx]
    }
    return mainScreen
}

/// Full screen-selection fallback chain used by the overlay, as pure geometry.
///
/// The focused-window AX query (`focusedWindowFrame`) returns nil for a LOT of real
/// apps — Electron with a lazy AX tree, full-screen apps, AX-permission timing — and
/// the old code then fell straight back to the MAIN screen, so on a multi-monitor
/// setup the overlay appeared on the wrong display (or, if main was momentarily nil,
/// not at all). The mouse-cursor screen is a reliable proxy for "where the user is
/// working" and fills that gap.
///
/// Order: (1) screen with most overlap with the focused window → (2) screen under the
/// mouse cursor → (3) main screen → (4) first screen. Returns nil only when there are
/// no screens at all.
func overlayScreenIndex(
    windowFrame: NSRect?,
    mouseLocation: NSPoint,
    screenFrames: [NSRect],
    mainIndex: Int?
) -> Int? {
    if let idx = bestScreenIndex(windowFrame: windowFrame, screenFrames: screenFrames) {
        return idx
    }
    for (i, frame) in screenFrames.enumerated() where frame.contains(mouseLocation) {
        return i
    }
    if let mainIndex = mainIndex, screenFrames.indices.contains(mainIndex) {
        return mainIndex
    }
    return screenFrames.isEmpty ? nil : 0
}

// MARK: - AX focused-window frame helper

/// Returns the screen-coordinate frame of the frontmost application's focused window
/// using the Accessibility API, without blocking if the app is non-AX.
///
/// Returns `nil` when:
///  - The frontmost application PID cannot be determined.
///  - AX permission is not granted (or the target app rejects AX).
///  - The focused element's position/size attributes are unavailable.
///
/// This is intentionally a free function (no class coupling) so it can be replaced
/// with an injection seam in tests if needed.
func focusedWindowFrame() -> NSRect? {
    guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
        return nil
    }
    let appElement = AXUIElementCreateApplication(frontPID)
    var focusedWindowValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
          let windowElement = focusedWindowValue else {
        return nil
    }
    // CF bridging — the type is checked by the AX attribute contract.
    // swiftlint:disable:next force_cast
    let axWindow = windowElement as! AXUIElement

    var posValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    // AXValue wraps CGPoint / CGSize — extract via AXValueGetValue
    if let posAX = posValue, CFGetTypeID(posAX) == AXValueGetTypeID() {
        AXValueGetValue(posAX as! AXValue, .cgPoint, &position)
    } else {
        return nil
    }
    if let sizeAX = sizeValue, CFGetTypeID(sizeAX) == AXValueGetTypeID() {
        AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
    } else {
        return nil
    }
    // AX reports the window in global display coordinates whose origin is the
    // TOP-LEFT of the PRIMARY display (Y increases downward); NSScreen uses a
    // bottom-left origin (Y increases upward). The vertical flip pivots on the
    // PRIMARY screen's height — NOT the union/max edge across all screens. Using
    // `max(maxY)` put the window on the wrong display whenever a secondary monitor
    // was taller or positioned higher than the primary, which is why the overlay
    // appeared on the wrong screen in multi-monitor setups (2026-06-22).
    let primaryHeight = NSScreen.screens.first?.frame.height ?? size.height
    return axToCocoaFrame(axPosition: position, axSize: size, primaryHeight: primaryHeight)
}

/// Convert an Accessibility window rect (top-left origin, primary-display relative)
/// to a Cocoa screen rect (bottom-left origin). Pure + testable: the vertical flip
/// pivots on `primaryHeight` (the menu-bar screen's height), so it stays correct
/// across multi-monitor arrangements regardless of where secondary displays sit.
func axToCocoaFrame(axPosition: CGPoint, axSize: CGSize, primaryHeight: CGFloat) -> NSRect {
    let cocoaY = primaryHeight - axPosition.y - axSize.height
    return NSRect(origin: CGPoint(x: axPosition.x, y: cocoaY), size: axSize)
}

// MARK: - RecordingOverlay

class RecordingOverlay {
    private var window: NSWindow?
    private var animationTimer: Timer?
    private var contentView: OverlayContentView?
    private weak var recorder: AudioRecorder?

    /// Visual variant for the prominent banner (config overlayStyle 1-5).
    var style: Int = 1
    // Seam for unit tests: override to inject a known window frame without real AX.
    var windowFrameProvider: (() -> NSRect?)? = nil
    // Seam for unit tests: override to inject a known cursor location.
    var mouseLocationProvider: () -> NSPoint = { NSEvent.mouseLocation }

    private func activeWindowFrame() -> NSRect? {
        if let provider = windowFrameProvider { return provider() }
        return focusedWindowFrame()
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let mainIndex = NSScreen.main.flatMap { main in screens.firstIndex(where: { $0 === main }) }
        let idx = overlayScreenIndex(
            windowFrame: activeWindowFrame(),
            mouseLocation: mouseLocationProvider(),
            screenFrames: screens.map { $0.frame },
            mainIndex: mainIndex
        )
        return idx.map { screens[$0] }
    }

    // R2: resolve the overlay's screen ONCE per recording (in show()) and reuse it for
    // update()/updateStreamingText(), so the AX IPC inside focusedWindowFrame() runs once
    // per dictation instead of at every state change (previously a second round-trip at
    // update(.transcribing), plus one per streaming partial). Reset per recording in
    // show() and cleared in hide(), so a multi-display move BETWEEN dictations still
    // re-resolves onto the newly-active screen.
    private var cachedScreen: NSScreen?
    private var screenResolved = false
    /// Bumped on every show()/hide(); stale banner timers check it before acting.
    private var showGeneration: UInt64 = 0

    private func resolvedTargetScreen() -> NSScreen? {
        if screenResolved { return cachedScreen }
        cachedScreen = targetScreen()
        screenResolved = true
        return cachedScreen
    }

    /// INSTANT screen pick for show(): mouse-cursor screen → main — no AX IPC.
    /// The precise focused-window resolution (an IPC to the frontmost app that
    /// can take up to 0.5s when it's cold) happens ASYNC right after; if it picks
    /// a different display the window is repositioned within ~100ms — far better
    /// than making every record-start pay the IPC before anything appears
    /// (2026-07-25: "the fade feels a little slow or stuttery").
    private func instantScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let mouse = mouseLocationProvider()
        if let underMouse = screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.main ?? screens[0]
    }

    /// Kick the AX-precise resolution off-main; reposition if it disagrees.
    private func refineScreenAsync(for expectedGeneration: UInt64) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let frame = self?.activeWindowFrame()
            DispatchQueue.main.async {
                guard let self = self, self.showGeneration == expectedGeneration,
                      let win = self.window else { return }
                let screens = NSScreen.screens
                guard !screens.isEmpty else { return }
                let mainIndex = NSScreen.main.flatMap { main in
                    screens.firstIndex(where: { $0 === main }) }
                guard let idx = overlayScreenIndex(
                    windowFrame: frame,
                    mouseLocation: self.mouseLocationProvider(),
                    screenFrames: screens.map { $0.frame },
                    mainIndex: mainIndex) else { return }
                let resolved = screens[idx]
                if resolved !== self.cachedScreen {
                    self.cachedScreen = resolved
                    let size = win.frame.size
                    win.setFrame(NSRect(x: resolved.frame.midX - size.width / 2,
                                        y: resolved.frame.midY - size.height / 2,
                                        width: size.width, height: size.height),
                                 display: true)
                }
            }
        }
    }

    func show(state: OverlayState, recorder: AudioRecorder? = nil, autoHideError: Bool = true) {
        // Hard kill any existing window (no animation)
        showGeneration &+= 1
        animationTimer?.invalidate()
        animationTimer = nil
        window?.orderOut(nil)
        window = nil
        contentView = nil
        self.recorder = recorder

        // Instant screen pick (no AX IPC on the show path); precise resolution
        // refines async and repositions in the rare multi-display disagreement.
        screenResolved = true
        cachedScreen = instantScreen()
        guard let screen = cachedScreen else { screenResolved = false; return }
        refineScreenAsync(for: showGeneration)

        // Record-start and errors open as a LARGE CENTER-SCREEN banner (Michael
        // 2026-07-25): unmissable positive feedback, so NOT seeing it after a keypress
        // reliably means the press didn't land (dead tap / dead app / refused start).
        // Recording glides down to the familiar bottom pill after a beat; errors
        // auto-hide in place.
        let isError = { if case .error = state { return true }; return false }()
        let prominent = state == .recording || isError
        // Michael's locked entry (2026-08-12) opens as a bare record mark on a fully
        // transparent window, so it needs a canvas big enough for the widest ring
        // pulse — clipping one into a corner arc is the exact artifact the lab was
        // built to avoid.
        let emergence = prominent && !isError
            && OverlayContentView.usesEmergenceEntry(style: style)
        let pillSize: NSSize
        let frame: NSRect
        let bottomMargin: CGFloat = 48
        if prominent {
            if isError {
                pillSize = OverlayContentView.errorSize
            } else if emergence {
                pillSize = OverlayContentView.emergenceSize
            } else {
                pillSize = OverlayContentView.prominentSize
            }
            frame = NSRect(x: screen.frame.midX - pillSize.width / 2,
                           y: screen.frame.midY - pillSize.height / 2,
                           width: pillSize.width, height: pillSize.height)
        } else {
            pillSize = OverlayContentView.pillSize(for: state)
            frame = NSRect(x: screen.frame.midX - pillSize.width / 2,
                           y: screen.visibleFrame.origin.y + bottomMargin,
                           width: pillSize.width, height: pillSize.height)
        }

        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        // AppKit derives the shadow from the window's alpha channel and caches it.
        // The emergence entry's content goes from a 9pt dot to a 150pt card, so a
        // cached shadow reads as a grey ghost rectangle around empty space. The
        // locked design was judged without a drop shadow; keep it that way and put
        // the shadow back when the overlay becomes an ordinary pill again.
        win.hasShadow = !emergence
        win.ignoresMouseEvents = true
        // .fullScreenAuxiliary: without it the overlay is invisible over full-screen
        // apps (2026-07-25 UX audit #11) — exactly where a user can't see the menu bar.
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = OverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        view.overlayState = state
        view.prominent = prominent && !isError
        view.style = style
        view.recordingStartedAt = Date()
        win.contentView = view

        // Start fully transparent for fade-in
        win.alphaValue = 0
        view.borderWidth = 0

        win.orderFrontRegardless()
        window = win
        contentView = view

        startAnimation()

        // Snappy entrance (2026-07-25): 80ms fade — the 200ms fade + 100ms border
        // delay read as sluggishness at the moment that most needs to feel instant.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            win.animator().alphaValue = 1.0
        }
        view.borderWidth = 1.0

        if isError {
            // Error banner: hold, then fade out — UNLESS the caller needs it to persist
            // (review #3: the mid-recording dead-audio warning must stay up for as long
            // as the mic is dead; auto-hiding it left the user dictating into a dead
            // mic with no indicator at all, the exact failure the watchdog exists for).
            if autoHideError {
                let generation = showGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self = self, self.showGeneration == generation else { return }
                    // codex review #6: update() reuses the window without bumping the
                    // generation — if the state moved on (e.g. .transcribing after the
                    // user released), this stale timer must not hide it.
                    if case .error = self.contentView?.overlayState { self.hide() }
                }
            }
        }
        // (No glide-to-pill: Michael 2026-07-25 — the banner stays large and centered
        // for the whole recording; the movement was distracting.)
    }

    func update(state: OverlayState) {
        guard let view = contentView, let win = window, let screen = resolvedTargetScreen() else {
            show(state: state)
            return
        }
        view.overlayState = state
        // Leaving the recording phase drops the emergence canvas for an ordinary
        // pill, which wants its shadow back (see show()).
        if state != .recording { win.hasShadow = true }

        let pillSize = OverlayContentView.pillSize(for: state, streamingText: view.streamingText)
        let bottomMargin: CGFloat = 48
        let x = screen.frame.midX - pillSize.width / 2
        let y = screen.visibleFrame.origin.y + bottomMargin
        win.setFrame(NSRect(x: x, y: y, width: pillSize.width, height: pillSize.height), display: false)
        view.frame = NSRect(origin: .zero, size: pillSize)
        view.needsDisplay = true
    }

    /// Update the overlay with streaming transcription text.
    /// Called from the main thread during recording as partial results arrive.
    func updateStreamingText(_ text: String) {
        guard let view = contentView, let win = window, let screen = resolvedTargetScreen() else { return }

        // Only grow the text, never shrink — prevents flickering from re-processing
        if text.count < view.streamingText.count { return }

        let oldText = view.streamingText
        view.streamingText = text

        // Resize the pill if text content changed
        let newSize = OverlayContentView.pillSize(for: view.overlayState, streamingText: text)
        let oldSize = OverlayContentView.pillSize(for: view.overlayState, streamingText: oldText)
        if newSize != oldSize {
            let x = screen.frame.midX - newSize.width / 2
            let y: CGFloat
            if text.isEmpty {
                // Compact pill at the bottom
                y = screen.visibleFrame.origin.y + 48
            } else {
                // Expanded pill centered on screen
                y = screen.frame.midY - newSize.height / 2
            }

            // Animate the size change smoothly
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrame(NSRect(x: x, y: y, width: newSize.width, height: newSize.height), display: true)
            }
            view.frame = NSRect(origin: .zero, size: newSize)
        }

        view.needsDisplay = true
    }

    /// Clear streaming text (called when recording stops).
    func clearStreamingText() {
        contentView?.streamingText = ""
        contentView?.needsDisplay = true
    }

    /// Compact size for the settled steady state (same center as the banner).
    static let settledSize = NSSize(width: 240, height: 56)

    /// ~2.4s after the explosion completes, compact the banner IN PLACE (same
    /// center, no travel — the shrink-and-move was rejected as distracting; an
    /// in-place decay was the reviewers' livability centerpiece).
    private func scheduleSettle() {
        // The emergence entry has no settle phase: its end state IS the shipped
        // purple pill at 1.2×, which stays put and keeps tracking speech (Michael:
        // "once the lines are created I want it to go back to what it was").
        guard !OverlayContentView.usesEmergenceEntry(style: style) else { return }
        let generation = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self = self, self.showGeneration == generation,
                  let win = self.window, let view = self.contentView,
                  view.overlayState == .recording, view.settleProgress < 1 else { return }
            view.settleProgress = 1
            let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
            let size = Self.settledSize
            let target = NSRect(x: center.x - size.width / 2,
                                y: center.y - size.height / 2,
                                width: size.width, height: size.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                win.animator().setFrame(target, display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                guard self.showGeneration == generation else { return }
                view.frame = NSRect(origin: .zero, size: target.size)
                view.needsDisplay = true
            }
        }
    }

    func hide() {
        // Invalidate any pending banner glide/auto-hide timers from the current show().
        showGeneration &+= 1
        // Drop the cached screen so the next recording re-resolves (display may have
        // changed while the overlay was hidden).
        screenResolved = false
        cachedScreen = nil
        guard let win = window, let view = contentView else { return }

        // Immediately detach references so show() won't see a stale window
        let animTimer = animationTimer
        animationTimer = nil
        window = nil
        contentView = nil
        recorder = nil

        // Hide bars, spinner, and border
        view.hideContents = true
        view.borderWidth = 0

        let originalFrame = win.frame

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
            let shrinkW: CGFloat = 15
            let shrinkH: CGFloat = 4
            let drop: CGFloat = 3
            let newFrame = NSRect(
                x: originalFrame.origin.x + shrinkW,
                y: originalFrame.origin.y - drop,
                width: originalFrame.width - shrinkW * 2,
                height: originalFrame.height - shrinkH * 2
            )
            win.animator().setFrame(newFrame, display: true)
        }, completionHandler: {
            animTimer?.invalidate()
            win.orderOut(nil)
        })
    }

    /// Frames elapsed since show(); only used to sub-sample the 60Hz emergence
    /// timer back down to the shipped 30Hz waveform cadence.
    private var frameCount: UInt64 = 0

    private func startAnimation() {
        // The emergence entry redraws at 60Hz — three ring pulses crossing 61pt in
        // 520ms is visibly steppy at 30. The waveform state machine still advances
        // at 30Hz (its smoothing, jitter period and travel cadence are tuned for
        // that rate, and "exactly as shipped" is the requirement for the steady
        // state), so the extra frames are pure redraw.
        let emergence = OverlayContentView.usesEmergenceEntry(style: style)
        let hz: Double = emergence ? 60.0 : 30.0
        let stateEvery: UInt64 = emergence ? 2 : 1
        frameCount = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            guard let self = self, let view = self.contentView else { return }
            self.frameCount &+= 1
            if self.frameCount % stateEvery == 0 {
                view.tick += 1
                if let recorder = self.recorder {
                    let raw = CGFloat(recorder.currentLevel)
                    // Noise gate: suppress ambient noise, rescale speech range
                    let gated = max(raw - 0.08, 0) / 0.92
                    view.audioLevel = min(pow(gated, 0.5) * 1.4, 1.0)
                    // First real speech triggers the record-icon -> waveform explosion
                    // (Michael 2026-07-25). Gate well above room tone so breath alone
                    // doesn't trigger it.
                    if !view.heardSpeech && view.audioLevel > 0.25 {
                        view.heardSpeech = true
                        view.speechStartedAt = Date()
                    }
                }
                // The per-bar waveform state used to advance inside drawBars, which
                // meant it never advanced at all while the prominent banner was up
                // (that path draws through drawBannerBars) — the banner's bars sat
                // frozen at zero for the whole recording. Advancing it here, once per
                // state tick, is what makes the banner and the emergence end state
                // genuinely speech-reactive.
                view.advanceLevels()
            }
            if view.heardSpeech && view.explodeProgress < 1 {
                if emergence {
                    // Wall-clock, not per-tick increments: the locked 520ms has to be
                    // 520ms whatever the frame rate does.
                    let started = view.speechStartedAt ?? Date()
                    let elapsed = -started.timeIntervalSinceNow
                    view.explodeProgress = min(1, CGFloat(elapsed / OverlayEmergence.emergeDuration))
                } else {
                    view.explodeProgress = min(1, view.explodeProgress + 0.09)
                    if view.explodeProgress >= 1 {
                        self.scheduleSettle()
                    }
                }
            }
            view.needsDisplay = true
        }
    }

    enum OverlayState: Equatable {
        case recording
        case transcribing
        /// Loud failure banner (red, center-screen, auto-hides): recording failed to
        /// start, or audio died mid-recording. Message is short and user-facing.
        case error(String)
    }
}

class OverlayContentView: NSView {
    var overlayState: RecordingOverlay.OverlayState = .recording
    /// Center-screen banner phase: big title + large bars for the first ~1.1s.
    var prominent = false
    /// Explosion sequence (Michael 2026-07-25): the banner opens with a record icon
    /// only; the FIRST real speech "explodes" it into the live waveform. These are
    /// driven from the 30fps animation tick.
    var heardSpeech = false
    var explodeProgress: CGFloat = 0
    /// Wall-clock instant the first real speech landed. The locked emergence
    /// (2026-08-12) runs on real time, not on a per-tick increment, so its 520ms
    /// stays 520ms regardless of frame rate.
    var speechStartedAt: Date?
    /// In-place decay to the compact steady state (0 = full banner, 1 = compact).
    var settleProgress: CGFloat = 0
    var recordingStartedAt = Date()
    /// Render-harness override for the elapsed timer (deterministic stills). Also
    /// pins the idle ring's phase, so emergence stills are reproducible.
    var renderElapsedOverride: TimeInterval?
    /// Visual variant (config `overlayStyle` 1–5); drawing dispatches on it.
    var style: Int = 1

    /// Which variant gets Michael's locked record-icon entry (2026-08-12).
    ///
    /// Style 5 is what an unset `overlayStyle` resolves to (`AppDelegate` clamps
    /// `config.overlayStyle ?? 5` into 1…5), so it is the one he actually sees.
    /// The old style-5 comet is preserved below as an unreachable `case 6`.
    static func usesEmergenceEntry(style: Int) -> Bool { style == 5 }
    var audioLevel: CGFloat = 0
    var tick: Int = 0
    @objc dynamic var borderWidth: CGFloat = 0
    var hideContents = false
    var streamingText: String = ""

    // Layout constants — visualization is 2x the original size
    private static let barCount = 16
    private static let dotSize: CGFloat = 2.0
    private static let barGap: CGFloat = 3
    private static let hPadding: CGFloat = 24
    private static let vPadding: CGFloat = 18
    private static let maxBarHeight: CGFloat = 20
    private static let spinnerSize: CGFloat = 22
    private static let spinnerLeftPad: CGFloat = 12   // gap between bars and spinner
    private static let spinnerRightPad: CGFloat = 16  // right edge padding
    private static let spinnerSpace: CGFloat = spinnerLeftPad + spinnerSize + spinnerRightPad - hPadding

    // Fixed corner radius — does NOT scale with pill height
    private static let cornerRadius: CGFloat = 20

    private var smoothLevel: CGFloat = 0
    private var displayLevels: [CGFloat] = Array(repeating: 0, count: barCount)
    // Per-bar jitter targets that change periodically, not every frame
    private var jitterTargets: [CGFloat] = Array(repeating: 0, count: barCount)
    private var jitterCurrent: [CGFloat] = Array(repeating: 0, count: barCount)
    // Traveling boost that cascades left to right
    private var travelBoost: [CGFloat] = Array(repeating: 0, count: barCount)
    private var travelTimer: Int = 0
    private var travelCooldown: Int = 0

    // Streaming text layout constants
    private static let streamingTextMaxWidth: CGFloat = 400
    private static let streamingTextTopPad: CGFloat = 2
    private static let streamingTextBottomPad: CGFloat = 12
    private static let streamingTextFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let maxVisibleLines = 6
    private static let lineHeightEstimate: CGFloat = 18 // ~13pt font with leading

    // Compressed bars layout when text is showing
    private static let compressedDotSize: CGFloat = 1.5
    private static let compressedBarGap: CGFloat = 2.0
    private static let compressedMaxBarHeight: CGFloat = 10
    private static let compressedBarsAreaHeight: CGFloat = 24

    /// Large center-screen banner shown for the first moments of every recording
    /// (Michael 2026-07-25: record-start must be UNMISSABLE — its absence after a
    /// keypress is the only reliable signal for a dead tap or dead app).
    static let prominentSize = NSSize(width: 340, height: 110)
    static let errorSize = NSSize(width: 400, height: 96)

    /// Canvas for the locked record-icon entry. Fully transparent until the purple
    /// bloom opens; sized so the outermost ring pulse (radius 74.5pt at the locked
    /// dials) never touches an edge — a clipped pulse reads as a stray corner arc.
    static let emergenceSize: NSSize = {
        let g = OverlayEmergence.geometry(centerX: 0, centerY: 0)
        let span = ceil(OverlayEmergence.maxInkRadius(geometry: g) * 2) + 20
        return NSSize(width: max(340, span), height: span)
    }()

    static func pillSize(for state: RecordingOverlay.OverlayState, streamingText: String = "") -> NSSize {
        if case .error = state { return errorSize }
        let barsWidth = CGFloat(barCount) * dotSize + CGFloat(barCount - 1) * barGap
        let baseWidth = hPadding * 2 + barsWidth
        let baseHeight = vPadding * 2 + dotSize

        if streamingText.isEmpty || state == .transcribing {
            return NSSize(width: baseWidth, height: baseHeight)
        }

        // Wider pill to accommodate text
        let textWidth = max(baseWidth, streamingTextMaxWidth + hPadding * 2)

        // Calculate text height, capped at ~6 lines
        let textHeight = streamingTextHeight(for: streamingText, maxWidth: streamingTextMaxWidth)
        let maxTextHeight = lineHeightEstimate * CGFloat(maxVisibleLines)
        let clampedTextHeight = min(textHeight, maxTextHeight)

        let totalHeight = compressedBarsAreaHeight + streamingTextTopPad + clampedTextHeight + streamingTextBottomPad
        return NSSize(width: textWidth, height: totalHeight)
    }

    private static func streamingTextHeight(for text: String, maxWidth: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: streamingTextFont,
            .paragraphStyle: paraStyle,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let boundingRect = attrStr.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(boundingRect.height)
    }

    /// Returns just the last N lines of text that fit in the visible area.
    private static func visibleTailText(from text: String, maxWidth: CGFloat) -> String {
        let maxHeight = lineHeightEstimate * CGFloat(maxVisibleLines)
        let fullHeight = streamingTextHeight(for: text, maxWidth: maxWidth)
        if fullHeight <= maxHeight { return text }

        // Text exceeds visible area — find lines from the end that fit
        // Split by newlines (we insert \n for sentence breaks)
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        for line in lines.reversed() {
            let candidate = ([line] + result).joined(separator: "\n")
            let h = streamingTextHeight(for: candidate, maxWidth: maxWidth)
            if h > maxHeight && !result.isEmpty { break }
            result.insert(line, at: 0)
        }
        return result.joined(separator: "\n")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let rect = bounds
        let pillPath = CGPath(roundedRect: rect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)

        // Error banner: red gradient, warning glyph, message. Center-screen, loud.
        if case .error(let message) = overlayState {
            ctx.saveGState()
            ctx.addPath(pillPath)
            ctx.clip()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                NSColor(red: 0.45, green: 0.05, blue: 0.08, alpha: 0.92).cgColor,
                NSColor(red: 0.65, green: 0.10, blue: 0.12, alpha: 0.92).cgColor,
            ] as CFArray
            if let g = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(g,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
            }
            ctx.restoreGState()

            let title = NSAttributedString(string: "⚠️ \(message)", attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let size = title.boundingRect(
                with: NSSize(width: rect.width - 40, height: rect.height),
                options: [.usesLineFragmentOrigin]).size
            title.draw(in: NSRect(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
            return
        }

        // Prominent record-start banner (stays for the whole recording — no glide).
        // Opens as a record ICON; the first real speech explodes it into the live
        // waveform. Five visual variants dispatched on `style` (config overlayStyle),
        // built 2026-07-25 for adversarial design review. All are near-opaque
        // (Michael: "less transparency, like 1/3 of the transparency").
        if prominent && overlayState == .recording {
            drawProminentBanner(ctx: ctx, rect: rect, pillPath: pillPath)
            return
        }

        // Purple gradient background for recording and transcribing states
        if overlayState == .recording || overlayState == .transcribing {
            ctx.saveGState()
            ctx.addPath(pillPath)
            ctx.clip()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradientColors = [
                NSColor(red: 0.25, green: 0.05, blue: 0.35, alpha: 0.6).cgColor,
                NSColor(red: 0.40, green: 0.10, blue: 0.55, alpha: 0.6).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(gradient,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: [])
            }
            ctx.restoreGState()
        } else {
            ctx.addPath(pillPath)
            ctx.setFillColor(NSColor(white: 0.08, alpha: 0.92).cgColor)
            ctx.fillPath()
        }

        if hideContents { return }

        // Border
        if borderWidth > 0 {
            let inset = borderWidth / 2
            let borderRect = rect.insetBy(dx: inset, dy: inset)
            let borderPath = CGPath(roundedRect: borderRect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
            ctx.addPath(borderPath)
            ctx.setStrokeColor(NSColor(red: 0.5, green: 0.15, blue: 0.7, alpha: 0.8).cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.strokePath()
        }

        let isTranscribing = overlayState == .transcribing
        let hasText = !streamingText.isEmpty && !isTranscribing

        if isTranscribing {
            // No bars during transcribing — only centered spinner
            drawSpinner(ctx: ctx, rect: rect)
        } else if hasText {
            // Bars compressed to top of the expanded pill
            let barsRect = NSRect(
                x: rect.minX,
                y: rect.maxY - Self.compressedBarsAreaHeight,
                width: rect.width,
                height: Self.compressedBarsAreaHeight
            )
            drawBars(ctx: ctx, rect: barsRect, color: NSColor.white.withAlphaComponent(0.75), compressed: true)

            // Streaming text below bars
            drawStreamingText(ctx: ctx, rect: rect)
        } else {
            // Normal centered bars, no text
            drawBars(ctx: ctx, rect: rect, color: NSColor.white.withAlphaComponent(0.75), compressed: false)
        }
    }

    // MARK: - Prominent banner variants (2026-07-25)

    private func cardGradient(_ ctx: CGContext, _ rect: NSRect, _ path: CGPath,
                              from c1: NSColor, to c2: NSColor) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [c1.cgColor, c2.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(g,
                start: CGPoint(x: rect.minX, y: rect.midY),
                end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
        }
        ctx.restoreGState()
    }

    private func pulse(_ base: CGFloat) -> CGFloat {
        base * (1 + 0.06 * sin(CGFloat(tick) * 0.12))
    }

    private func drawTitle(_ text: String, in rect: NSRect, y: CGFloat, size: CGFloat, dot: Bool) {
        let title = NSMutableAttributedString()
        if dot {
            title.append(NSAttributedString(string: "\u{25CF} ", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0),
            ]))
        }
        title.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
        ]))
        let tSize = title.size()
        title.draw(at: NSPoint(x: rect.midX - tSize.width / 2, y: y))
    }

    private func drawRecordCircle(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                                  alpha: CGFloat) {
        ctx.setFillColor(NSColor(red: 0.95, green: 0.23, blue: 0.25, alpha: alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
    }

    /// Banner-scale live bars (round-1 adversarial synthesis, 2026-07-25):
    ///   * 12 narrow bars (17 read as an equalizer icon; narrow bars read as data)
    ///   * spatial smoothing so neighbors correlate like real speech energy
    ///   * amplitude floor: near-silence collapses bars to DOTS, so pauses look calm
    ///     and speech visibly meters (the palindromic full-height sawtooth was the
    ///     set's strongest clip-art tell)
    ///   * during the explosion, bars EMERGE from the center as the energy front
    ///     reaches them — outer bars stay collapsed until progress passes them —
    ///     and are born red, cooling to the settle color as they rise (continuity
    ///     with the record icon's mass; previously the finished waveform crossfaded
    ///     in and nothing "exploded")
    private static let bannerBarCount = 12

    private func bannerLevels() -> [CGFloat] {
        let n = Self.bannerBarCount
        var raw = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            raw[i] = displayLevels[(i * Self.barCount) / n]
        }
        // Two smoothing passes (R2 craft: one pass landed at the 12th percentile of
        // plausible neighbor correlation — speech energy is smoother than that).
        for _ in 0..<2 {
            var out = raw
            for i in 1..<(n - 1) {
                out[i] = raw[i] * 0.55 + (raw[i - 1] + raw[i + 1]) * 0.225
            }
            raw = out
        }
        return raw
    }

    /// R2-fixed banner bars:
    ///  * fully opaque fill (translucent bars over the fading disc created the
    ///    off-palette pink/maroon blends of round 2)
    ///  * `origin` = relative x (0..1) the explosion radiates from — 0.5 for the
    ///    centered styles, the badge dock for style 5's left cascade
    ///  * bars GROW as they are revealed (round 2: inner bars were at ~100% height
    ///    at p=0.5 — a mask wipe, not an emergence)
    ///  * heat anchored at the ORIGIN: bars nearest the red mass are born reddest,
    ///    everything cools to the settle color as emergence completes
    ///  * floor: minimum height == bar width, so silence renders as round DOTS
    private func drawBannerBars(ctx: CGContext, rect: NSRect, emergence: CGFloat,
                                settleColor: NSColor, origin: CGFloat = 0.5,
                                span: CGFloat = 0.72, badgeNorm: CGFloat? = nil) {
        let n = Self.bannerBarCount
        let levels = bannerLevels()
        let gap: CGFloat = rect.width * 0.030
        let barW = (rect.width * span - gap * CGFloat(n - 1)) / CGFloat(n)
        let startX = rect.midX - (barW * CGFloat(n) + gap * CGFloat(n - 1)) / 2
        let maxH = rect.height
        let red = Self.bannerRed
        for i in 0..<n {
            let xNorm = CGFloat(i) / CGFloat(n - 1)
            let front: CGFloat
            let redness: CGFloat
            if let badge = badgeNorm {
                // Comet mode (style 5, R3 codex fix): bars exist only BEHIND the
                // traveling badge (to its right), shed as it passes — heat clings
                // to the badge's trailing edge and cools with distance and time.
                front = max(0, min(1, (xNorm - badge) / 0.10)) * (0.35 + 0.65 * emergence)
                redness = max(0, 1 - (xNorm - badge) * 3) * (1 - emergence * 0.7)
            } else {
                let dist = min(1, abs(xNorm - origin) / max(origin, 1 - origin))
                front = max(0, min(1, (emergence * 1.25 - dist) / 0.25))
                redness = (1 - dist) * (1 - emergence)
            }
            guard front > 0 else { continue }
            let grow = front * (0.55 + 0.45 * emergence)
            let h = max(barW, maxH * levels[i] * grow)
            let color = settleColor.blended(withFraction: redness, of: red) ?? settleColor
            ctx.setFillColor(color.cgColor)
            let x = startX + CGFloat(i) * (barW + gap)
            let bar = CGRect(x: x, y: rect.midY - h / 2, width: barW, height: h)
            let path = CGPath(roundedRect: bar, cornerWidth: barW / 2,
                              cornerHeight: barW / 2, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    // Round-1 fixes baked in (2026-07-25, four-lens adversarial review):
    //  * bars EMERGE center-out, born red, cooling to white (X1/X3)
    //  * expanding shapes are clipped to the zone BELOW the title — nothing ever
    //    strikes through the label (X5) and nothing clips the card edge
    //  * icon and bars share one vertical axis (no inter-phase jump)
    //  * one red family (#ED2231); no naive sRGB morphs through mud
    //  * S3's linear stretch (read as strikethrough) replaced with a radial burst
    //  * S4's duplicate indicators removed; S5 gets a container + conserves its red
    //    mass into the persistent dot
    //  * SETTLED phase: after the explosion the card compacts IN PLACE to a calm
    //    timer + dot + small bars (livability: the 28pt title is a 30-min nag)
    private static let bannerRed = NSColor(red: 0.93, green: 0.13, blue: 0.19, alpha: 1.0)

    /// Card fill per style — one source of truth so the settled card inherits its
    /// style's material instead of swapping to a foreign flat fill (R2 N4/N6).
    /// Opacity 0.97: at 0.90, document text read straight through the card — "too
    /// opaque to be glass, too transparent to be clean" (R2 livability #1 finding).
    private func cardColors() -> (from: NSColor, to: NSColor) {
        switch style {
        case 2: return (NSColor(red: 0.16, green: 0.04, blue: 0.24, alpha: 0.97),
                        NSColor(red: 0.30, green: 0.08, blue: 0.42, alpha: 0.97))
        case 3: return (NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.97),
                        NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.97))
        case 4: return (NSColor(red: 0.22, green: 0.07, blue: 0.34, alpha: 0.97),
                        NSColor(red: 0.34, green: 0.11, blue: 0.48, alpha: 0.97))
        case 5: return (NSColor(red: 0.15, green: 0.03, blue: 0.24, alpha: 0.97),
                        NSColor(red: 0.15, green: 0.03, blue: 0.24, alpha: 0.97))
        default: return (NSColor(red: 0.20, green: 0.05, blue: 0.30, alpha: 0.97),
                         NSColor(red: 0.33, green: 0.09, blue: 0.46, alpha: 0.97))
        }
    }

    private func titleZoneHeight(_ rect: NSRect) -> CGFloat { rect.height * 0.28 }

    private func bodyRect(_ rect: NSRect) -> NSRect {
        // 4pt symmetric breathing room top and bottom of the band (R2: expanding
        // circles were sheared flat against the card's bottom edge).
        NSRect(x: rect.minX, y: rect.minY + 4,
               width: rect.width, height: rect.height - titleZoneHeight(rect) - 8)
    }

    private func drawBannerTitle(_ rect: NSRect, text: String = "Recording") {
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ])
        let tSize = title.size()
        title.draw(at: NSPoint(x: rect.midX - tSize.width / 2,
                               y: rect.maxY - titleZoneHeight(rect) / 2 - tSize.height / 2))
    }

    private func drawProminentBanner(ctx: CGContext, rect: NSRect, pillPath: CGPath) {
        if Self.usesEmergenceEntry(style: style) {
            drawEmergenceEntry(ctx: ctx, rect: rect)
            return
        }
        if settleProgress >= 1 {
            drawSettledCard(ctx: ctx, rect: rect, pillPath: pillPath)
            return
        }
        let p = explodeProgress
        let body = bodyRect(rect)
        let axis = CGPoint(x: body.midX, y: body.midY)
        let barsRect = NSRect(x: body.minX, y: axis.y - body.height * 0.30,
                              width: body.width, height: body.height * 0.60)
        let colors = cardColors()
        cardGradient(ctx, rect, pillPath, from: colors.from, to: colors.to)
        // Ring/disc growth is capped INSIDE the band (R2: rings that outgrew the
        // card survived only as clipped corner arcs — an accidental "( )" glyph).
        let maxR = body.height * 0.48

        func clippedToBody(_ draw: () -> Void) {
            ctx.saveGState()
            ctx.addPath(pillPath)
            ctx.clip()
            ctx.clip(to: body)
            draw()
            ctx.restoreGState()
        }

        switch style {
        case 2: // Ring Burst — front radius COUPLED to the bar emergence
            drawBannerTitle(rect)
            clippedToBody {
                if p < 1 {
                    let ringR = min(maxR, pulse(26) + p * maxR)
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent((1 - p) * 0.9).cgColor)
                    ctx.setLineWidth(4)
                    ctx.strokeEllipse(in: CGRect(x: axis.x - ringR, y: axis.y - ringR,
                                                 width: ringR * 2, height: ringR * 2))
                    if p < 0.5 {
                        drawRecordCircle(ctx, center: axis, radius: 15 * (1 - p * 2), alpha: 1 - p * 2)
                    }
                }
            }
            if heardSpeech {
                drawBannerBars(ctx: ctx, rect: barsRect, emergence: p, settleColor: .white)
            }

        case 3: // Minimal — radial burst with fast falloff (no maroon slab)
            let tag = NSAttributedString(string: "speakfree", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                // 4.8:1 on the black card (R2: 3.31:1 read as an accidental watermark)
                .foregroundColor: NSColor(white: 0.56, alpha: 1.0),
            ])
            tag.draw(at: NSPoint(x: rect.maxX - tag.size().width - 14, y: rect.minY + 9))
            let c = CGPoint(x: rect.midX, y: rect.midY)
            if p < 1 {
                // (1-p)^2: the disc must be GONE before the bars own the frame —
                // a half-faded disc behind bars was round 2's "planet/grille" read.
                drawRecordCircle(ctx, center: c, radius: pulse(13) * (1 + p * 2.4),
                                 alpha: (1 - p) * (1 - p))
            }
            if heardSpeech {
                let mid = NSRect(x: rect.minX, y: rect.midY - rect.height * 0.27,
                                 width: rect.width, height: rect.height * 0.54)
                drawBannerBars(ctx: ctx, rect: mid, emergence: p, settleColor: .white)
            }

        case 4: // Glass Title — single ring, no residual core (R2 N3: the orphaned
                // half-occluded remnant read as a bruise)
            drawBannerTitle(rect)
            clippedToBody {
                if p < 1 {
                    let ringR = min(maxR, pulse(22) * (1 + p * 1.8))
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent((1 - p) * 0.9).cgColor)
                    ctx.setLineWidth(3)
                    ctx.strokeEllipse(in: CGRect(x: axis.x - ringR, y: axis.y - ringR,
                                                 width: ringR * 2, height: ringR * 2))
                    if p < 0.5 {
                        drawRecordCircle(ctx, center: axis, radius: 13 * (1 - p * 2), alpha: 1 - p * 2)
                    }
                }
            }
            if heardSpeech {
                drawBannerBars(ctx: ctx, rect: barsRect, emergence: p, settleColor: .white)
            }

        case 6: // Comet Dock — the 2026-07-25 winner, SUPERSEDED 2026-08-12 by the
            // Ring-Pulses/Purple-bloom entry that now owns style 5 (see
            // drawEmergenceEntry). Kept intact for side-by-side comparison; the
            // config clamp in AppDelegate caps overlayStyle at 5, so nothing reaches
            // this case today and the render harness drives it directly.
            // Record mark travels left to a REAL dock at the bar field's edge,
            // shedding bars behind it — comet, one continuous red mass.
            let dotInset: CGFloat = 34
            let dockX = rect.minX + dotInset
            let field = NSRect(x: dockX + 18, y: rect.midY - rect.height * 0.27,
                               width: rect.maxX - 28 - (dockX + 18),
                               height: rect.height * 0.54)
            let bc = CGPoint(x: rect.midX + (dockX - rect.midX) * p, y: rect.midY)
            let br = 20 - (20 - 6) * p
            if heardSpeech {
                // Badge position normalized into field space for the comet front.
                let badgeNorm = (bc.x - field.minX) / field.width
                drawBannerBars(ctx: ctx, rect: field, emergence: p,
                               settleColor: .white, span: 0.94, badgeNorm: badgeNorm)
            }
            // Badge rides OVER the bars it sheds — it is the traveling object.
            drawRecordCircle(ctx, center: bc, radius: p < 1 ? pulse(br) : br, alpha: 1)
            if p < 0.15 {
                // Record-mark ring fades over the first beat of speech (a pop-off
                // read as a glitch; a long fade over emerging bars read as ghost
                // arcs — 150ms is the window that avoids both).
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9 * (1 - p / 0.15)).cgColor)
                ctx.setLineWidth(2.5)
                let rr = br + 5
                ctx.strokeEllipse(in: CGRect(x: bc.x - rr, y: bc.y - rr,
                                             width: rr * 2, height: rr * 2))
            }

        default: // S1 Solid Card — expanding RING (R2: the scaling disc was "the
                 // single ugliest artifact in the set"; a slab can't burst)
            drawBannerTitle(rect)
            clippedToBody {
                if p < 1 {
                    let r = min(maxR, pulse(20) * (1 + p * 1.6))
                    drawRecordCircle(ctx, center: axis, radius: r * (1 - p),
                                     alpha: (1 - p) * (1 - p))
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent((1 - p) * 0.85).cgColor)
                    ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: axis.x - r - 5, y: axis.y - r - 5,
                                                 width: (r + 5) * 2, height: (r + 5) * 2))
                }
            }
            if heardSpeech {
                drawBannerBars(ctx: ctx, rect: barsRect, emergence: p, settleColor: .white)
            }
        }

        if borderWidth > 0 {
            let inset = borderWidth / 2
            let borderRect = rect.insetBy(dx: inset, dy: inset)
            let bp = CGPath(roundedRect: borderRect, cornerWidth: Self.cornerRadius,
                            cornerHeight: Self.cornerRadius, transform: nil)
            ctx.addPath(bp)
            ctx.setStrokeColor(NSColor(red: 0.6, green: 0.25, blue: 0.8, alpha: 0.9).cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.strokePath()
        }
    }

    // MARK: - Locked record-icon entry (2026-08-12)

    private func setFill(_ ctx: CGContext, _ rgb: OverlayEmergence.RGB, _ alpha: CGFloat) {
        ctx.setFillColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    private func strokeRing(_ ctx: CGContext, center: CGPoint, stroke: OverlayEmergence.RingStroke,
                            color: OverlayEmergence.RGB) {
        guard stroke.radius > 0, stroke.alpha > 0, stroke.lineWidth > 0 else { return }
        ctx.setStrokeColor(red: color.r, green: color.g, blue: color.b, alpha: stroke.alpha)
        ctx.setLineWidth(stroke.lineWidth)
        ctx.strokeEllipse(in: CGRect(x: center.x - stroke.radius, y: center.y - stroke.radius,
                                     width: stroke.radius * 2, height: stroke.radius * 2))
    }

    /// The blooming purple pill: a rounded rect that starts as a disc the size of
    /// the record mark and relaxes into the shipped card at 1.2×.
    private func drawBloomCard(_ ctx: CGContext, geometry g: OverlayEmergence.Geometry,
                               card: OverlayEmergence.CardShape) {
        guard card.alpha > 0, card.width > 0, card.height > 0 else { return }
        let box = CGRect(x: g.centerX - card.width / 2, y: g.centerY - card.height / 2,
                         width: card.width, height: card.height)
        let path = CGPath(roundedRect: box, cornerWidth: card.cornerRadius,
                          cornerHeight: card.cornerRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let a = OverlayEmergence.purpleA
        let b = OverlayEmergence.purpleB
        let colors = [
            CGColor(red: a.r, green: a.g, blue: a.b, alpha: card.alpha),
            CGColor(red: b.r, green: b.g, blue: b.b, alpha: card.alpha),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: box.minX, y: box.midY),
                                   end: CGPoint(x: box.maxX, y: box.midY), options: [])
        }
        ctx.restoreGState()

        let bw = g.borderWidth
        guard bw > 0, card.borderAlpha > 0 else { return }
        let inner = box.insetBy(dx: bw / 2, dy: bw / 2)
        guard inner.width > 0, inner.height > 0 else { return }
        let r = max(0, card.cornerRadius - bw / 2)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil))
        let bc = OverlayEmergence.borderColor
        ctx.setStrokeColor(red: bc.r, green: bc.g, blue: bc.b, alpha: card.borderAlpha)
        ctx.setLineWidth(bw)
        ctx.strokePath()
    }

    /// Michael's locked entry (build/26-08-12-record-icon-animation/LOCKED-SETTINGS.json).
    ///
    /// Paint order matches the lab exactly: bloom card, then the emergence pulses,
    /// then the bars, then the idle ring and the record mark on top. Everything is
    /// a continuous function of `explodeProgress`, so p = 1 is simultaneously the
    /// last frame of the entry and the permanent steady state — the bars keep
    /// tracking the mic from there with no separate code path and no settle.
    private func drawEmergenceEntry(ctx: CGContext, rect: NSRect) {
        let p = OverlayEmergence.clamp01(explodeProgress)
        let g = OverlayEmergence.geometry(centerX: rect.midX, centerY: rect.midY)
        let center = CGPoint(x: g.centerX, y: g.centerY)

        drawBloomCard(ctx, geometry: g, card: OverlayEmergence.card(progress: p, geometry: g))

        for stroke in OverlayEmergence.emergencePulses(progress: p, geometry: g) {
            strokeRing(ctx, center: center, stroke: stroke, color: OverlayEmergence.ringColor)
        }

        let solid = OverlayEmergence.solidity(progress: p, geometry: g)
        for i in 0..<g.count where solid[i] > 0 {
            let level = min(1, max(0, displayLevels[i]))
            let h = g.targetHeight(level: level) * solid[i]
            guard h > 0 else { continue }
            let x = g.homeX(i)
            let bar = CGRect(x: x - g.barWidth / 2, y: g.centerY - h / 2,
                             width: g.barWidth, height: h)
            // Corner radius tracks level, so silence renders as round dots and loud
            // speech as capsules — the shipped drawBars rule, at 1.2×.
            let r = level * g.barWidth / 2
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: r, cornerHeight: r, transform: nil))
            setFill(ctx, OverlayEmergence.barColor(index: i, progress: p, geometry: g),
                    OverlayEmergence.barAlpha)
            ctx.fillPath()
        }

        let elapsed = renderElapsedOverride ?? -recordingStartedAt.timeIntervalSinceNow
        for stroke in OverlayEmergence.idleRings(progress: p, time: CGFloat(elapsed)) {
            strokeRing(ctx, center: center, stroke: stroke, color: OverlayEmergence.ringColor)
        }

        let markR = OverlayEmergence.markRadius(progress: p)
        let markA = OverlayEmergence.markAlpha(progress: p)
        if markR > 0 && markA > 0 {
            setFill(ctx, OverlayEmergence.discRed, markA)
            ctx.fillEllipse(in: CGRect(x: center.x - markR, y: center.y - markR,
                                       width: markR * 2, height: markR * 2))
        }
    }

    /// SETTLED steady state (R2-fixed): inherits its style's card material and the
    /// hairline border (was a byte-identical foreign card for 4 of 5 styles); 97%
    /// opaque (at 90% document text bled straight through); adds the word REC (the
    /// card must read cold at minute 30 — dot+digits+bars alone is a media-player
    /// idiom); timer field reserved for "1:00:00" so the layout NEVER reflows; bar
    /// field fills to a symmetric right inset (the 43.5pt dead gutter is gone).
    private func drawSettledCard(ctx: CGContext, rect: NSRect, pillPath: CGPath) {
        let colors = cardColors()
        cardGradient(ctx, rect, pillPath, from: colors.from, to: colors.to)

        let dot = CGPoint(x: rect.minX + 17, y: rect.midY)
        drawRecordCircle(ctx, center: dot, radius: 5.5, alpha: 0.95)

        let rec = NSAttributedString(string: "REC", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.68),
        ])
        rec.draw(at: NSPoint(x: rect.minX + 28, y: rect.midY - rec.size().height / 2))

        let secs = Int(renderElapsedOverride ?? -recordingStartedAt.timeIntervalSinceNow)
        let stamp = secs >= 3600
            ? String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
            : String(format: "%d:%02d", secs / 60, secs % 60)
        let t = NSAttributedString(string: stamp, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.60),
        ])
        // Right-aligned in a field wide enough for "1:00:00" — no reflow, ever.
        let timerFieldRight = rect.minX + 104
        t.draw(at: NSPoint(x: timerFieldRight - t.size().width,
                           y: rect.midY - t.size().height / 2))

        // Bars fill the remainder to a symmetric right inset; calmer amplitude
        // (40% of card height — motion, not strobe, is the 30-minute fatigue risk).
        // Right edge tuned so the last bar's ink sits ~11.5pt from the card edge,
        // matching the dot's left inset (R3: 20pt vs 11.5pt read as a dead gutter).
        let barsRect = NSRect(x: timerFieldRight + 10, y: rect.midY - rect.height * 0.20,
                              width: rect.maxX - 9 - (timerFieldRight + 10),
                              height: rect.height * 0.40)
        drawBannerBars(ctx: ctx, rect: barsRect, emergence: 1,
                       settleColor: NSColor(red: 0.85, green: 0.80, blue: 0.90, alpha: 1.0),
                       span: 0.97)

        if borderWidth > 0 {
            let inset = borderWidth / 2
            let borderRect = rect.insetBy(dx: inset, dy: inset)
            let bp = CGPath(roundedRect: borderRect, cornerWidth: Self.cornerRadius,
                            cornerHeight: Self.cornerRadius, transform: nil)
            ctx.addPath(bp)
            ctx.setStrokeColor(NSColor(red: 0.6, green: 0.25, blue: 0.8, alpha: 0.9).cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.strokePath()
        }
    }

    /// Design-review seam: seed deterministic bar levels so offscreen renders are
    /// reproducible (the live path animates them from mic level).
    internal func seedLevelsForRender(_ levels: [CGFloat]) {
        for (i, v) in levels.enumerated() where i < displayLevels.count {
            displayLevels[i] = v
        }
    }

    /// Read-only view of the waveform state, so tests can assert that the levels
    /// advance without going through a draw pass.
    internal func levelForRender(_ index: Int) -> CGFloat {
        displayLevels.indices.contains(index) ? displayLevels[index] : 0
    }

    /// Advance the per-bar waveform state by one animation tick.
    ///
    /// This used to live inside `drawBars`, which meant it only ran on the code
    /// path that draws the plain pill. The prominent banner and the settled card
    /// both render through `drawBannerBars`, which only READS `displayLevels` — so
    /// their bars never moved. The animation timer now calls this once per tick for
    /// every state, which is what makes every variant speech-reactive; `drawBars`
    /// is pure rendering.
    ///
    /// Behaviour is byte-for-byte the old code (same smoothing, jitter period,
    /// travel cadence and edge suppression) — only the call site moved.
    func advanceLevels() {
        if overlayState == .transcribing { return }

        // Fast attack, moderate release
        let smoothing: CGFloat = audioLevel > smoothLevel ? 0.8 : 0.4
        smoothLevel += (audioLevel - smoothLevel) * smoothing

        let baseLevel = smoothLevel

        // Periodically fire a traveling boost that cascades left to right
        travelTimer += 1
        if travelCooldown > 0 { travelCooldown -= 1 }
        if baseLevel > 0.1 && travelCooldown == 0 && travelTimer % 8 == 0 {
            travelBoost[0] = CGFloat.random(in: 0.1...0.25)
            travelCooldown = Int.random(in: 3...8)
        }
        // Cascade travel boost left to right
        for i in stride(from: Self.barCount - 1, through: 1, by: -1) {
            travelBoost[i] += (travelBoost[i - 1] - travelBoost[i]) * 0.4
        }
        travelBoost[0] *= 0.85 // decay the source

        for i in 0..<Self.barCount {
            // Edge suppression: 20% outermost, 12% second, 5% third
            let edgeClamp: CGFloat
            if i == 0 || i == Self.barCount - 1 {
                edgeClamp = 0.8
            } else if i == 1 || i == Self.barCount - 2 {
                edgeClamp = 0.88
            } else if i == 2 || i == Self.barCount - 3 {
                edgeClamp = 0.95
            } else {
                edgeClamp = 1.0
            }

            // Smooth jitter: wider range so only some bars peak tall
            if tick % 6 == i % 6 {
                jitterTargets[i] = CGFloat.random(in: -0.4...0.4)
            }
            jitterCurrent[i] += (jitterTargets[i] - jitterCurrent[i]) * 0.25
            let jitter = jitterCurrent[i] * (0.3 + 0.7 * baseLevel)

            let target = (baseLevel + jitter + travelBoost[i]) * edgeClamp

            // Fast attack, smoother release
            let displaySmoothing: CGFloat = target > displayLevels[i] ? 0.8 : 0.5
            displayLevels[i] += (target - displayLevels[i]) * displaySmoothing
        }
    }

    private func drawBars(ctx: CGContext, rect: NSRect, color: NSColor, compressed: Bool) {
        if overlayState == .transcribing { return }

        let effectiveDotSize = compressed ? Self.compressedDotSize : Self.dotSize
        let effectiveGap = compressed ? Self.compressedBarGap : Self.barGap
        let effectiveMaxHeight = compressed ? Self.compressedMaxBarHeight : Self.maxBarHeight

        // Bars are left-aligned from the horizontal padding in both layouts.
        let startX: CGFloat = Self.hPadding
        let centerY: CGFloat = rect.midY

        ctx.setFillColor(color.cgColor)

        for i in 0..<Self.barCount {
            let dl = max(displayLevels[i], 0)
            let minH: CGFloat = compressed ? 0.5 : 1.0
            let h = minH + (effectiveMaxHeight - minH) * dl

            let x = startX + CGFloat(i) * (effectiveDotSize + effectiveGap)
            let y = centerY - h / 2
            let barRect = CGRect(x: x, y: y, width: effectiveDotSize, height: h)
            // Border radius scales with level: square when silent, fully rounded when loud
            let r = dl * (effectiveDotSize / 2)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawSpinner(ctx: CGContext, rect: NSRect) {
        let cx = rect.midX  // centered when transcribing
        let cy = rect.midY
        let spokeCount = 8
        let innerR: CGFloat = 6.0  // distance from center to inner tip
        let outerR: CGFloat = 10.0  // distance from center to outer tip
        let spokeWidth: CGFloat = 2.5

        // Current leading spoke index (rotates at ~10 steps/sec)
        let leadingSpoke = (tick / 3) % spokeCount

        ctx.setLineWidth(spokeWidth)
        ctx.setLineCap(.round)

        for i in 0..<spokeCount {
            // Angle: 0=top, going clockwise. Negate because CG Y-axis is up.
            let angle = -CGFloat(i) * (.pi / 4) + .pi / 2

            let x1 = cx + cos(angle) * innerR
            let y1 = cy + sin(angle) * innerR
            let x2 = cx + cos(angle) * outerR
            let y2 = cy + sin(angle) * outerR

            // Brightness: leading spoke is brightest, fading behind it
            let stepsBehind = (leadingSpoke - i + spokeCount) % spokeCount
            let alpha = CGFloat(spokeCount - stepsBehind) / CGFloat(spokeCount)

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12 + 0.78 * alpha).cgColor)
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
            ctx.strokePath()
        }
    }

    private func drawStreamingText(ctx: CGContext, rect: NSRect) {
        guard !streamingText.isEmpty else { return }

        let textMaxWidth = Self.streamingTextMaxWidth
        let textX = rect.midX - textMaxWidth / 2

        // The text area starts below the compressed bars area
        let textAreaTop = rect.maxY - Self.compressedBarsAreaHeight - Self.streamingTextTopPad
        let textAreaBottom = rect.minY + Self.streamingTextBottomPad
        let textAreaHeight = textAreaTop - textAreaBottom

        // Get the visible tail of the text (last ~6 lines)
        let visibleText = Self.visibleTailText(from: streamingText, maxWidth: textMaxWidth)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.streamingTextFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraphStyle,
        ]

        let attrStr = NSAttributedString(string: visibleText, attributes: attributes)
        let textHeight = Self.streamingTextHeight(for: visibleText, maxWidth: textMaxWidth)

        // Anchor text to the top of the text area (new text pushes old text up)
        let textRect = NSRect(x: textX, y: textAreaTop - textHeight, width: textMaxWidth, height: textHeight)

        // Clip to the text area so nothing bleeds outside the pill
        ctx.saveGState()
        ctx.clip(to: NSRect(x: rect.minX, y: textAreaBottom, width: rect.width, height: textAreaHeight))

        NSGraphicsContext.current?.saveGraphicsState()
        attrStr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.current?.restoreGraphicsState()

        ctx.restoreGState()
    }
}
