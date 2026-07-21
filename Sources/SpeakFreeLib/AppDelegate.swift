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

    // Sparkle auto-updater — checks for updates on launch and periodically.
    // Constructed lazily and STARTED only from setupInner (the production launch
    // path), never at AppDelegate construction: with `startingUpdater: true` the
    // updater came alive inside xctest whenever a test built an AppDelegate, and
    // Sparkle's scheduled update-check prompts/errors are real modal NSAlerts on
    // the main queue — any test that then spins the run loop deadlocks forever.
    // That was the whole-suite stall found by the 2026-07-01 audit (and it is
    // time/defaults-dependent, which is why the suite was green on 06-10 and hung
    // on 07-01 with no code change). Tests route setup through _setupExecutor and
    // never reach setupInner, so the updater now stays dormant under test.
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    // R1: focus capture (the AXUIElement focused at record-start, used to refocus before
    // pasting, plus the cursor-context text passed to whisper as a prompt). The AX read now
    // runs OFF-MAIN so record-start never blocks on an unresponsive frontmost app's AX tree:
    // `begin()` at record-start, the background reader `publish`es when it lands, and
    // finalize `consume(waitingUpTo:)`s it (waiting briefly only if still in flight — never
    // on the start path; nil on timeout, exactly the old AX-timeout semantics).
    private let focusCapture = FocusCaptureBox<(AXUIElement?, String?)>()
    // Screen OCR text captured at recording start (opt-in). Written only on main via
    // generation-token check, so no lock needed.
    private var screenContextText: String?
    // Generation token: bumped at recording start AND end/cancel. The OCR background task
    // captures the UUID at dispatch time and writes back only if the token still matches,
    // discarding stale results from previous recordings.
    private var screenCaptureGeneration: UUID = UUID()
    // Last time the transcription-failure alert was shown; a persistently broken engine
    // fails every attempt, and the modal is throttled to one per 5 minutes (main-only).
    private var lastTranscriptionFailureAlert: Date?
    // Recordings apology notice (2026-07-14): retained while showing; the timer re-shows
    // it every few hours until the user decides keep/delete. Main-only.
    private var recordingsNoticeController: RecordingsNoticeController?
    private var recordingsNoticeTimer: Timer?
    // Graceful SIGTERM (2026-07-14): a reinstall/kill must never eat an in-flight
    // dictation. The source is retained for process lifetime.
    private var sigtermSource: DispatchSourceSignal?
    // Tail of the last successful insertion (2026-07-15): feeds the cursor-context
    // fallback for AX-opaque editors. Main-only.
    private var lastInsertionTail: String?
    private var lastInsertionBundleID: String?
    private var lastInsertionAt: Date?
    private var lastInsertionElement: AXUIElement?
    private var lastInsertionInteractionGeneration: UInt64?
    private let userInteractionGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))
    // L1: a config reload that lands while a dictation is in flight (fn held) must NOT mutate live
    // dictation state — it would (a) rebuild the HotkeyManager mid-press (recreating the event tap
    // loses the pending key-release, so the recording never stops and the next utterance merges
    // in), (b) swap the transcriber, finalizing THIS utterance on the wrong engine, and (c) flip
    // config.toggleMode so a Hold→Toggle switch mid-press makes handleKeyUp return early and strand
    // the running recording. So the ENTIRE reloadConfig is deferred by setting this flag; it is
    // re-run in full the moment the dictation ends (finalize / key-up / abort). The old
    // pendingHotkeyReload folded into this — the hotkey rebuild happens inside the deferred
    // reloadConfig, same as when not pressed. Main-only.
    private var pendingConfigReload = false

    // Adaptive post-buffer (T2.1): poll trailing audio after key release and finalize as soon as
    // ~150ms of trailing silence is observed, hard-capped at 300ms (never worse than the old flat
    // wait). The decision itself lives in the pure PostBufferPolicy; this timer only feeds it RMS
    // windows from the live recorder.
    private var postBufferTimer: Timer?
    /// Window cadence the post-buffer poll uses (matches PostBufferPolicy's default window grain).
    private let postBufferWindowMs: Double = 30.0

    // Streaming transcription: periodic inference during recording
    private var streamingTimer: Timer?
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
        // Cap ALL AX messaging process-wide at 0.5 s. The AX default is an INDEFINITE block
        // when the target app is hung — set once on the system-wide element so no AX call
        // anywhere (insert path, RecordingOverlay, menu focus queries) can stall us into a
        // beachball waiting on an unresponsive frontmost app (AX-A).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        statusBar = StatusBarController()
        recorder = AudioRecorder()
        inserter = TextInserter()
        installGracefulTermination()

        // Device catalog cache: the ONLY CoreAudio the main thread ever sees. Refreshes
        // off-main at launch and on device changes; the menu rebuilds from the cache.
        AudioDeviceCatalog.onCacheRefreshed = { [weak self] in self?.statusBar.buildMenu() }
        AudioDeviceCatalog.startCache()

        // Multi-device AirPods contention: the detector throttles itself (max one
        // notice per hour) — surface it visibly when it fires.
        recorder.onContention = { message in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "AirPods Interference Detected"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

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

    // MARK: Legacy Parakeet model resolution (audit 2026-07-01, Michael's call)

    /// Test seam for the legacy model prompt — receives whether v3 is already on
    /// disk, returns the chosen model id. nil = show the real NSAlert.
    var _legacyModelPrompter: ((_ v3Downloaded: Bool) -> String)?

    /// Configs written before Parakeet-first onboarding can have engine=parakeet
    /// with no `parakeetModel` key. The old `?? v3` fallback silently steered
    /// those users to the multilingual model while the product default moved to
    /// v2 (faster English). Instead of silently picking either, ask ONCE at
    /// launch and persist the answer, so the config always carries an explicit
    /// choice afterwards.
    func resolveLegacyParakeetModel() -> String {  // internal for tests (seam: _legacyModelPrompter)
        if let explicit = config.parakeetModel { return explicit }
        let v3Downloaded = ParakeetModelManager.shared.isModelDownloaded("parakeet-tdt-0.6b-v3")
        let chosen = _legacyModelPrompter?(v3Downloaded)
            ?? Self.promptLegacyParakeetChoice(v3Downloaded: v3Downloaded)
        config.parakeetModel = chosen
        try? config.save()
        DiagnosticLogger.shared.log(
            "Legacy Parakeet config had no model choice — user chose \(chosen) (v3 on disk: \(v3Downloaded))")
        return chosen
    }

    /// Blocking one-time choice dialog. Runs on main (setup calls this off-main);
    /// the default button favors not surprising the user: keep multilingual if
    /// it's already installed and in use, recommend English v2 otherwise.
    private static func promptLegacyParakeetChoice(v3Downloaded: Bool) -> String {
        var choice = Config.defaultParakeetModel
        let present = {
            let alert = NSAlert()
            alert.messageText = "Choose your dictation model"
            alert.alertStyle = .informational
            if v3Downloaded {
                alert.informativeText = """
                speakfree now uses a faster English-only model by default. \
                You currently have the multilingual model installed.

                Keep multilingual, or switch to the faster English model? \
                Switching downloads about 600 MB. You can change this anytime in Settings.
                """
                alert.addButton(withTitle: "Keep Multilingual")
                alert.addButton(withTitle: "Switch to English (Faster)")
                choice = alert.runModal() == .alertFirstButtonReturn
                    ? "parakeet-tdt-0.6b-v3" : "parakeet-tdt-0.6b-v2"
            } else {
                alert.informativeText = """
                speakfree now uses a faster English-only model by default.

                Use English (recommended), or the multilingual model if you \
                dictate in other languages? You can change this anytime in Settings.
                """
                alert.addButton(withTitle: "English (Recommended)")
                alert.addButton(withTitle: "Multilingual")
                choice = alert.runModal() == .alertFirstButtonReturn
                    ? "parakeet-tdt-0.6b-v2" : "parakeet-tdt-0.6b-v3"
            }
        }
        if Thread.isMainThread { present() } else { DispatchQueue.main.sync(execute: present) }
        return choice
    }

    private func setupInner() throws {
        DiagnosticLogger.shared.setup()
        DiagnosticLogger.shared.log("Setup started")
        config = Config.load()

        // Start Sparkle from the real launch path only (see updaterController's
        // comment — starting it at construction deadlocked the test suite).
        // setupInner runs off-main; the updater expects a main-thread start.
        // Bundle-gated: the bare CLI binary has no Info.plist, so Sparkle cannot
        // initialize there and throws an "Unable to Check For Updates" alert at launch.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            DispatchQueue.main.async { [weak self] in
                self?.updaterController.startUpdater()
            }
        }

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

        // Recordings apology notice (2026-07-14): saving shipped on-by-default through
        // v1.7.1; the notice lets users keep or delete what accumulated. Returns every
        // launch (and every few hours, below) until resolved. Dev machines are exempt —
        // the corpus there is intentional.
        switch DevMode.isActive
            ? RecordingsNotice.LaunchAction.nothing
            : RecordingsNotice.launchAction(decision: config.recordingsNoticeDecision,
                                            hasRecordings: RecordingStore.hasAudioFiles()) {
        case .markNotApplicable:
            var updated = Config.load()
            updated.recordingsNoticeDecision = "none-found"
            try? updated.save()
        case .show:
            DispatchQueue.main.async { [weak self] in self?.showRecordingsNotice() }
        case .nothing:
            break
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
            modelID = resolveLegacyParakeetModel()
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
            // Present the onboarding modal via the main RUN LOOP, NOT DispatchQueue.main.sync.
            // WelcomeController.show() runs NSApp.runModal; its nested run loop must keep draining the
            // main dispatch queue so the Parakeet download's progress callbacks AND its post-download
            // MainActor hops (finalize, compileAndCache, markDownloaded) can run. Launching the modal
            // from a main-queue dispatch block makes libdispatch treat the main queue as mid-drain and
            // starves every other main-queue block for the modal's whole lifetime: the ~600 MB model
            // downloads to disk, but the UI freezes at 0% and the install never finishes (the Task
            // hangs at the first `await MainActor.run`). CFRunLoopPerformBlock runs as a run-loop
            // activity, not a dispatch item, so the nested modal loop drains the main queue normally.
            let presentWelcome = {
                let result = WelcomeController.show(suggestedEngine: engineID, suggestedModel: modelID)
                selectedEngine = result.engine
                selectedModel = result.modelID
                selectedLanguage = result.language
                didProceed = result.shouldContinue
            }
            if Thread.isMainThread {
                presentWelcome()
            } else {
                let welcomeDone = DispatchSemaphore(value: 0)
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    presentWelcome()
                    welcomeDone.signal()
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                welcomeDone.wait()
            }
            guard didProceed else {
                DispatchQueue.main.async {
                    self.statusBar.state = .noModel
                    self.statusBar.buildMenu()
                }
                return
            }
            // Proceeding out of the needsDownload path means a model was just downloaded — flag it so
            // the re-run of setup() ends on the green `.ready` icon (see startListening()).
            justDownloadedModel = true
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

        // Apply routing BEFORE enabling pre-buffer. Assigning preBufferEnabled=true
        // starts the engine immediately; doing that first briefly opens the system
        // default route and then races the route-triggered rebuild at launch.
        recorder.dualCaptureEnabled = config.dualMicCapture?.value ?? false
        recorder.setPinnedInputDevice(uid: config.inputDeviceUID)
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
            },
            onUserInteraction: { [weak self] in
                self?.noteUserInteraction()
            }
        )

        isReady = true
        // After a fresh model download, show the green "ready" icon as a "you're all set" cue until
        // the first dictation clears it (handleKeyDown → .recording). Normal launches stay idle.
        if justDownloadedModel {
            justDownloadedModel = false
            statusBar.state = .ready
        } else {
            statusBar.state = .idle
        }
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

    /// True when onboarding just downloaded a model this launch. Consumed by startListening() to show
    /// the green `.ready` icon until the first dictation; reset once shown.
    private var justDownloadedModel = false

    private var tutorialPopover: NSPopover?

    /// The effective engine id, honoring SPEAKFREE_ENGINE the same way EngineFactory does.
    /// Single source of truth so engine creation, model-id selection, and activeEngineID
    /// tracking can never disagree (e.g. building Parakeet but loading a whisper model size).
    private var effectiveEngineID: String {
        ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"] ?? config.engine ?? "whisper"
    }

    /// Decision for reloadConfig's Parakeet branch (UI-B). Settings saves the config the instant a
    /// Parakeet model is picked (EnginePickerView `.onChange` → save → reloadConfig), which can name
    /// a model that hasn't been downloaded yet (the inline Download button is tapped afterward).
    /// Swapping the live transcriber onto an undownloaded model would leave the hotkey active on an
    /// engine that can't transcribe. So rebuild only when the model is actually on disk; otherwise
    /// keep the current transcriber running. Pure so the guard is unit-testable.
    enum ParakeetReloadDecision: Equatable {
        case rebuild(modelID: String)
        case keepCurrent
    }

    static func parakeetReloadDecision(modelID: String, isModelDownloaded: Bool) -> ParakeetReloadDecision {
        isModelDownloaded ? .rebuild(modelID: modelID) : .keepCurrent
    }

    public func reloadConfig() {
        // L1: never mutate live dictation state mid-utterance. If fn is held (a dictation is in
        // flight), defer the ENTIRE reload — not just the hotkey rebuild — because it also swaps
        // the transcriber (this utterance would finalize on the wrong engine) and flips
        // config.toggleMode (a Hold→Toggle switch while held makes handleKeyUp return early and
        // never stops the recording). Set the flag and bail; every dictation-end path re-runs the
        // full reload once (performPendingConfigReloadIfNeeded), reloading fresh Config.load()
        // state from disk. This is reached from settings save, notice callbacks, and mic select —
        // all correctly get the same defer-if-pressed semantics.
        if isPressed {
            pendingConfigReload = true
            DiagnosticLogger.shared.log("Config: reload deferred — dictation in flight")
            return
        }

        // In noModel state: only restart full setup if the user has now downloaded a model.
        // Without this check, opening Settings (which calls reloadConfig on save) would
        // re-trigger the welcome dialog even though the user deliberately skipped it.
        guard isSetupComplete else {
            let freshConfig = Config.load()
            let engineID = ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"]
                ?? freshConfig.engine ?? "whisper"
            let modelAvailable: Bool
            if engineID == "parakeet" {
                // nil model here = legacy config that hasn't been through the launch
                // prompt yet (resolveLegacyParakeetModel). Keep the historical v3
                // fallback for this transient window — silently flipping a legacy
                // v3 user to v2 mid-session would be a surprise model change.
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
            // Same transient-window fallback as above — see resolveLegacyParakeetModel.
            let modelID = config.parakeetModel ?? "parakeet-tdt-0.6b-v3"
            switch Self.parakeetReloadDecision(
                modelID: modelID,
                isModelDownloaded: ParakeetModelManager.shared.isModelDownloaded(modelID)) {
            case .rebuild(let id):
                finishReloadConfig(modelID: id)
            case .keepCurrent:
                // Model not downloaded yet — keep the current transcriber usable rather than
                // swapping the hotkey onto an engine that can't transcribe. The Settings
                // Parakeet download banner drives the fetch; a later save rebuilds onto it.
                print("Parakeet model \(modelID) not downloaded — keeping current engine (\(activeEngineID))")
                reloadHotkeyAndSettings()
            }
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

    // MARK: - Graceful termination (2026-07-14)

    /// SIGTERM (pkill, reinstall scripts, logout) waits for an in-flight dictation to
    /// finish — and for 10 s of quiet after it — before exiting, instead of cutting the
    /// user off mid-sentence. SIGKILL is unaffected (nothing can be).
    func installGracefulTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { NSApp.terminate(nil); return }
            let busy = self.statusBar.state == .recording || self.statusBar.state == .transcribing
            if !busy {
                NSApp.terminate(nil)
                return
            }
            DiagnosticLogger.shared.log("SIGTERM: dictation in flight — waiting to exit")
            self.terminateAfterQuiet(consecutiveIdle: 0,
                                     deadline: Date().addingTimeInterval(5 * 60))
        }
        source.resume()
        sigtermSource = source
    }

    /// Poll every 0.5 s; require 10 s of continuous idle (no recording/transcribing)
    /// before terminating. Hard deadline so a stuck state can't make the app unkillable.
    private func terminateAfterQuiet(consecutiveIdle: Int, deadline: Date) {
        let busy = statusBar.state == .recording || statusBar.state == .transcribing
        let idleCount = busy ? 0 : consecutiveIdle + 1
        if idleCount >= 20 || Date() > deadline {
            DiagnosticLogger.shared.log("SIGTERM: quiet — exiting now")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.terminateAfterQuiet(consecutiveIdle: idleCount, deadline: deadline)
        }
    }

    /// Microphone pin plumbing for the menu-bar selector. `config` is nil until setup
    /// loads it, and StatusBarController builds its first menu BEFORE that (launch
    /// crash caught by the AX harness 2026-07-14) — both entry points must nil-tolerate.
    public func currentInputDeviceUID() -> String? { config?.inputDeviceUID }

    public func selectInputDevice(uid: String?) {
        var updated = Config.load()
        updated.inputDeviceUID = uid
        try? updated.save()
        config?.inputDeviceUID = uid
        recorder.setPinnedInputDevice(uid: uid)
        statusBar.buildMenu()
        // P2: this is an external writer of config.json. If Settings is open, its cached view
        // model now holds a stale inputDeviceUID and its next save would revert this pick — re-sync
        // it from disk. Only when visible: refreshing mid-edit would clobber the user's in-progress
        // changes (and reloadConfig must NOT drive this, to avoid refreshing during a Settings save).
        if SettingsWindowController.isWindowVisible {
            settingsViewModel?.refreshFromDisk()
        }
        DiagnosticLogger.shared.log("Microphone selector: \(uid ?? "system default")")
    }

    /// Reload hotkey, pre-buffer, and menu without changing the transcriber/model.
    private func reloadHotkeyAndSettings() {
        // Routing must be settled before pre-buffer can start an absent engine.
        recorder.dualCaptureEnabled = config.dualMicCapture?.value ?? false
        recorder.setPinnedInputDevice(uid: config.inputDeviceUID)
        recorder.preBufferEnabled = config.preBuffer?.value ?? true

        // Update spoken punctuation on existing transcriber
        transcriber?.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

        // L1: rebuilding the HotkeyManager tears down and recreates the event tap, which would
        // lose an in-flight press's key-release. That deferral now lives at the TOP of reloadConfig
        // (the whole reload is deferred while fn is held), so this method is only ever reached when
        // fn is NOT held — the rebuild is always safe here.
        rebuildHotkeyManager()

        statusBar.buildMenu()

        syncLocalAPIServerState()
    }

    /// Tear down and recreate the HotkeyManager from the current config. Split out of
    /// reloadHotkeyAndSettings (P1) so it can be deferred past an in-flight dictation.
    private func rebuildHotkeyManager() {
        hotkeyManager?.stop()
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )
        hotkeyManager?.start(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() },
            onAbort: { [weak self] in self?.handleRecordingAbort() },
            onUserInteraction: { [weak self] in self?.noteUserInteraction() }
        )
    }

    private func noteUserInteraction() {
        userInteractionGeneration.withLock { generation in
            generation &+= 1
        }
    }

    private func currentUserInteractionGeneration() -> UInt64 {
        userInteractionGeneration.withLock { $0 }
    }

    /// L1: apply a config reload that was deferred because a dictation was in flight when
    /// reloadConfig was called. Called from every path that ends a dictation (finalizeRecording,
    /// handleKeyUp, handleRecordingAbort); the guard-then-clear makes it fire once and is
    /// idempotent, so overlapping end paths don't double-reload. reloadConfig reloads fresh
    /// Config.load() state from disk, and by the time any of these callers runs isPressed is
    /// already false, so the reload proceeds (does not re-defer) — the hotkey rebuild included.
    private func performPendingConfigReloadIfNeeded() {
        guard pendingConfigReload else { return }
        pendingConfigReload = false
        DiagnosticLogger.shared.log("Config: applying deferred reload — dictation finished")
        reloadConfig()
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

    /// Present the recordings apology notice. Main-only. A dismissal without a
    /// keep/delete decision re-arms it a few hours out; a decision (persisted by the
    /// controller) reloads config so the dialog's toggle takes effect immediately.
    private func showRecordingsNotice() {
        guard recordingsNoticeController == nil else { return }
        recordingsNoticeController = RecordingsNoticeController.present(
            onResolved: { [weak self] in
                self?.recordingsNoticeTimer?.invalidate()
                self?.recordingsNoticeTimer = nil
                self?.recordingsNoticeController = nil
                self?.reloadConfig()
                // P2: external writer of saveRecordings/recordingsNoticeDecision. Re-sync an open
                // Settings view model from disk so its next save can't resurrect the stale value.
                if SettingsWindowController.isWindowVisible {
                    self?.settingsViewModel?.refreshFromDisk()
                }
            },
            onConfigChanged: { [weak self] in
                self?.reloadConfig()
                // P2: same external-writer re-sync as onResolved (window-visible only).
                if SettingsWindowController.isWindowVisible {
                    self?.settingsViewModel?.refreshFromDisk()
                }
            },
            onDismissed: { [weak self] in
                guard let self else { return }
                self.recordingsNoticeController = nil
                self.recordingsNoticeTimer?.invalidate()
                self.recordingsNoticeTimer = Timer.scheduledTimer(
                    withTimeInterval: RecordingsNotice.reshowInterval, repeats: false
                ) { [weak self] _ in
                    self?.showRecordingsNotice()
                }
            }
        )
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

        // L1: the key was released via the still-installed old hotkey manager (the reload was
        // deferred while held) and isPressed is now false — safe to apply any deferred config
        // reload in full (transcriber swap + hotkey rebuild + settings).
        performPendingConfigReloadIfNeeded()
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
        // R1: fire-and-commit. The AX read used to block the main thread up to 0.5s at
        // record-START — and an unresponsive frontmost app would stall it long enough for
        // macOS to disable our event tap. It now runs on the background queue and publishes
        // into `focusCapture`; finalize consumes the result (waiting briefly only if it is
        // still in flight). Record-start no longer waits on it at all. Pre-roll (500ms)
        // means no audio is lost by starting the recorder before the read completes.
        let token = focusCapture.begin()
        // Snapshot the main-only fallback inputs now (we're on main) so the background
        // reader can compute the Electron cursor-context fallback without touching main state.
        let lastTail = lastInsertionTail
        let lastBundle = lastInsertionBundleID
        let lastAt = lastInsertionAt
        let lastElement = lastInsertionElement
        let lastInteractionGeneration = lastInsertionInteractionGeneration
        let interactionGenerationAtStart = currentUserInteractionGeneration()
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var capturedElement: AXUIElement?
            var capturedContext: String?
            let systemWide = AXUIElementCreateSystemWide()
            var elementRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
            if result == .success, let element = elementRef {
                // swiftlint:disable:next force_cast
                let axElement = element as! AXUIElement
                capturedElement = axElement
                capturedContext = self?.readTextBeforeCursor(in: axElement)
            }

            // Electron editors (VS Code) expose no AXValue — fall back to the tail of our
            // own last insertion when it plausibly still sits before the cursor, so the
            // mid-sentence-lowercase and prepend-space features keep working there.
            if capturedContext == nil {
                let userInteracted = lastInteractionGeneration.map {
                    $0 != interactionGenerationAtStart
                } ?? false
                let focusedElementMatches: Bool?
                if let lastElement, let capturedElement {
                    focusedElementMatches = CFEqual(lastElement, capturedElement)
                } else {
                    focusedElementMatches = nil
                }
                let fallback = FinalizePipeline.fallbackCursorContext(
                    lastInsertedTail: lastTail,
                    lastInsertedBundleID: lastBundle,
                    lastInsertedAt: lastAt,
                    frontmostBundleID: frontBundle,
                    now: Date(),
                    userInteractedSinceInsertion: userInteracted,
                    focusedElementMatches: focusedElementMatches)
                if let fallback {
                    capturedContext = fallback
                    DiagnosticLogger.shared.log(
                        "captureFocusedElement: AX gave no context — using tail of last insertion (\(fallback.count) chars)")
                } else if lastTail != nil, userInteracted {
                    DiagnosticLogger.shared.log(
                        "captureFocusedElement: discarded remembered context after user interaction")
                } else if lastTail != nil, focusedElementMatches == false {
                    DiagnosticLogger.shared.log(
                        "captureFocusedElement: discarded remembered context after focus changed")
                }
            }

            // Generation-guarded: a stale capture from a previous recording is dropped.
            self?.focusCapture.publish((capturedElement, capturedContext), token: token)
        }
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
            // range.location is a UTF-16 offset — convert via the utf16 view (AX-E).
            let cursorIndex = max(0, range.location)
            if cursorIndex > 0, let before = TextInserter.textBeforeUTF16Offset(fullText, cursorIndex) {
                // Take last 500 chars to stay within whisper's prompt limits
                return String(before.suffix(500))
            }
        }

        // No cursor info — use the last 500 chars of the whole field
        return String(fullText.suffix(500))
    }

    private func handleRecordingStart() {
        guard !isPressed else { return }

        // Microphone gate: never silently record silence. If access is missing, this prompts
        // (notDetermined) or shows an actionable alert (denied) and aborts this attempt.
        guard Permissions.ensureMicrophoneForRecording() else { return }

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
            // Remote desktop: AX would read the Splashtop UI, not the remote field. Reset the
            // capture box to a published-nil so finalize consumes no stale context.
            focusCapture.reset()
        }

        // Capture screen context in background if enabled.
        // Skip for remote desktop apps — OCR captures the remote screen content
        // which whisper then parrots instead of transcribing speech.
        // Skip when the engine ignores prompts (Parakeet, the default engine): the OCR text
        // only ever feeds the inference prompt, so capturing the full screen for it is
        // wasted work AND a needless read of everything visible.
        let isRemoteDesktop = inserter.isRemoteDesktopFrontmost()
        let engineUsesPrompt = transcriber?.supportsPrompt ?? false
        if config.screenContext?.value == true && !isRemoteDesktop && engineUsesPrompt {
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
            focusCapture.reset()  // recording never started — invalidate the in-flight capture
            // I4: OCR was kicked off just above, but recording never started so nothing will
            // consume it. Clear it and invalidate the in-flight capture so a late OCR write can't
            // bias the next dictation's prompt.
            screenContextText = nil
            screenCaptureGeneration = UUID()
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
        focusCapture.reset()  // invalidate any in-flight focus capture
        screenContextText = nil
        screenCaptureGeneration = UUID()  // invalidate any in-flight OCR
        statusBar.state = .idle
        recordingOverlay.hide()
        statusBar.buildMenu()

        // L1: the dictation ended (aborted) — apply any config reload deferred while fn was held.
        performPendingConfigReloadIfNeeded()
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
        let samplesAtRelease = recorder.currentSampleCount()
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
        // Perf adjudication dispute #1: bound the total wait by a MONOTONIC deadline. DispatchTime
        // is a monotonic clock (unlike wall-clock CFAbsoluteTimeGetCurrent, which NTP/clock-set can
        // jump), so a congested runloop firing a late tick still stops at the first tick past the
        // cap — we check the CURRENT clock against the deadline each tick, never trust tick count.
        let startTick = DispatchTime.now().uptimeNanoseconds

        postBufferTimer?.invalidate()
        postBufferTimer = Timer.scheduledTimer(withTimeInterval: windowMs / 1000.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startTick) / 1_000_000.0
            // R3: copy only the trailing slice, not the full (growing) sample array each tick.
            let trailing = self.recorder.samples(after: samplesAtRelease)
            // Ask the pure policy how long it wants given the trailing audio seen so far.
            let decided = PostBufferPolicy.decideWaitMs(trailingSamples: trailing, windowMs: windowMs)

            // Stop once the decided wait has elapsed, or the monotonic cap deadline is reached.
            if PostBufferPolicy.postBufferShouldFinalize(elapsedMs: elapsedMs, decidedMs: decided, capMs: capMs) {
                timer.invalidate()
                self.postBufferTimer = nil
                finalize()
            }
        }
    }

    private func finalizeRecording(keyReleaseTime: Double = CFAbsoluteTimeGetCurrent()) {
        // L1: the key was released before the post-buffer scheduled this call (isPressed is
        // already false). Applying a deferred FULL reload here — ahead of every return below —
        // guarantees no exit path (toggle-mode stop, gate failure, nil transcriber, success) leaves
        // it stranded, and it is the un-defer point for toggle mode (where handleKeyUp returned
        // early). Running before the transcriber snapshot below means the swap is atomic w.r.t.
        // this finalize: the snapshot picks up the freshly-applied engine and the whole
        // finalization runs on ONE engine (no torn mid-async swap). Idempotent with the handleKeyUp
        // / abort calls via the flag guard.
        performPendingConfigReloadIfNeeded()

        let stopTime = keyReleaseTime

        guard let recording = recorder.stopRecording() else {
            RecordingStore.clearSentinel()
            focusCapture.reset()
            statusBar.state = .idle
            recordingOverlay.hide()
            return
        }
        let audioURL = recording.url
        let secondaryCapture = recording.secondary

        // Pre-transcription gates (too-short / silent), with the wav on disk as arbiter:
        // if the in-memory samples fail a gate but the just-written wav passes, transcribe
        // the wav's samples instead of dropping the dictation (2026-06-29: a good AirPods
        // recording was dropped as "silent"; the wav transcribed fine offline).
        // Threshold + RMS live in FinalizePipeline so the test harness gates on the SAME values.
        let gate = FinalizePipeline.resolveGateSamples(
            memorySamples: recording.samples,
            readWav: { try? ProcessCommand.loadSamples(from: audioURL) }
        )
        if let failure = gate.failure {
            switch failure {
            case .tooShort(let count):
                // Likely an accidental tap — skip quietly.
                DiagnosticLogger.shared.log(
                    "Recording too short (\(count) samples / \(Int(Double(count) / 16000.0 * 1000))ms) — skipping")
            default:
                // NOTE: the wav either agreed or could not be read — resolveGateSamples does
                // not distinguish; do not claim agreement in the log.
                DiagnosticLogger.shared.log(
                    "Recording was silent (RMS \(FinalizePipeline.rms(of: recording.samples))) and the wav did not rescue it — audio engine may be dead, rebuilding")
                recorder.ensureAudioHealthy()
            }
            if !DevMode.effectiveSaveRecordings(config) {
                // Saving is opt-out: a gate-failed capture must not linger on disk.
                try? FileManager.default.removeItem(at: audioURL)
            }
            RecordingStore.clearSentinel()
            focusCapture.reset()
            // I4: a gate-failed dictation never consumes its OCR, so clear it and invalidate any
            // in-flight capture — otherwise this recording's screenContextText survives and biases
            // the NEXT dictation's prompt with stale on-screen text.
            screenContextText = nil
            screenCaptureGeneration = UUID()
            statusBar.state = .idle
            recordingOverlay.hide()
            return
        }
        if gate.usedWavFallback {
            // Divergence between the tap's in-memory copy and the wav is an upstream bug —
            // the dictation is saved, but leave a trace so it can be chased.
            DiagnosticLogger.shared.log(
                "Gate override: in-memory samples failed (count \(recording.samples.count), RMS \(FinalizePipeline.rms(of: recording.samples))) but wav passed — transcribing wav samples")
        }
        let samples = gate.samples

        statusBar.state = .transcribing
        recordingOverlay.update(state: .transcribing)

        // R1: consume the off-main focus capture. In the normal case it published while the
        // user was still speaking, so this returns immediately; only if the AX read is still
        // in flight does it wait briefly (0.5s budget, the same as the old synchronous
        // capture — but off the felt start path). nil on timeout is identical to the old
        // AX-timeout behavior.
        let (capturedElement, capturedInputText) = focusCapture.consume(waitingUpTo: 0.5) ?? (nil, nil)
        let capturedScreenText = screenContextText
        screenContextText = nil
        screenCaptureGeneration = UUID()  // invalidate any late-arriving OCR

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
        // Recordings privacy: persisting audio + transcripts is opt-in (2026-07-14).
        let keepRecording = DevMode.effectiveSaveRecordings(config)
        let mode = config.spokenPunctuation ?? .off
        let glossary = Config.loadVocabulary()
        let overrides = Config.loadOverrides()
        let capturedStyleMode = recordingStyleMode
        // Provenance snapshot for the .meta.json sidecar — engine/model from the ACTIVE
        // transcriber (not config, which can disagree after a model fallback).
        let metaEngine = activeEngineID
        let metaDevice = recorder.currentCaptureDeviceName()

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
                        overrides: overrides,
                        audioDurationSeconds: Double(samples.count) / 16000.0
                    )
                }
                // The serial capture queue resolves this only after Bluetooth start and stop
                // have both completed. Awaiting here keeps CoreAudio work off main and closes
                // the AirPods mic before inference begins. Bounded: the secondary stop sits
                // behind Bluetooth HAL calls, and a wedged coreaudiod there must degrade to
                // primary-only — never hold the user's text hostage to the comparison track.
                let btSamples = await secondaryCapture.value(
                    timeout: DualCapture.secondaryResultTimeout)
                let hasBluetoothTrack = btSamples.count >= FinalizePipeline.minSamples
                let btURL = audioURL.deletingPathExtension().appendingPathExtension("bt.wav")
                var btArtifactCommitted = false
                defer {
                    // The primary recording's normal finish path enforces the privacy
                    // setting. The extra Bluetooth artifact must obey it even when
                    // inference throws before finishRecording is reached — and even with
                    // saving ON, a bt.wav written before a throw has no sidecars yet and
                    // would sit as an orphan the recovery path could adopt. Only a fully
                    // finished dual dictation keeps it.
                    if !btArtifactCommitted {
                        try? FileManager.default.removeItem(at: btURL)
                    }
                }

                let primaryRaw: String
                var bluetoothRaw: String?
                var reusedPartial = false
                if hasBluetoothTrack {
                    // Sequential, PRIMARY FIRST — deliberately. Both engine backends
                    // serialize internally (Whisper's serial engineQueue, Parakeet's
                    // actor), so async-let gave no real overlap; worse, nondeterministic
                    // enqueue order could park the user's primary inference behind the
                    // whole Bluetooth pass. Primary goes first so the comparison track
                    // can only ever cost its own inference time, never delay-order risk.
                    try? DualCapture.writeWav(samples: btSamples, to: btURL)
                    let started = CFAbsoluteTimeGetCurrent()
                    primaryRaw = try await transcriber.transcribe(
                        audioURL: audioURL, samples: samples, prompt: prompt)
                    bluetoothRaw = try? await transcriber.transcribe(
                        audioURL: btURL, samples: btSamples, prompt: prompt)
                    DiagnosticLogger.shared.log(String(
                        format: "DualCapture: dual inference (primary-first) completed in %.3fs",
                        CFAbsoluteTimeGetCurrent() - started))
                } else {
                    // Streaming-partial reuse is primary-only. A dual recording always runs
                    // both full passes so its alignment compares equivalent inference paths.
                    (primaryRaw, reusedPartial) = try await FinalizePipeline.resolveRaw(
                        reuseDecision: reuseDecision
                    ) {
                        try await transcriber.transcribe(
                            audioURL: audioURL, samples: samples, prompt: prompt)
                    }
                }
                if reusedPartial {
                    DiagnosticLogger.shared.log("T2.3: reused last streaming partial (skipped final inference)")
                }
                let merge = bluetoothRaw.map {
                    DualCapture.mergeTranscripts(
                        primary: primaryRaw, bluetooth: $0,
                        protectedWords: DualCapture.protectedWordSet(fromGlossary: glossary))
                } ?? DualCapture.MergeResult(
                    text: primaryRaw, usedBluetooth: false, confidence: 0,
                    matchedTokens: 0, reason: .primaryOnly)
                let raw = merge.text
                if hasBluetoothTrack {
                    let agreement = DualCapture.tokenAgreement(primaryRaw, bluetoothRaw ?? "")
                    DiagnosticLogger.shared.log(String(
                        format: "DualCapture: merge=%@ confidence=%.1f%% agreement=%.1f%% "
                            + "(primary %d chars, bt %d chars, bt %.1fs)",
                        merge.reason.rawValue, merge.confidence * 100, agreement * 100,
                        primaryRaw.count, bluetoothRaw?.count ?? 0,
                        Double(btSamples.count) / 16000.0))
                }
                let text = TextPipeline.run(makeInput(raw), precomputedPrompt: .some(prompt)).finalText
                RecordingStore.finishRecording(
                    audioURL: audioURL, keep: keepRecording, raw: raw, text: text,
                    meta: RecordingStore.RecordingMeta(
                        appVersion: SpeakFree.version,
                        engine: metaEngine,
                        model: transcriber.modelID,
                        inputDevice: metaDevice,
                        date: ISO8601DateFormatter().string(from: Date()),
                        durationSeconds: Double(samples.count) / 16000.0,
                        transcriptChars: text.count
                    ))

                RecordingStore.clearSentinel()

                // Preserve both unmerged raw transcripts for future corpus iteration.
                // `.raw.txt` above is the merged raw that actually entered TextPipeline.
                if keepRecording, hasBluetoothTrack {
                    RecordingStore.saveDualSourceRaws(
                        primary: primaryRaw, bluetooth: bluetoothRaw ?? "",
                        btAudioURL: btURL, mainAudioURL: audioURL)
                    btArtifactCommitted = true
                }
                if keepRecording && maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }

                DispatchQueue.main.async {
                    self.recordingOverlay.hide()
                    if !text.isEmpty {
                        // T2.2: use the prepend-space decision precomputed at record-start (off
                        // main). No AX query, no semaphore.wait — zero main-thread stall here.
                        let insertText = FinalizePipeline.composeInsertText(text, prependSpace: capturedPrependSpace)
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
                            // Remember what now sits before the cursor — the context
                            // fallback for AX-opaque editors (VS Code) reads this on
                            // the next recording start. Chain onto the context THIS
                            // dictation used, so back-to-back dictations accumulate
                            // ("…weird," + " I think…") instead of resetting.
                            self.lastInsertionTail =
                                String(((capturedInputText ?? "") + insertText).suffix(500))
                            self.lastInsertionBundleID =
                                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                            self.lastInsertionAt = Date()
                            self.lastInsertionElement = capturedElement
                            self.lastInsertionInteractionGeneration =
                                self.currentUserInteractionGeneration()
                        }
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
                // The opt-out must win on the failure path too: finishRecording(keep:false)
                // — the deletion the user consented to — is never reached when inference
                // throws, and the wav would silently persist against the setting.
                if !keepRecording {
                    try? FileManager.default.removeItem(at: audioURL)
                }
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
                        // Must be VISIBLE: a swallowed throw here means a good recording
                        // silently produces nothing (the 2026-06-29 dropped-dictation event
                        // took 12 days to trace because this branch only printed to stdout).
                        // Error type/description only — never transcript content.
                        let message = "Transcription failed: \(error)"
                        print("Error: \(message)")
                        DiagnosticLogger.shared.log(message)
                        // Throttle the modal: a persistently broken engine fails EVERY
                        // dictation, and one focus-stealing alert per attempt is hostile.
                        // The log line above fires every time regardless.
                        let now = Date()
                        if self.lastTranscriptionFailureAlert.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                            self.lastTranscriptionFailureAlert = now
                            NSApp.activate(ignoringOtherApps: true)
                            let alert = NSAlert()
                            alert.messageText = "Transcription Failed"
                            let recordingNote = keepRecording
                                ? "Your recording was kept and can be transcribed from the recordings folder."
                                : "The recording was discarded (saving recordings is off)."
                            alert.informativeText = "The engine reported an error. \(recordingNote)"
                                + "\n\n\(error.localizedDescription)"
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
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
                DispatchQueue.main.async {
                    // Commit completed sentences so they won't change on next inference.
                    // Must run on main: streamingAssembler is main-queue-only state (it is
                    // also mutated by onPartialResult and reset by stopStreamingTimer).
                    let displayText = self.buildStableDisplayText(from: partial)
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

/// R1: a generation-guarded holder for an off-main capture result.
///
/// `begin()` opens a new generation (invalidating any in-flight prior capture) and returns
/// a token. The background reader calls `publish(_:token:)` when its work lands. The
/// consumer calls `consume(waitingUpTo:)`, which returns the published value immediately if
/// it has already arrived, or waits up to `timeout` for it — and returns `nil` on timeout,
/// matching the old "AX query timed out → no context" behavior. `publish` is always called
/// off the consumer's thread and signals a semaphore, so `consume` waiting on the consumer
/// (main) thread can never deadlock. `reset()` puts the box into a published-nil state so a
/// consume returns immediately with no value (used when a capture is skipped or invalidated).
final class FocusCaptureBox<Value> {
    private let lock = NSLock()
    private var generation = 0
    private var value: Value?
    private var published = false
    private var semaphore: DispatchSemaphore?
    /// When the current generation was opened. A capture is only valid within
    /// `captureDeadline` of this instant — see `publish`/`consume`.
    private var beganAt: Date?
    /// Start-relative validity window. Restores HEAD's "context is from record-START"
    /// semantics: a result that only lands (or that a consumer would only wait for) more than
    /// this long after `begin()` reflects mid-recording focus, not the focus at record-start,
    /// so it is discarded rather than accepted.
    private let captureDeadline: TimeInterval

    init(captureDeadline: TimeInterval = 0.5) {
        self.captureDeadline = captureDeadline
    }

    /// Open a new generation. Returns the token the background reader must pass to `publish`.
    func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        value = nil
        published = false
        semaphore = DispatchSemaphore(value: 0)
        beganAt = Date()
        return generation
    }

    /// Publish the captured value. Dropped if `token` is stale (a newer `begin()`/`reset()`
    /// ran), the current generation was already published, or the capture landed more than
    /// `captureDeadline` after `begin()` (a late read reflects mid-recording, not record-start).
    func publish(_ newValue: Value?, token: Int) {
        lock.lock()
        let tooLate = beganAt.map { Date().timeIntervalSince($0) > captureDeadline } ?? true
        guard token == generation, !published, !tooLate else { lock.unlock(); return }
        value = newValue
        published = true
        let sem = semaphore
        lock.unlock()
        sem?.signal()
    }

    /// Return the published value, waiting only until the start-relative deadline (and at most
    /// `timeout`) if the capture is still in flight. Never blocks the caller beyond that; `nil`
    /// on timeout (graceful degradation). Clears the stored value/element on return so the AX
    /// element and cursor-adjacent text are never retained past a single consume (privacy).
    func consume(waitingUpTo timeout: TimeInterval) -> Value? {
        lock.lock()
        if published { let v = value; value = nil; lock.unlock(); return v }
        // If the capture can no longer legally publish (past its start-relative deadline),
        // return immediately rather than blocking main on a result that will be rejected. This
        // also kills the between-dictations 0.5s block when no capture is in flight for this gen.
        let remaining: TimeInterval = beganAt.map { captureDeadline - Date().timeIntervalSince($0) } ?? 0
        if remaining <= 0 { let v = value; value = nil; lock.unlock(); return v }
        let sem = semaphore
        lock.unlock()
        _ = sem?.wait(timeout: .now() + min(timeout, remaining))
        lock.lock(); let v = value; value = nil; lock.unlock()
        return v
    }

    /// Invalidate any in-flight capture and put the box into a published-nil state so the
    /// next `consume` returns `nil` immediately (no wait).
    func reset() {
        lock.lock()
        generation += 1
        value = nil
        published = true
        semaphore = nil
        beganAt = nil
        lock.unlock()
    }
}
