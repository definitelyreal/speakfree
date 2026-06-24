import AppKit
import ApplicationServices
import AVFoundation
import os
import Sparkle

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyManager: HotkeyManager?
    var recorder: AudioRecorder!
    var transcriber: Transcriber!
    var inserter: TextInserter!
    var config: Config!
    private let _isPressed = OSAllocatedUnfairLock(initialState: false)
    var isPressed: Bool {
        get { _isPressed.withLock { $0 } }
        set { _isPressed.withLock { $0 = newValue } }
    }
    var isReady = false
    public var lastTranscription: String?
    private var recordingOverlay = RecordingOverlay()
    private var settingsViewModel: SettingsViewModel?
    private var localAPIServer: LocalAPIServer?
    private var recordingStyleMode: TextPostProcessor.StyleMode = .none

    // Clean up whisper model before exit to prevent ggml Metal assertion crash.
    // The crash happens in __cxa_finalize_ranges when ggml tries to free Metal
    // residency sets that are still active during static destructor cleanup.
    public func applicationWillTerminate(_ notification: Notification) {
        // applicationWillTerminate cannot await — bridge the async unload to sync via the
        // transcriber's synchronous passthrough (semaphore-backed inside Transcriber).
        transcriber?.unloadModelSync()
        hotkeyManager?.stop()
        recorder?.shutdown()
        localAPIServer?.stop()
    }

    // Sparkle auto-updater — checks for updates on launch and periodically
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // The AXUIElement focused when recording started — used to refocus before pasting
    private var recordingSourceElement: AXUIElement?
    // Text before cursor at recording start — passed to whisper as context prompt
    private var recordingContextText: String?
    // Screen OCR text captured at recording start (opt-in). Written only on main via
    // generation-token check, so no lock needed.
    private var screenContextText: String?
    // Generation token: bumped at recording start AND end/cancel. The OCR background task
    // captures the UUID at dispatch time and writes back only if the token still matches,
    // discarding stale results from previous recordings.
    private var screenCaptureGeneration: UUID = UUID()

    // Adaptive post-buffer (T2.1): poll trailing audio after key release and finalize as soon as
    // ~150ms of trailing silence is observed, hard-capped at 300ms (never worse than the old flat
    // wait). The decision itself lives in the pure PostBufferPolicy; this timer only feeds it RMS
    // windows from the live recorder.
    private var postBufferTimer: Timer?
    /// Window cadence the post-buffer poll uses (matches PostBufferPolicy's default window grain).
    private let postBufferWindowMs: Double = 30.0

    // Streaming transcription: periodic inference during recording
    private var streamingTimer: Timer?
    private var streamingText: String = ""
    private var isStreamingInFlight = false  // prevents overlapping inference runs
    /// Streaming-overlay text assembler. Owns the "committed" display text (sentences that
    /// have ended and won't reflow) and the stable-append logic, extracted to
    /// `StreamingTextAssembler` so the assembly is unit-testable. Behavior is byte-identical
    /// to the prior inline `committedStreamingText` + `buildStableDisplayText`.
    private var streamingAssembler = StreamingTextAssembler()
    /// Monotonically-increasing token bumped every time streaming stops. Stale partial-result
    /// callbacks that arrive on main after recording ended compare against this and are dropped.
    private var streamingGeneration: UInt = 0

    // T2.3 — Reuse last streaming partial. These three capture the LAST completed streaming pass so
    // `finalizeRecording` can (when StreamingReuse.decide approves) skip the redundant final
    // inference and route this saved raw partial through TextPipeline instead. Reset on every
    // streaming start/stop. Written on the main queue only.
    /// Raw engine text the last completed streaming pass returned (pre-TextPipeline). "" = none.
    private var lastStreamingRawPartial: String = ""
    /// Recorder sample count the last streaming pass ran over.
    private var lastStreamingSampleCount: Int = 0
    /// `CFAbsoluteTime` the last streaming pass completed (0 = none yet).
    private var lastStreamingCompletedAt: Double = 0

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        recorder = AudioRecorder()
        inserter = TextInserter()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    /// Handles dock-drag, Finder "Open With", and `speakfree <file>` — all funnel here.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let audioExtensions: Set<String> = ["m4a","mp3","wav","flac","aiff","aif","caf","aac","mp4","mov","ogg"]
        let audioURLs = urls.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard let first = audioURLs.first else { return }
        DispatchQueue.main.async {
            FileTranscriptionController.show(url: first)
        }
    }

    // MARK: - Setup failure seam

    /// Injectable executor: tests replace this to simulate a throw without running the full setup.
    /// Production code leaves it nil — `setup()` calls `setupInner()` directly.
    var _setupExecutor: (() throws -> Void)?

    private func setup() {
        do {
            if let executor = _setupExecutor {
                try executor()
            } else {
                try setupInner()
            }
        } catch {
            let message = error.localizedDescription
            DiagnosticLogger.shared.log("Fatal setup error: \(message)")

            // Transition the menu bar to the visible error state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.statusBar.state = .setupFailed(message: message)
                self.statusBar.buildMenu()
            }

            // Surface a modal alert. Runs on main so we block the setup thread here
            // until the user dismisses — the process stays alive and in the error state.
            DispatchQueue.main.sync { [weak self] in
                guard let self else { return }
                self.showSetupFailureAlert(message: message)
            }
        }
    }

    /// Shows a blocking NSAlert describing the setup failure.
    /// Separated from `setup()` so it can be replaced by a seam in tests.
    var _alertPresenter: ((String) -> Void)?

    func showSetupFailureAlert(message: String) {
        if let presenter = _alertPresenter {
            presenter(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "speakfree failed to start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Continue Anyway")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
        // If the user clicked "Continue Anyway" the app stays alive in the error state.
    }

    /// Test-only bridge — calls `setup()` directly so tests can exercise the failure path
    /// without going through `applicationDidFinishLaunching`. Not called by production code.
    func runSetupForTesting() {
        setup()
    }

    private func setupInner() throws {
        DiagnosticLogger.shared.setup()
        DiagnosticLogger.shared.log("Setup started")
        config = Config.load()

        // Check for crash recovery before touching recordings
        if let orphanedURL = RecordingStore.checkCrashRecovery() {
            print("Crash recovery: found orphaned recording at \(orphanedURL.path)")
            RecordingStore.clearSentinel()
            DispatchQueue.main.async {
                self.statusBar.showCrashRecovery(url: orphanedURL, handler: { [weak self] url in
                    self?.reprocess(audioURL: url)
                })
            }
        }

        let maxRecordings = (config.preserveAllRecordings?.value ?? false) ? 0 : Config.effectiveMaxRecordings(config.maxRecordings)
        if maxRecordings > 0 {
            RecordingStore.prune(maxCount: maxRecordings)
        }

        // One-time migration: clean garbage auto-learned entries
        DispatchQueue.main.sync {
            VocabularyMigration.runIfNeeded()
        }

        // Resolve the engine + model identifier, then check whether the model is on disk.
        // If not, show the welcome dialog for both Whisper and Parakeet.
        let engineID = effectiveEngineID
        var modelID: String
        var needsDownload = false

        if engineID == "parakeet" {
            modelID = config.parakeetModel ?? "parakeet-tdt-0.6b-v3"
            needsDownload = !ParakeetModelManager.shared.isModelDownloaded(modelID)
        } else {
            // Determine effective model (multilingual if needed)
            var effectiveModelSize = config.modelSize
            if config.language != "en" && WhisperLanguage.isEnglishOnly(config.modelSize) {
                effectiveModelSize = WhisperLanguage.multilingualModel(for: config.modelSize)
                print("Language \(config.language) requires multilingual model — using \(effectiveModelSize)")
            }

            if !Transcriber.modelExists(modelSize: effectiveModelSize) {
                // Fallback: if we wanted multilingual but only have .en, use .en —
                // same size class, so transcription quality is unchanged.
                if effectiveModelSize != config.modelSize && Transcriber.modelExists(modelSize: config.modelSize) {
                    DiagnosticLogger.shared.log("Multilingual model \(effectiveModelSize) not found — using \(config.modelSize) as fallback")
                    effectiveModelSize = config.modelSize
                }
                else {
                    // NO silent quality fallback. Substituting "any model on disk" once
                    // swapped tiny.en in for a missing large-v3-turbo and silently degraded
                    // every dictation for days (2026-06-11 collapse). A missing model gets
                    // the explicit download dialog, pre-set to the configured model.
                    DiagnosticLogger.shared.log("Configured model \(effectiveModelSize) missing from disk — showing download dialog (no silent fallback)")
                    needsDownload = true
                }
            }
            modelID = effectiveModelSize
        }

        if needsDownload {
            var selectedEngine = engineID
            var selectedModel = modelID
            var selectedLanguage = config.language
            var didProceed = false
            DispatchQueue.main.sync {
                let result = WelcomeController.show(suggestedEngine: engineID, suggestedModel: modelID)
                selectedEngine = result.engine
                selectedModel = result.modelID
                selectedLanguage = result.language
                didProceed = result.shouldContinue
            }
            guard didProceed else {
                DispatchQueue.main.async {
                    self.statusBar.state = .noModel
                    self.statusBar.buildMenu()
                }
                return
            }
            config.engine = selectedEngine
            config.language = selectedLanguage
            if selectedEngine == "parakeet" {
                config.parakeetModel = selectedModel
            } else {
                config.modelSize = selectedModel
            }
            try? config.save()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.setup() }
            return
        }

        let engine = EngineFactory.make(config: config)
        transcriber = Transcriber(engine: engine, modelID: modelID, language: config.language)
        activeEngineID = engineID
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)
        DiagnosticLogger.shared.log("Model loaded: \(modelID) (engine: \(engineID))")

        // Configure pre-buffer
        recorder.preBufferEnabled = config.preBuffer?.value ?? true

        // Configure model persistence
        transcriber.keepModelLoaded = config.keepModelLoaded ?? "auto"
        transcriber.startMemoryPressureMonitoring()
        warmUpEngine(engineID)

        DispatchQueue.main.async {
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.buildMenu()
        }

        // Whisper-only startup gate: a Parakeet setup has no whisper-cli/whisper-binary and
        // must not be blocked here. Gate on the effective engine so permissions/hotkeys still init.
        if engineID == "whisper" && Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        Permissions.ensureMicrophone()

        // For Developer ID signed releases, macOS tracks TCC grants by bundle ID + team ID,
        // both of which stay constant across version updates. Resetting TCC on every version
        // bump breaks first launch after every release — don't do it.
        // For beta (ad-hoc signed) builds, the code identity changes on each rebuild, so we
        // still reset there to avoid stale grants.
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        if isBeta && Permissions.didUpgrade() {
            print("Beta upgrade detected — resetting Accessibility trust")
            Permissions.resetAccessibility()
        } else {
            _ = Permissions.didUpgrade()  // still update .last-version file
        }

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted — prompting...")
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
            }
            Permissions.promptAccessibility()
            print("Waiting for Accessibility permission...")
            // Bounded wait: re-surface the system dialog every 60 s so the user is never
            // left with a silent infinite poll. Each 60-second cycle consists of 0.5-second
            // checks so we respond quickly when the user grants permission.
            let recheckInterval = 0.5
            let repromptCycle = 60.0
            var elapsed = 0.0
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: recheckInterval)
                elapsed += recheckInterval
                if elapsed >= repromptCycle {
                    elapsed = 0.0
                    print("Accessibility: still waiting — re-prompting...")
                    Permissions.promptAccessibility()
                }
            }
            print("Accessibility: granted")
            DispatchQueue.main.async {
                self.statusBar.state = .idle
                self.statusBar.buildMenu()
            }
        } else {
            print("Accessibility: granted")
        }

        // Warm up the audio engine now so first recording starts instantly
        recorder.warmUp()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isSetupComplete = true
            self.startListening()
            if self.openSettingsAfterSetup {
                self.openSettingsAfterSetup = false
                self.showSettings()
            }
            self.showTutorialPopoverIfNeeded()
        }
    }

    private func startListening() {
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )

        hotkeyManager?.start(
            onKeyDown: { [weak self] in
                self?.handleKeyDown()
            },
            onKeyUp: { [weak self] in
                self?.handleKeyUp()
            },
            onAbort: { [weak self] in
                self?.handleRecordingAbort()
            }
        )

        isReady = true
        statusBar.state = .idle
        statusBar.buildMenu()

        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        print("speakfree v\(SpeakFree.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        print("Ready.")
        DiagnosticLogger.shared.log("Ready — hotkey=\(hotkeyDesc) model=\(config.modelSize)")

        // Start LocalAPIServer on launch if enabled in config (T1.2).
        syncLocalAPIServerState()

        // Verify all subsystems after startup
        verifySubsystems(context: "startup")
    }

    /// Comprehensive health check — logs status of all subsystems.
    /// Call at startup and before each recording.
    private func verifySubsystems(context: String) {
        var issues: [String] = []

        // 1. Status bar icon
        if statusBar.statusItem.button?.image == nil {
            issues.append("status bar icon missing")
            statusBar.state = .idle  // force redraw
        }

        // 2. Event tap
        if let hm = hotkeyManager {
            hm.ensureTapHealthy()
        } else {
            issues.append("hotkeyManager is nil")
        }

        // 3. Audio engine
        recorder.ensureAudioHealthy()

        // 4. Accessibility
        if !AXIsProcessTrusted() {
            issues.append("accessibility not granted")
        }

        // 5. Microphone
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            issues.append("microphone not granted")
        }

        // 6. Model file exists (whisper-only — parakeet models live in FluidAudio's own cache
        //    and are validated by the engine on load, not via a ggml-*.bin lookup).
        //    Gate on the effective engine (honoring SPEAKFREE_ENGINE) so a Parakeet setup
        //    doesn't trip a whisper ggml-*.bin health check.
        if effectiveEngineID == "whisper" {
            if Transcriber.findModel(modelSize: transcriber?.modelID ?? config.modelSize) == nil {
                issues.append("model file missing")
            }
        }

        if issues.isEmpty {
            DiagnosticLogger.shared.log("Health check (\(context)): all OK")
        } else {
            DiagnosticLogger.shared.log("Health check (\(context)): ISSUES — \(issues.joined(separator: ", "))")
            print("⚠️ Health check (\(context)): \(issues.joined(separator: ", "))")
        }
    }

    /// The model identifier currently loaded by the transcriber.
    public var activeModelSize: String { transcriber?.modelID ?? config.modelSize }

    /// The engine id ("whisper" | "parakeet") of the currently-built transcriber. Tracked here
    /// so reloadConfig can detect an engine switch without reaching into transcriber.engine.*.
    private var activeEngineID: String = "whisper"

    /// True once setupInner() has run to completion (hotkey listener started).
    /// While false, the app is in the "no model" state and reloadConfig triggers a full restart.
    private var isSetupComplete = false

    /// Set by WelcomeController's Configure button — opens Settings once setup finishes.
    public var openSettingsAfterSetup = false

    private var tutorialPopover: NSPopover?

    /// The effective engine id, honoring SPEAKFREE_ENGINE the same way EngineFactory does.
    /// Single source of truth so engine creation, model-id selection, and activeEngineID
    /// tracking can never disagree (e.g. building Parakeet but loading a whisper model size).
    private var effectiveEngineID: String {
        ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"] ?? config.engine ?? "whisper"
    }

    public func reloadConfig() {
        // In noModel state: only restart full setup if the user has now downloaded a model.
        // Without this check, opening Settings (which calls reloadConfig on save) would
        // re-trigger the welcome dialog even though the user deliberately skipped it.
        guard isSetupComplete else {
            let freshConfig = Config.load()
            let engineID = ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"]
                ?? freshConfig.engine ?? "whisper"
            let modelAvailable: Bool
            if engineID == "parakeet" {
                let modelID = freshConfig.parakeetModel ?? "parakeet-tdt-0.6b-v3"
                modelAvailable = ParakeetModelManager.shared.isModelDownloaded(modelID)
            } else {
                modelAvailable = Transcriber.modelExists(modelSize: freshConfig.modelSize)
                    || findAnyDownloadedModel() != nil
            }
            if modelAvailable {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.setup() }
            }
            return
        }

        config = Config.load()

        // Parakeet: no ggml-on-disk gate (FluidAudio downloads/validates its own cache).
        // Always rebuild the transcriber so an engine switch takes effect.
        if effectiveEngineID == "parakeet" {
            let modelID = config.parakeetModel ?? "parakeet-tdt-0.6b-v3"
            finishReloadConfig(modelID: modelID)
            return
        }

        var effectiveModelSize = config.modelSize
        if config.language != "en" && WhisperLanguage.isEnglishOnly(config.modelSize) {
            effectiveModelSize = WhisperLanguage.multilingualModel(for: config.modelSize)
            print("Language \(config.language) requires multilingual model — using \(effectiveModelSize)")
        }

        // If we're already on whisper and the model isn't on disk, keep running. But if we're
        // switching FROM parakeet TO whisper, rebuild regardless so the engine actually swaps.
        let switchingFromParakeet = activeEngineID != "whisper"
        if !switchingFromParakeet && !Transcriber.modelExists(modelSize: effectiveModelSize) {
            // Don't auto-download — keep the current transcriber running.
            // The settings UI shows the download prompt inline.
            print("Model \(effectiveModelSize) not on disk — keeping current model (\(activeModelSize))")
            // Still reload hotkey and other settings
            reloadHotkeyAndSettings()
            return
        }

        finishReloadConfig(modelID: effectiveModelSize)
    }

    private func finishReloadConfig(modelID: String) {
        // Capture the outgoing transcriber so its engine's cleanup runs before we drop it.
        // Without this, switching engine/model leaks the old engine's loaded model (ANE/Metal
        // residency) until ARC happens to release it — unload it deterministically instead.
        let old = transcriber

        let engine = EngineFactory.make(config: config)
        transcriber = Transcriber(engine: engine, modelID: modelID, language: config.language)
        activeEngineID = effectiveEngineID

        // Unload the previous engine off the main thread (async unload); ARC drops `old` after.
        if let old = old {
            Task { await old.unloadModel() }
        }
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

        // Configure model persistence
        transcriber.keepModelLoaded = config.keepModelLoaded ?? "auto"
        transcriber.startMemoryPressureMonitoring()
        warmUpEngine(effectiveEngineID)

        reloadHotkeyAndSettings()
        print("Config reloaded: hotkey=\(KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)) model=\(modelID) engine=\(effectiveEngineID)")
    }

    /// Warm up the Parakeet model in the background at launch / engine switch so the
    /// first dictation isn't a ~15-20s cold ANE load. Parakeet only (Whisper's cold
    /// load is fast and its memory profile differs); no-ops if assets aren't present.
    private func warmUpEngine(_ engineID: String) {
        guard engineID == "parakeet" else { return }
        let t = transcriber
        Task.detached(priority: .userInitiated) {
            let start = Date()
            await t?.warmUp()
            print("Parakeet warm-up finished in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
    }

    /// Reload hotkey, pre-buffer, and menu without changing the transcriber/model.
    private func reloadHotkeyAndSettings() {
        // Configure pre-buffer
        recorder.preBufferEnabled = config.preBuffer?.value ?? true

        // Update spoken punctuation on existing transcriber
        transcriber?.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

        hotkeyManager?.stop()
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )
        hotkeyManager?.start(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() },
            onAbort: { [weak self] in self?.handleRecordingAbort() }
        )

        statusBar.buildMenu()

        syncLocalAPIServerState()
    }

    /// Start or stop the LocalAPIServer based on the current config.
    /// Called from both `reloadHotkeyAndSettings` (settings-save path) and
    /// `startListening` (launch path) so the server comes up on launch when enabled.
    private func syncLocalAPIServerState() {
        let apiEnabled = config.localAPI?.value ?? false
        let apiPort = UInt16(config.localAPIPort ?? 5765)
        if apiEnabled, let t = transcriber {
            if localAPIServer == nil || localAPIServer?.port != apiPort {
                localAPIServer?.stop()
                localAPIServer = LocalAPIServer(port: apiPort)
            }
            localAPIServer?.start(transcriber: t,
                                  allowBrowser: config.localAPIAllowBrowser?.value ?? false,
                                  authToken: config.localAPIToken)
        } else {
            localAPIServer?.stop()
            localAPIServer = nil
        }
    }

    private func showTutorialPopoverIfNeeded() {
        let key = "speakfree.hasShownTutorial"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard let button = statusBar?.statusItem.button else { return }

        let vc = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 58))
        let label = NSTextField(wrappingLabelWithString:
            "Click here to access settings, updates, or quit SpeakFree.")
        label.font = NSFont.systemFont(ofSize: 13)
        label.isEditable = false; label.isBordered = false; label.backgroundColor = .clear
        label.frame = NSRect(x: 12, y: 9, width: 266, height: 40)
        view.addSubview(label)
        vc.view = view

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 290, height: 58)
        popover.behavior = .transient
        tutorialPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.tutorialPopover?.close()
            self?.tutorialPopover = nil
        }
    }

    public func showSettings() {
        if settingsViewModel == nil {
            settingsViewModel = SettingsViewModel()
            settingsViewModel?.onSave = { [weak self] in
                self?.reloadConfig()
            }
        }
        SettingsWindowController.show(viewModel: settingsViewModel!)
    }

    private func handleKeyDown() {
        guard isReady else { return }

        let isToggle = config.toggleMode?.value ?? false

        if isToggle {
            if isPressed {
                handleRecordingStop()
            } else {
                handleRecordingStart()
            }
        } else {
            guard !isPressed else { return }
            handleRecordingStart()
        }
    }

    private func handleKeyUp() {
        let isToggle = config.toggleMode?.value ?? false
        if isToggle { return }

        handleRecordingStop()
    }

    private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "speakfree needs Accessibility access to type your dictation.\n\nClick \"Open Settings\" below, then find speakfree in the list and turn it on. Come back here when done — it will start automatically."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "I'll Do It Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    private func captureFocusedElement() {
        // Run AX queries with a timeout — if the frontmost app is unresponsive,
        // AXUIElementCopyAttributeValue blocks indefinitely, stalling the main thread
        // and eventually causing macOS to disable our event tap.
        let semaphore = DispatchSemaphore(value: 0)
        var capturedElement: AXUIElement?
        var capturedContext: String?

        DispatchQueue.global(qos: .userInteractive).async {
            let systemWide = AXUIElementCreateSystemWide()
            var elementRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
            if result == .success, let element = elementRef {
                // swiftlint:disable:next force_cast
                let axElement = element as! AXUIElement
                capturedElement = axElement
                capturedContext = self.readTextBeforeCursor(in: axElement)
            }
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 0.5)
        if timeout == .timedOut {
            DiagnosticLogger.shared.log("captureFocusedElement: AX query timed out — skipping context")
        }
        recordingSourceElement = capturedElement
        recordingContextText = capturedContext
    }

    /// Reads up to 500 characters before the cursor without changing selection or focus.
    private func readTextBeforeCursor(in element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String, !fullText.isEmpty else { return nil }

        // Try to get cursor position from selected text range
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
            let cursorIndex = max(0, range.location)
            if cursorIndex > 0, let swiftIndex = fullText.index(fullText.startIndex, offsetBy: cursorIndex, limitedBy: fullText.endIndex) {
                let before = String(fullText[..<swiftIndex])
                // Take last 500 chars to stay within whisper's prompt limits
                return String(before.suffix(500))
            }
        }

        // No cursor info — use the last 500 chars of the whole field
        return String(fullText.suffix(500))
    }

    private func handleRecordingStart() {
        guard !isPressed else { return }
        isPressed = true

        // Verify all subsystems before every recording
        verifySubsystems(context: "pre-recording")

        // Detect style mode from frontmost app before menu bar steals focus
        recordingStyleMode = TextPostProcessor.detectStyleMode(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )

        // Capture focused element before anything else changes.
        // Skip for remote desktop — AX reads the Splashtop UI, not the remote text field.
        if !inserter.isRemoteDesktopFrontmost() {
            captureFocusedElement()
        } else {
            recordingSourceElement = nil
            recordingContextText = nil
        }

        // Capture screen context in background if enabled.
        // Skip for remote desktop apps — OCR captures the remote screen content
        // which whisper then parrots instead of transcribing speech.
        let isRemoteDesktop = inserter.isRemoteDesktopFrontmost()
        if config.screenContext?.value == true && !isRemoteDesktop {
            // Bump generation so any in-flight OCR from a previous recording is discarded.
            let capturedGeneration = UUID()
            screenCaptureGeneration = capturedGeneration
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let text = ScreenContext.captureAndRecognize()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.screenCaptureGeneration == capturedGeneration else { return }
                    self.screenContextText = text
                }
            }
        }

        statusBar.state = .recording
        recordingOverlay.show(state: .recording, recorder: recorder)
        do {
            // Always write to recordings dir — crash recovery works regardless of maxRecordings
            let outputURL = RecordingStore.newRecordingURL()
            RecordingStore.writeSentinel(recordingURL: outputURL)
            try recorder.startRecording(to: outputURL)

            // Start streaming transcription timer — processes audio every 2s for live preview
            startStreamingTimer()
        } catch {
            print("Error: \(error.localizedDescription)")
            RecordingStore.clearSentinel()
            isPressed = false
            recordingSourceElement = nil
            statusBar.state = .idle
            recordingOverlay.hide()
        }
    }

    /// A real key was pressed while fn was held — this is a keyboard shortcut, not dictation.
    /// Cancel recording silently and let the shortcut pass through.
    private func handleRecordingAbort() {
        guard isPressed else { return }
        isPressed = false

        stopStreamingTimer()

        if let result = recorder.stopRecording() {
            try? FileManager.default.removeItem(at: result.url)
        }
        RecordingStore.clearSentinel()
        recordingSourceElement = nil
        recordingContextText = nil
        screenContextText = nil
        screenCaptureGeneration = UUID()  // invalidate any in-flight OCR
        statusBar.state = .idle
        recordingOverlay.hide()
        statusBar.buildMenu()
    }

    private func handleRecordingStop() {
        guard isPressed else { return }
        isPressed = false

        // Stop streaming timer and clear streaming state
        stopStreamingTimer()

        // Capture key-release time NOW — finalizeRecording runs up to 300ms later, so
        // measuring inside it would undercount the post-buffer delay in the latency log.
        let keyReleaseTime = CFAbsoluteTimeGetCurrent()

        // T2.1 — Adaptive post-buffer. We still keep recording AFTER key release so the tail of
        // the last word (an AVAudioEngine buffer releasing mid-word loses its tail) isn't clipped.
        // But instead of a FLAT 300ms tax on every dictation, we poll the trailing audio's RMS and
        // finalize as soon as ~150ms of trailing silence is observed — hard-capped at 300ms so we
        // are NEVER worse than the old flat wait. The wait DECISION is the pure PostBufferPolicy
        // (unit-tested over RMS windows); this loop only feeds it the live trailing samples.
        let samplesAtRelease = recorder.currentSamples().count
        runAdaptivePostBuffer(samplesAtRelease: samplesAtRelease) { [weak self] in
            self?.finalizeRecording(keyReleaseTime: keyReleaseTime)
        }
    }

    /// Poll the recorder's trailing audio on a short timer; once `PostBufferPolicy.decideWaitMs`
    /// says enough contiguous trailing silence has accrued (or the 300ms cap is hit), invoke
    /// `finalize` on the main queue. `samplesAtRelease` marks the sample count at key-release so
    /// only audio captured AFTER the key lifted is scored as "trailing". The decision is the pure
    /// policy; this only feeds it the live trailing samples.
    private func runAdaptivePostBuffer(samplesAtRelease: Int, finalize: @escaping () -> Void) {
        let windowMs = postBufferWindowMs
        let capMs = PostBufferPolicy.defaultCapMs
        let startTick = CFAbsoluteTimeGetCurrent()

        postBufferTimer?.invalidate()
        postBufferTimer = Timer.scheduledTimer(withTimeInterval: windowMs / 1000.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTick) * 1000.0
            let all = self.recorder.currentSamples()
            let trailing = all.count > samplesAtRelease ? Array(all[samplesAtRelease...]) : []
            // Ask the pure policy how long it wants given the trailing audio seen so far.
            let decided = PostBufferPolicy.decideWaitMs(trailingSamples: trailing, windowMs: windowMs)

            // Stop once we've waited at least the policy's decision, or we hit the hard cap.
            if elapsedMs >= decided || elapsedMs >= capMs {
                timer.invalidate()
                self.postBufferTimer = nil
                finalize()
            }
        }
    }

    private func finalizeRecording(keyReleaseTime: Double = CFAbsoluteTimeGetCurrent()) {
        let stopTime = keyReleaseTime

        guard let recording = recorder.stopRecording() else {
            RecordingStore.clearSentinel()
            recordingSourceElement = nil
            statusBar.state = .idle
            recordingOverlay.hide()
            return
        }
        let audioURL = recording.url
        let samples = recording.samples

        // Skip transcription for very short recordings (<300ms) — likely an accidental tap
        let minSamples = 4800  // 300ms at 16kHz
        if samples.count < minSamples {
            print("Recording too short (\(samples.count) samples / \(Int(Double(samples.count) / 16000.0 * 1000))ms) — skipping")
            RecordingStore.clearSentinel()
            recordingSourceElement = nil
            recordingContextText = nil
            statusBar.state = .idle
            recordingOverlay.hide()
            return
        }

        // Check for dead audio (all silence) — engine may have died mid-recording
        let rms = sqrtf(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        if rms < 0.0001 {
            DiagnosticLogger.shared.log("Recording was silent (RMS \(rms)) — audio engine may be dead, rebuilding")
            recorder.ensureAudioHealthy()
            RecordingStore.clearSentinel()
            recordingSourceElement = nil
            recordingContextText = nil
            statusBar.state = .idle
            recordingOverlay.hide()
            return
        }

        statusBar.state = .transcribing
        recordingOverlay.update(state: .transcribing)

        let capturedElement = recordingSourceElement
        let capturedInputText = recordingContextText
        let capturedScreenText = screenContextText
        screenContextText = nil
        screenCaptureGeneration = UUID()  // invalidate any late-arriving OCR
        recordingSourceElement = nil
        recordingContextText = nil

        // T2.2 — Precompute shouldPrependSpace NOW, on main, from the cursor-context string
        // that was already captured at record-start (off main, inside captureFocusedElement).
        // The last character of capturedInputText IS the character immediately before the cursor,
        // so no further AX query is needed. This eliminates the 300ms semaphore.wait that
        // previously blocked the main thread at insert time.
        //
        // Tradeoff: the value reflects the focused element at RECORD-START. If focus changes
        // mid-dictation the answer may be stale — but we refocus that same element anyway, so
        // the element and the precomputed context always agree.
        let capturedPrependSpace = TextInserter.shouldPrependSpace(contextBefore: capturedInputText)

        // Snapshot ALL config-derived state on main before crossing into the async Task.
        // Accessing self.config.* from a background queue is a torn-read race — Config is a
        // struct so reads and writes are not atomic across threads.
        let maxRecordings = (config.preserveAllRecordings?.value ?? false) ? 0 : Config.effectiveMaxRecordings(config.maxRecordings)
        let mode = config.spokenPunctuation ?? .off
        let glossary = Config.loadVocabulary()
        let overrides = Config.loadOverrides()
        let capturedStyleMode = recordingStyleMode
        // Provenance snapshot for the .meta.json sidecar — engine/model from the ACTIVE
        // transcriber (not config, which can disagree after a model fallback).
        let metaEngine = activeEngineID
        let metaDevice = AudioRecorder.defaultInputDeviceName()

        // Snapshot the transcriber on main BEFORE crossing into the async Task. A settings
        // change mid-finalize (reloadConfig) can swap self.transcriber out from under us; the
        // snapshot guarantees this recording's audio runs through the engine that was active
        // when the user spoke, not a freshly-swapped one.
        guard let transcriber = self.transcriber else {
            RecordingStore.clearSentinel()
            statusBar.state = .idle
            recordingOverlay.hide()
            return
        }

        // T2.3 — decide (on main, all state read here) whether to reuse the last streaming partial
        // instead of running a fresh final inference. The gate (flag + freshness + growth) is the
        // pure StreamingReuse type.
        //
        // DEFAULT OFF (AR-2 finding #2): the T2.3-PRE measurement that originally authorized
        // default-ON only varied THREAD COUNT on 2–3 s hallucination slices ("(upbeat music)",
        // empty strings) and reported 0.000% divergence — agreement on noise, not signal. It never
        // measured the axis production actually swaps: a `prompt:nil`, NON-VAD-trimmed streaming
        // partial (transcribeStreaming, AppDelegate path) replacing a glossary/screen/cursor-context
        // -primed, VAD-trimmed FINAL pass (transcribe, prompt: prompt below). Re-measured on the FULL
        // real-speech fixtures that axis diverges ~5% (>5× the locked <1% gate). So reuse is OFF by
        // default until a valid prompt-axis measurement clears the gate; the flag remains for
        // opt-in/experiments. When the gate declines, `reuseDecision` is `.runFinalInference` and the
        // path below is byte-identical to pre-T2.3.
        let reuseDecision = StreamingReuse.decide(StreamingReuse.State(
            flagEnabled: config.reuseStreamingPartial?.value ?? false,
            lastRawPartial: lastStreamingRawPartial,
            lastStreamedSampleCount: lastStreamingSampleCount,
            lastStreamCompletedAt: lastStreamingCompletedAt,
            sampleCountAtRelease: samples.count,
            keyReleaseAt: keyReleaseTime
        ))

        // Bridge into async: the transcribe pipeline is now async/await (FluidAudio is
        // async-only; WhisperEngine exposes async shims). The engines serialize access to
        // their own context internally, so we no longer need whisperSerialQueue to gate the
        // final pass. Results are still marshalled back to main via DispatchQueue.main.async.
        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Build Whisper prompt + run post-processing through the shared
                // TextPipeline core. Extracting this out of an inline closure is
                // what lets unit tests cover the same code path the app uses,
                // preventing the kind of drift that shipped the v1.2.11 comma loop.

                // Build prompt context once before whisper runs; pass the precomputed
                // prompt into TextPipeline.run so assemblePromptHints is called only once
                // per recording. The makeInput closure captures context for the run call.
                let pipelineContext = TextPipeline.Input(
                    punctuationMode: mode,
                    cursorContextText: capturedInputText,
                    screenContextText: capturedScreenText,
                    styleMode: capturedStyleMode,
                    glossaryWords: glossary
                )
                let prompt = TextPipeline.assemblePromptHints(input: pipelineContext)
                let makeInput: (String) -> TextPipeline.Input = { raw in
                    TextPipeline.Input(
                        raw: raw,
                        punctuationMode: mode,
                        cursorContextText: capturedInputText,
                        screenContextText: capturedScreenText,
                        styleMode: capturedStyleMode,
                        glossaryWords: glossary,
                        overrides: overrides
                    )
                }
                // T2.3 — reuse the saved streaming partial when the gate approved, else run the
                // final inference. Either way the raw text flows through the SAME TextPipeline
                // post-processing below, so the only difference is whether whisper_full ran again.
                let raw: String
                switch reuseDecision {
                case .reusePartial(let rawPartial):
                    // The streaming partial is RAW collectSegments output; unlike the final pass it
                    // has NOT had its multi-segment acoustic `\n` collapsed. Apply the IDENTICAL
                    // collapse the final path uses so an unspoken segment split can never reach
                    // TextInserter as a line-break `.shiftReturn` (Newline Policy 2b / Option B).
                    raw = TextPipeline.collapseSegmentNewlines(rawPartial)
                    DiagnosticLogger.shared.log("T2.3: reused last streaming partial (skipped final inference)")
                case .runFinalInference:
                    raw = try await transcriber.transcribe(audioURL: audioURL, samples: samples, prompt: prompt)
                }
                RecordingStore.saveRaw(text: raw, for: audioURL)
                let text = TextPipeline.run(makeInput(raw), precomputedPrompt: .some(prompt)).finalText
                RecordingStore.saveTranscription(text: text, for: audioURL)
                RecordingStore.saveMeta(RecordingStore.RecordingMeta(
                    appVersion: SpeakFree.version,
                    engine: metaEngine,
                    model: transcriber.modelID,
                    inputDevice: metaDevice,
                    date: ISO8601DateFormatter().string(from: Date()),
                    durationSeconds: Double(samples.count) / 16000.0,
                    transcriptChars: text.count
                ), for: audioURL)

                RecordingStore.clearSentinel()
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }

                DispatchQueue.main.async {
                    self.recordingOverlay.hide()
                    if !text.isEmpty {
                        // T2.2: use the prepend-space decision precomputed at record-start (off
                        // main). No AX query, no semaphore.wait — zero main-thread stall here.
                        let insertText = capturedPrependSpace ? " " + text : text
                        self.lastTranscription = text
                        // Record usage stats
                        let audioSeconds = Double(samples.count) / 16000.0
                        UsageStats.shared.recordDictation(characters: text.count, audioSeconds: audioSeconds)
                        // Secure-Input fallback notification (audit M2): if the insertion falls back
                        // because Secure Input is active (e.g. a password field), show a distinct
                        // "auto-clears" notification so the user knows the clipboard is self-cleaning.
                        self.inserter.onSecureInputFallback = {
                            self.statusBar.state = .secureInputCopied
                            self.statusBar.buildMenu()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.statusBar.state = .idle
                                self.statusBar.buildMenu()
                            }
                        }
                        let pasted = self.inserter.insert(text: insertText, refocusing: capturedElement, onFocusLost: {
                            // Only update state if it wasn't already set by onSecureInputFallback.
                            if self.statusBar.state != .secureInputCopied {
                                self.statusBar.state = .copiedToClipboard
                                self.statusBar.buildMenu()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    self.statusBar.state = .idle
                                    self.statusBar.buildMenu()
                                }
                            }
                        })
                        if pasted {
                            let elapsed = CFAbsoluteTimeGetCurrent() - stopTime
                            DiagnosticLogger.shared.log("Transcription complete: \(String(format: "%.2f", elapsed))s from key-release to text-inserted, \(text.count) chars")
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    } else {
                        self.statusBar.state = .idle
                        self.statusBar.buildMenu()
                    }
                }
            } catch {
                RecordingStore.clearSentinel()
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                // Detect a missing engine model (e.g. Parakeet never downloaded) and surface a
                // clear, actionable message instead of a generic failure. Either way the status
                // must not stay stuck on .transcribing.
                let isModelMissing: Bool
                if case TranscriptionEngineError.modelAssetsMissing = error {
                    isModelMissing = true
                } else {
                    isModelMissing = false
                }
                DispatchQueue.main.async {
                    self.recordingOverlay.hide()
                    if isModelMissing {
                        let message = "Parakeet model not downloaded — open Settings to download."
                        print("Error: \(message)")
                        DiagnosticLogger.shared.log(message)
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "Model Not Downloaded"
                        alert.informativeText = message
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Open Settings")
                        alert.addButton(withTitle: "Later")
                        if alert.runModal() == .alertFirstButtonReturn {
                            self.showSettings()
                        }
                    } else {
                        print("Error: Transcription failed")
                    }
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
        }
    }

    // MARK: - Streaming Transcription

    private func startStreamingTimer() {
        guard config.streamingEnabled?.value ?? true else { return }
        // Gate on the transcriber's engine-agnostic passthroughs. Engines that don't support
        // live preview (parakeet v1) report supportsStreaming == false and are skipped here.
        guard transcriber.supportsStreaming, transcriber.isLoaded else { return }
        streamingText = ""
        streamingAssembler.reset()
        isStreamingInFlight = false
        resetStreamingReuseState()  // T2.3: no partial to reuse until the first pass completes
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.processStreamingChunk()
        }
        DiagnosticLogger.shared.log("Streaming: timer started (2.0s interval)")
    }

    private func stopStreamingTimer() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingText = ""
        streamingAssembler.reset()
        isStreamingInFlight = false
        streamingGeneration &+= 1  // invalidate any in-flight partial-result callbacks
        // NOTE: lastStreamingRawPartial/SampleCount/CompletedAt are intentionally NOT cleared here.
        // handleRecordingStop() calls stopStreamingTimer() BEFORE finalizeRecording reads the reuse
        // state, so clearing here would always defeat the reuse path. They are reset in
        // startStreamingTimer() (next recording) instead.
        recordingOverlay.clearStreamingText()
    }

    private func processStreamingChunk() {
        guard isPressed, !isStreamingInFlight else { return }

        let currentSamples = recorder.currentSamples()
        // Need at least 1 second of audio for meaningful transcription
        guard currentSamples.count > 16000 else { return }

        isStreamingInFlight = true

        // T2.3 — remember the sample count this streaming pass runs over so finalizeRecording can
        // measure how much the recording grew since (the reuse growth-gate).
        let streamedSampleCount = currentSamples.count

        let language = config.language

        // Snapshot the transcriber on main BEFORE crossing into the async Task (mirrors the
        // finalizeRecording fix). A mid-stream engine swap (reloadConfig) can replace
        // self.transcriber; the snapshot guarantees this partial runs through the engine that
        // was active when the chunk was captured, not a freshly-swapped one.
        guard let transcriber = self.transcriber else {
            isStreamingInFlight = false
            return
        }
        let suppressRegex = transcriber.suppressAutoPunctuation ? "[,\\.\\?!;:\\-—]" : nil

        let generation = streamingGeneration
        // Bridge into async: streaming now routes through the Transcriber passthrough (no longer
        // reaches into transcriber.engine.*). Engines serialize their own context internally.
        Task { [weak self] in
            guard let self = self else { return }
            // Re-check: user may have released hotkey while we waited to start
            guard self.isPressed else {
                DispatchQueue.main.async { self.isStreamingInFlight = false }
                return
            }
            do {
                let partial = try await transcriber.transcribeStreaming(
                    samples: currentSamples,
                    language: language,
                    prompt: nil,
                    suppressRegex: suppressRegex,
                    onPartialResult: { [weak self, generation] text in
                        guard let self = self, self.streamingGeneration == generation else { return }
                        // Strip Whisper hallucination markers so they don't appear in the
                        // streaming overlay — the finalize path goes through TextPipeline,
                        // but the preview path calls the engine directly.
                        let cleaned = TextPipeline.stripWhisperBracketMarkers(text)
                        let displayText = self.buildStableDisplayText(from: cleaned)
                        self.recordingOverlay.updateStreamingText(displayText)
                    }
                )
                self.streamingText = partial

                // Commit completed sentences so they won't change on next inference
                let displayText = self.buildStableDisplayText(from: partial)

                DispatchQueue.main.async {
                    self.recordingOverlay.updateStreamingText(displayText)
                    self.isStreamingInFlight = false
                    // T2.3 — record THIS completed pass (raw partial + samples it saw + when it
                    // finished) so a fast key-release can reuse it instead of a fresh final pass.
                    // Guard on generation: a stop that already bumped the generation must not have
                    // its (now-stale) partial revived by a late-arriving completion.
                    if self.streamingGeneration == generation {
                        self.lastStreamingRawPartial = partial
                        self.lastStreamingSampleCount = streamedSampleCount
                        self.lastStreamingCompletedAt = CFAbsoluteTimeGetCurrent()
                    }
                }
            } catch {
                DiagnosticLogger.shared.log("Streaming: chunk failed — \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isStreamingInFlight = false
                }
            }
        }
    }

    /// Build stable display text: committed sentences are frozen, new content is appended.
    /// Each sentence starts on a new line so existing lines don't reflow.
    private func buildStableDisplayText(from rawText: String) -> String {
        return streamingAssembler.append(rawText)
    }

    /// T2.3 — clear the saved last-streaming-pass state (called at streaming START so a new
    /// recording can't reuse the previous recording's partial).
    private func resetStreamingReuseState() {
        lastStreamingRawPartial = ""
        lastStreamingSampleCount = 0
        lastStreamingCompletedAt = 0
    }

    public func reprocess(audioURL: URL) {
        guard statusBar.state == .idle else { return }

        // Read saved transcription text — no need to re-transcribe
        let textURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        guard let text = try? String(contentsOf: textURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Reprocess: no saved transcription for \(audioURL.lastPathComponent)")
            return
        }

        // Copy to clipboard — the menu stole focus from the user's app,
        // so direct insertion via AX won't work reliably. Clipboard is the safest path.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        lastTranscription = text

        statusBar.state = .copiedToClipboard
        statusBar.buildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusBar.state = .idle
            self?.statusBar.buildMenu()
        }
    }

    /// Find the LARGEST downloaded whisper model on disk, returning the model size
    /// string (e.g. "base.en"). Largest-by-file-size, never directory order — used
    /// only as an availability check; model selection itself never silently
    /// substitutes (see the no-silent-fallback rule in setupInner).
    private func findAnyDownloadedModel() -> String? {
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(atPath: modelsDir.path))?
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .max(by: { a, b in
                let sizeA = (try? fm.attributesOfItem(atPath: modelsDir.appendingPathComponent(a).path))?[.size] as? Int ?? 0
                let sizeB = (try? fm.attributesOfItem(atPath: modelsDir.appendingPathComponent(b).path))?[.size] as? Int ?? 0
                return sizeA < sizeB
            })
            .map { String($0.dropFirst(5).dropLast(4)) }  // "ggml-base.en.bin" → "base.en"
    }
}
