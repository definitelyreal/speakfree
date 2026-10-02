// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Wires Edit Mode into the app: fn taps, recording, the window, and Return's insertion into the
/// app the session started in. The session's rules live in EditSessionCore; this class is glue.
///
/// Flow: fn tap with no session → capture the frontmost app (once, before the window opens; never
/// recaptured) → open the window → record a take. Each finished take arrives through
/// AppDelegate.editFinalizeSink as a paragraph. Return re-activates the captured app, checks it is
/// still the same window (and field, where one was captured), and inserts; any doubt copies the
/// text and keeps the draft open.
@MainActor
final class EditSessionController {

    /// What the controller needs from AppDelegate (closures keep the 3,000-line file untouched
    /// beyond wiring).
    struct Hooks {
        var setPendingTarget: ((sessionID: UUID, segmentID: UUID)?) -> Void
        var startRecording: () -> Bool          // true when a take actually started
        var stopRecording: () -> Void
        var abortRecording: () -> Void
        var isInPostBuffer: () -> Bool
        var inserter: () -> TextInserter?
        var isRemoteDesktop: (String?) -> Bool
        var onSessionClosed: () -> Void
        var saveConfig: ((inout Config) -> Void) -> Void
        var loadConfig: () -> Config
        var noteRecents: () -> Void
        var noteCommittedText: (String, String?, UUID) -> Void = { _, _, _ in }
        /// True while the app is recording (any take, any mode).
        var isRecording: () -> Bool = { false }
        /// Tests turn these off: no window on screen, no read of the real frontmost app.
        var presentWindow = true
        var captureFrontmostApp = true
        /// Tests inject a scripted cleaner; nil = the real confined CLI.
        var cleaner: EditCleanupRunning?
        /// Tests inject a fake; nil = the real pasteboard.
        var clipboard: EditClipboard?
    }

    private let hooks: Hooks
    private let cleaner: EditCleanupRunning
    private let latencyLog = EditLatencyLog()
    private(set) var core: EditSessionCore?
    private(set) var windowController: EditWindowController?
    private var optionsPopover: NSPopover?
    private var changesPopover: NSPopover?

    // The destination, captured once at session open.
    private var targetApp: NSRunningApplication?
    private var targetIdentity: EditTargetIdentity?
    private var capturedWindow: AXUIElement?
    private var capturedField: AXUIElement?
    private var captureDone = true
    private var captureGeneration: UInt64 = 0
    private(set) var committing = false
    /// Bumped at every take start; a Return scheduled for an earlier take does not fire.
    private var takeGeneration = 0

    init(hooks: Hooks) {
        self.hooks = hooks
        if let injected = hooks.cleaner {
            cleaner = injected
        } else {
            let path = hooks.loadConfig().claudeExecutablePath
            cleaner = CleanupService(configuredExecutablePath: path, timeout: 20)
        }
    }

    var isOpen: Bool { core?.isOpen == true }

    /// Settings changed on disk (the Settings window, or the config file): apply cleanup on/off,
    /// consent, model and animation to the open session at once. Turning cleanup off here stops
    /// its calls immediately, the same as the window's own Options.
    func configChanged() {
        guard let core = core, core.isOpen else { return }
        let s = EditModeSettings.from(hooks.loadConfig())
        if s.model != core.settings.model { core.setModel(s.model) }
        if s.animation != core.settings.animation { core.setAnimation(s.animation) }
        if s.consentGiven != core.settings.consentGiven { core.setConsentGiven(s.consentGiven) }
        if s.cleanupEnabled != core.settings.cleanupEnabled { core.setCleanupEnabled(s.cleanupEnabled) }
    }

    // MARK: fn taps (EditKeyReducer)

    func handleFnTap() {
        // While Return's insertion is in flight the window is hidden but the session is still
        // open; a tap now would start a take nobody can see. Ignore it, audibly.
        if committing {
            NSSound.beep()
            return
        }
        let state: EditKeyReducer.SessionState
        if let core = core, core.isOpen {
            state = core.recordingSegmentID != nil ? .recording : .sessionOpenIdle
        } else {
            state = .noSession
        }
        switch EditKeyReducer.action(for: state) {
        case .openSessionAndRecord:
            openSession()
            startTake()
        case .endSegment:
            stopTake()
        case .startSegment:
            startTake()
        }
    }

    // MARK: Session lifecycle

    func openSession(sampleParagraphs: Bool = false) {
        guard core == nil || core?.isOpen == false else {
            windowController?.show()
            return
        }
        if hooks.captureFrontmostApp { captureTarget() }
        let config = hooks.loadConfig()
        let settings = EditModeSettings.from(config)
        let persistence = DevMode.effectiveSaveRecordings(config)
        let core = EditSessionCore(persistenceEnabled: persistence, settings: settings, cleaner: cleaner,
                                   clipboard: hooks.clipboard ?? PasteboardClipboard(inserter: hooks.inserter), latencyLog: latencyLog,
                                   targetAppName: targetIdentity?.appName)
        self.core = core
        let wc = EditWindowController(core: core, targetName: targetDisplayName())
        windowController = wc
        core.onEvent = { [weak self] event in self?.handle(event) }
        wc.onReturn = { [weak self] in self?.returnPressed() }
        wc.onEscape = { [weak self] in self?.escapePressed() }
        wc.onCloseRequest = { [weak self] in self?.closeRequested() ?? true }
        wc.onOptions = { [weak self] anchor in self?.showOptions(anchor) }
        wc.onChanges = { [weak self] id, anchor in self?.showChanges(id, anchor: anchor) }
        wc.onRetry = { [weak self] id in self?.core?.retryCleanup(id) }
        wc.onCompareChoose = { [weak self] label in self?.core?.chooseCandidate(label) }
        wc.onCompareClose = { [weak self] in self?.core?.dismissCompare() }
        if hooks.presentWindow { wc.show() }
        if sampleParagraphs { addSampleParagraph() }
    }

    private func targetDisplayName() -> String? {
        guard let id = targetIdentity else { return nil }
        if let title = id.windowTitle, !title.isEmpty, title != id.appName {
            return "\(id.appName): \(title)"
        }
        return id.appName
    }

    private func handle(_ event: EditCoreEvent) {
        windowController?.handle(event)
        if event == .readyToCommit {
            // The take Return waited for is on screen now; give it a beat to be seen, then insert,
            // unless he started another take in the meantime (he is still dictating).
            let generation = takeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.takeGeneration == generation else { return }
                    self.returnPressed()
                }
            }
        }
    }

    private func closeSession() {
        captureGeneration &+= 1
        captureDone = true
        // A take still recording belongs to this session: stop it and throw it away, so no
        // orphan audio can land in a later session.
        if core?.recordingSegmentID != nil {
            hooks.abortRecording()
        }
        optionsPopover?.close()
        changesPopover?.close()
        windowController?.window.orderOut(nil)
        windowController = nil
        if let core = core, core.isOpen { core.terminate() }
        core = nil
        // Never clear the pending target while a take is still being captured or is in its
        // post-release buffer: finalize must still see it and route the take to this (now closed)
        // session, where it is dropped. Clearing it here would send a discarded take to the normal
        // inserter. Finalize and abort consume it themselves.
        if !hooks.isRecording() && !hooks.isInPostBuffer() {
            hooks.setPendingTarget(nil)
        }
        targetApp = nil
        targetIdentity = nil
        capturedWindow = nil
        capturedField = nil
        committing = false
        hooks.onSessionClosed()
    }

    /// App quit with a session open: stop cleanup, keep the draft (when saving is on).
    func terminate() {
        core?.terminate()
    }

    // MARK: Takes

    private func startTake() {
        guard let core = core, core.isOpen else { return }
        // A tap during the previous take's short post-buffer would otherwise CONTINUE that take
        // (AppDelegate.handleRecordingStart). Wait for its finalize to begin, then start fresh.
        if hooks.isInPostBuffer() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.startTake() }
            }
            return
        }
        // Something else is already recording (a take this session did not start): never adopt
        // it, because its audio is not this paragraph's.
        if hooks.isRecording() {
            NSSound.beep()
            return
        }
        takeGeneration += 1
        let segmentID = core.beginTake()
        hooks.setPendingTarget((sessionID: core.state.id, segmentID: segmentID))
        if !hooks.startRecording() {
            hooks.setPendingTarget(nil)
            core.takeProducedNothing(segmentID)
        }
    }

    private func stopTake() {
        guard let core = core, let id = core.recordingSegmentID else { return }
        core.takeStopped(id)
        hooks.stopRecording()
    }

    /// AppDelegate.editFinalizeSink: a take's on-device text.
    func deliver(_ payload: EditFinalizePayload, kept: Bool) {
        guard let core = core, core.state.id == payload.sessionID else { return }
        let stem = kept ? payload.audioURL.deletingPathExtension().lastPathComponent : nil
        core.takeTranscribed(payload.segmentID, raw: payload.raw, pipelineText: payload.pipelineText,
                             componentStem: stem)
    }

    /// AppDelegate.editFinalizeFailureSink: a take that produced no text.
    func deliverNothing(sessionID: UUID, segmentID: UUID) {
        guard let core = core, core.state.id == sessionID else { return }
        core.takeProducedNothing(segmentID)
    }

    // MARK: DevMode sample paragraphs (exercise the window without a microphone)

    static let samples: [(raw: String, pipeline: String)] = [
        ("the garden center opens at eight so lets leave by seven thirty",
         "The garden center opens at eight so lets leave by seven thirty."),
        ("the recital is on thursday no wait friday at six",
         "The recital is on Thursday no wait Friday at six."),
        ("pick up milk Kama bread and a lemon paired",
         "Pick up milk Kama bread and a lemon paired."),
        ("do not approve the draft until legal has signed off",
         "Do not approve the draft until legal has signed off."),
        ("the new version is faster column it opens in under a second",
         "The new version is faster column it opens in under a second."),
    ]
    private var sampleIndex = 0

    func addSampleParagraph() {
        guard let core = core, core.isOpen else { return }
        let sample = Self.samples[sampleIndex % Self.samples.count]
        sampleIndex += 1
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: sample.raw, pipelineText: sample.pipeline)
    }

    // MARK: Return

    private func returnPressed() {
        guard let core = core, core.isOpen, !committing else { return }
        // Wait before freezing the draft. The window remains editable during capture,
        // so Return must include any typing that arrives before capture completes.
        guard captureDone else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.core === core else { return }
                    self.returnPressed()
                }
            }
            return
        }
        // An input method is still composing: its text is not in the draft yet. Wait for it.
        if windowController?.textView.hasMarkedText() == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated { self?.returnPressed() }
            }
            return
        }
        // Anything typed but not yet handed to the session (a deferred reconcile) goes in first.
        windowController?.syncTypingNow()
        switch core.returnPressed() {
        case .waitingForTake:
            // Finish the take first; `.readyToCommit` brings us back once it is shown.
            if core.recordingSegmentID != nil { stopTake() }
        case .nothingToInsert:
            closeSession()
        case .commit(let text):
            commit(text)
        }
    }

    private func commit(_ text: String) {
        guard let core = core else { return }
        let isRemote = hooks.isRemoteDesktop(targetIdentity?.bundleID)
        if case .retain(let reason) = EditDestination.precheck(targetIdentity, isRemoteDesktop: isRemote) {
            core.commitRetained(reason)
            return
        }
        guard let app = targetApp else {
            core.commitRetained(.targetQuit)
            return
        }
        committing = true
        windowController?.window.orderOut(nil)
        app.activate(options: [])
        waitForFrontmost(pid: app.processIdentifier, deadline: Date().addingTimeInterval(1.5)) { [weak self] timedOut in
            guard let self, self.core === core else { return }
            self.verifyAndInsert(text, activationTimedOut: timedOut)
        }
    }

    private func waitForFrontmost(pid: pid_t, deadline: Date, done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            // A short settle so the app's own key window and focus are restored.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { done(false) }
            return
        }
        if Date() >= deadline { done(true); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.waitForFrontmost(pid: pid, deadline: deadline, done: done) }
        }
    }

    private func verifyAndInsert(_ text: String, activationTimedOut: Bool) {
        guard let core = core, let identity = targetIdentity, let app = targetApp else {
            retain(.targetQuit)
            return
        }
        let pid = app.processIdentifier
        let window = capturedWindow
        let field = capturedField
        let title = identity.windowTitle
        let inserter = hooks.inserter()
        // AX reads can block on an unresponsive app: read off main, decide on main.
        DispatchQueue.global(qos: .userInitiated).async {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.5)
            let nowWindow = Self.copyElement(appEl, kAXFocusedWindowAttribute)
            let nowTitle = nowWindow.flatMap { Self.copyString($0, kAXTitleAttribute) }
            let sameWindow: Bool? = (window != nil && nowWindow != nil) ? CFEqual(window, nowWindow) : nil
            let sameTitle: Bool? = (title != nil && nowTitle != nil) ? (title == nowTitle) : nil
            var sameField: Bool?
            if let field = field {
                let nowField = Self.copyElement(appEl, kAXFocusedUIElementAttribute)
                sameField = nowField.map { CFEqual($0, field) }
            }
            let secure = IsSecureEventInputEnabled()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.core === core else { return }
                    let observed = EditTargetObservation(
                        targetStillRunning: !app.isTerminated,
                        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        sameWindow: sameWindow, sameTitle: sameTitle, sameField: sameField,
                        secureInputActive: secure, activationTimedOut: activationTimedOut)
                    let verdict = EditDestination.verdict(
                        target: identity, isRemoteDesktop: self.hooks.isRemoteDesktop(identity.bundleID),
                        observed: observed)
                    DiagnosticLogger.shared.log("EditMode: commit verdict \(verdict) (window=\(String(describing: sameWindow)) title=\(String(describing: sameTitle)) field=\(String(describing: sameField)))")
                    guard verdict == .insert, let inserter = inserter else {
                        if case .retain(let reason) = verdict { self.retain(reason) } else { self.retain(.unknownField) }
                        return
                    }
                    self.submitPreparedText(text, using: inserter, refocusing: field)
                }
            }
        }
    }

    /// Target validation has completed. Each submission owns its result, including
    /// publication failures and deferred refocus, without changing AppDelegate's callbacks.
    func submitPreparedText(_ text: String, using inserter: TextInserter, refocusing field: AXUIElement?) {
        guard let core = core else { return }
        inserter.insert(text: text, refocusing: field, handlesRecovery: true) { [weak self] outcome in
            MainActor.assumeIsolated {
                guard let self, self.core === core else { return }
                if TextInserter.deliveryWasSubmitted(outcome) {
                    self.finishCommit()
                } else {
                    self.retain(.insertionUncertain)
                }
            }
        }
    }

    private func retain(_ reason: EditRetainReason) {
        committing = false
        guard let core = core else { return }
        core.commitRetained(reason)
        if hooks.presentWindow { windowController?.show() }
    }

    private func finishCommit() {
        guard let core = core else { return }
        let artifact = core.commitSucceeded(targetApp: targetIdentity?.bundleID)
        hooks.noteCommittedText(artifact.text, targetIdentity?.bundleID, artifact.sessionID)
        let config = hooks.loadConfig()
        if DevMode.effectiveSaveRecordings(config) {
            EditRecents.write(artifact)
            hooks.noteRecents()
        }
        closeSession()
    }

    // MARK: Esc / close

    private func escapePressed() {
        guard let core = core else { return }
        switch core.escapePressed() {
        case .discardedTake:
            hooks.abortRecording()
            hooks.setPendingTarget(nil)
        case .armed:
            break
        case .closed:
            closeSession()
        }
    }

    /// Red close button / Cmd+W: the same guard as Esc. Returns whether the window may close.
    private func closeRequested() -> Bool {
        guard core != nil else { return true }
        // Same path as Esc; closeSession orders the window out itself, so AppKit never closes it.
        escapePressed()
        return false
    }

    // MARK: Target capture

    private func captureTarget() {
        captureGeneration &+= 1
        let generation = captureGeneration
        capturedWindow = nil
        capturedField = nil
        captureDone = true
        let own = NSRunningApplication.current.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own else {
            targetApp = nil
            targetIdentity = nil
            return
        }
        targetApp = front
        let pid = front.processIdentifier
        let name = front.localizedName ?? front.bundleIdentifier ?? "the app"
        let bundleID = front.bundleIdentifier
        targetIdentity = EditTargetIdentity(pid: pid, bundleID: bundleID, appName: name,
                                            windowTitle: nil, hasWindow: false, hasField: false)
        // Capture identity only, off-main. Electron's unreliable AX text reads/writes do
        // not imply that its focused control's identity is unavailable. Skipping this
        // lookup made Claude copy-only even when it exposed the original composer.
        captureDone = false
        DispatchQueue.global(qos: .userInitiated).async {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.5)
            let window = Self.copyElement(appEl, kAXFocusedWindowAttribute)
            let title = window.flatMap { Self.copyString($0, kAXTitleAttribute) }
            var field: AXUIElement?
            // Ask the captured app, not the system-wide focus: our Edit window may
            // already be key by the time this background lookup runs.
            if let f = Self.copyElement(appEl, kAXFocusedUIElementAttribute) {
                var fpid: pid_t = 0
                if AXUIElementGetPid(f, &fpid) == .success, fpid == pid { field = f }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.captureGeneration == generation,
                          self.targetApp?.processIdentifier == pid else { return }
                    self.capturedWindow = window
                    self.capturedField = field
                    self.targetIdentity = EditTargetIdentity(
                        pid: pid, bundleID: bundleID, appName: name,
                        windowTitle: (title?.isEmpty == false) ? title : nil,
                        hasWindow: window != nil, hasField: field != nil)
                    self.captureDone = true
                    self.windowController?.setTargetName(self.targetDisplayName())
                }
            }
        }
    }

    nonisolated private static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let value = ref,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    nonisolated private static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    // MARK: Options and Changes popovers

    private func showOptions(_ anchor: NSView) {
        guard let core = core, let wc = windowController else { return }
        let view = EditOptionsView(
            core: core,
            onCleanup: { [weak self] on in self?.setCleanup(on) },
            onModel: { [weak self] m in self?.setModel(m) },
            onAnimation: { [weak self] a in self?.setAnimation(a) },
            onPreview: { [weak wc] in wc?.previewAnimation() },
            onCompare: { [weak self] a, b in self?.startCompare(a, b) },
            onSample: DevMode.isActive ? { [weak self] in self?.addSampleParagraph() } : nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = view
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        optionsPopover = popover
    }

    private func setCleanup(_ on: Bool) {
        guard let core = core else { return }
        if on && !core.settings.consentGiven {
            guard EditConsentSheet.run(in: windowController?.window) == .allow else {
                optionsPopover?.close()
                return
            }
            hooks.saveConfig { $0.editModeCloudConsent = ISO8601DateFormatter().string(from: Date()) }
            core.setConsentGiven(true)
        }
        hooks.saveConfig { $0.editModeCleanup = FlexBool(on) }
        core.setCleanupEnabled(on)
    }

    private func setModel(_ m: CleanupService.Model) {
        hooks.saveConfig { $0.editModeCleanupModel = m.rawValue }
        core?.setModel(m)
    }

    private func setAnimation(_ a: EditAnimationStyle) {
        hooks.saveConfig { $0.editModeAnimation = a.rawValue }
        core?.setAnimation(a)
        windowController?.previewAnimation()
    }

    private func startCompare(_ a: CleanupService.Model, _ b: CleanupService.Model) {
        guard let core = core, let wc = windowController, let id = wc.currentSegmentID() else { return }
        optionsPopover?.close()
        if !core.startCompare(segmentID: id, models: [a, b]) {
            NSSound.beep()
        }
    }

    private func showChanges(_ id: UUID, anchor: NSView) {
        guard let core = core else { return }
        let vc = EditVersionsView(core: core, segmentID: id, onRetry: { [weak self] in
            self?.core?.retryCleanup(id)
        })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        changesPopover = popover
    }
}

/// The real clipboard, used only by the running app (tests inject a fake).
final class PasteboardClipboard: EditClipboard {
    private let inserter: () -> TextInserter?

    init(inserter: @escaping () -> TextInserter?) {
        self.inserter = inserter
    }

    func copy(_ text: String) -> Bool {
        guard let inserter = inserter() else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        return inserter.replaceClipboardForUser(with: [item])
    }
}
