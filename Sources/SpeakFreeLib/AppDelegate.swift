// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
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
    /// Frontmost app at record start — where the dictation will land. Persisted in
    /// .meta.json so the edit-feedback batch can find the final artifact to diff.
    private var recordingTargetBundleID: String?

    // Clean up whisper model before exit to prevent ggml Metal assertion crash.
    // The crash happens in __cxa_finalize_ranges when ggml tries to free Metal
    // residency sets that are still active during static destructor cleanup.
    public func applicationWillTerminate(_ notification: Notification) {
        // Close an in-flight recording FIRST (2026-07-25 audit F7): a clean quit
        // (Cmd-Q, logout, Sparkle relaunch) previously left the wav header uncommitted —
        // total loss, same as a crash. stopRecording() drains the write queue and
        // patches the header; the wav then survives for the launch orphan sweep.
        if recorder?.stopRecording() != nil {
            DiagnosticLogger.shared.log("Terminate: closed in-flight recording for recovery")
        }
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
    // Draining after SIGTERM (2026-07-25): new recordings are refused while waiting to
    // exit — one started post-SIGTERM races the exit and its audio dies in memory.
    private var isTerminating = false
    // In-recording dead-audio watchdog + idle tap-health poll (2026-07-25). Main-only.
    private var recordingWatchdogTimer: Timer?
    private var watchdogWarnedDeadAudio = false
    private var watchdogSilentTicks = 0
    private var tapHealthTimer: Timer?
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
        // One-line effective-config snapshot (Michael 2026-08-20: forensics need the
        // settings a session actually ran with, not a guess from the current file).
        var cfgParts: [String] = []
        cfgParts.append("engine=" + (config.engine ?? "whisper"))
        cfgParts.append("model=" + config.modelSize)
        cfgParts.append("parakeetModel=" + (config.parakeetModel ?? "-"))
        cfgParts.append("input=" + (config.inputDeviceUID ?? "system-default"))
        cfgParts.append("punctuation=\(config.effectivePunctuationMode)")
        cfgParts.append("streaming=\(config.streamingEnabled?.value ?? true)")
        cfgParts.append("preBuffer=\(config.preBuffer?.value ?? true)")
        cfgParts.append("keepLoaded=" + (config.keepModelLoaded ?? "auto"))
        cfgParts.append("saveRecordings=\(config.saveRecordings?.value ?? false)")
        cfgParts.append("screenContext=\(config.screenContext?.value ?? false)")
        cfgParts.append("language=" + config.language)
        DiagnosticLogger.shared.log("Config: " + cfgParts.joined(separator: " "))

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
        // Recovery (rebuilt 2026-07-25): the sentinel is one pointer, but the real
        // inventory is the ORPHAN SWEEP — any recent wav without a transcript sidecar,
        // headers repaired in place. The old handler (`reprocess`) only re-read a .txt
        // that a crashed recording never has; recovery now actually TRANSCRIBES.
        let maxRecordings = (config.preserveAllRecordings?.value ?? false) ? 0 : Config.effectiveMaxRecordings(config.maxRecordings)
        if maxRecordings > 0 {
            RecordingStore.prune(maxCount: maxRecordings)
        }

        // (Prune runs FIRST — codex review #2: pruning after the sweep could delete
        // an orphan mid-recovery.)
        // AUTO-recovery (Michael, 2026-07-25: "why should I have to click?"): orphans
        // are transcribed in the background at launch — no menu click, no clipboard
        // side effects. Results land as transcript sidecars, so recovered dictations
        // appear in Recent Dictations (where a click inserts them). Each orphan waits
        // for an idle moment so a live dictation's inference never queues behind a
        // recovery chunk. Empty transcripts (room tone) get an empty sidecar so
        // they're never re-swept. Failures stay orphaned and retry next launch.
        RecordingStore.clearSentinel()
        let orphans = RecordingStore.sweepRecoverableOrphans()
        if !orphans.isEmpty {
            DiagnosticLogger.shared.log(String(
                format: "Recovery: %d orphan(s) queued for background transcription (newest %@, %.0fs)",
                orphans.count, orphans[0].url.lastPathComponent, orphans[0].seconds))
            autoRecoverOrphans(orphans.map(\.url))
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
            onUserInteraction: { [weak self] interaction in
                DispatchQueue.main.async { self?.noteUserInteraction(interaction) }
            }
        )

        isReady = true
        // Tap-health poll (2026-07-25 audit: a dead event tap was UNDETECTABLE —
        // the only health check was gated behind a successful keypress). Every 30s,
        // verify and re-arm the tap so "press fn, nothing happens" gets fixed before
        // the user hits it. NOT gated on isPressed (2026-08-11): a stranded take —
        // release lost during a tap outage — keeps isPressed true indefinitely, so an
        // idle-only poll was disabled during exactly the failure it guards. Running it
        // mid-take is safe: ensureTapHealthy reconciles only when it actually repaired
        // something, so a healthy take in progress is never touched.
        DispatchQueue.main.async { [weak self] in
            self?.tapHealthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                guard let self = self, !self.isTerminating else { return }
                self.hotkeyManager?.ensureTapHealthy()
            }
        }
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

        // Spoken Only on Parakeet: Parakeet ignores suppressAutoPunctuation, and the spoken-word
        // substitution is now identically guarded across Spoken Only and Automatic & Spoken, so the
        // two modes are behaviorally identical here. We do NOT rewrite the stored mode (a user who
        // switches back to Whisper keeps Spoken Only); log one line for observability.
        if effectiveEngineID == "parakeet" && config.spokenPunctuation == .spoken {
            DiagnosticLogger.shared.log(
                "Punctuation: Spoken Only on Parakeet behaves as Automatic & Spoken "
                + "(Parakeet cannot suppress its own auto-punctuation); stored mode left unchanged.")
        }

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
            // Refuse NEW recordings while draining: a dictation started after SIGTERM
            // races the exit and its audio dies in memory (2026-07-25: recording began
            // 2s after the prior one finished, deploy force-killed it mid-capture, wav
            // on disk had 0 samples). Finishing the in-flight one, then going dark for
            // ~10s until the new instance arrives, is strictly better than eating audio.
            self.isTerminating = true
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
            onUserInteraction: { [weak self] interaction in
                DispatchQueue.main.async { self?.noteUserInteraction(interaction) }
            }
        )
    }

    private func noteUserInteraction(_ interaction: HotkeyManager.CursorInteraction) {
        func invalidate() {
            userInteractionGeneration.withLock { generation in
                generation &+= 1
            }
        }

        guard let bundleID = lastInsertionBundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              let tail = lastInsertionTail else {
            invalidate()
            return
        }

        let pastedText = interaction == .paste
            ? NSPasteboard.general.string(forType: .string) : nil
        guard let updatedTail = HotkeyManager.updatedCursorTail(
            tail, after: interaction, pastedText: pastedText) else {
            invalidate()
            return
        }

        // We now know the cursor tail from the actual edits, even if AX cannot expose the
        // editor. Clear the old AX identity (Electron may vend unstable wrapper objects), keep
        // only the bounded suffix, and refresh the fallback freshness window.
        lastInsertionTail = updatedTail
        lastInsertionAt = Date()
        lastInsertionElement = nil
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
        guard isReady, !isTerminating else { return }

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

    /// Guards `lastLiveAXContextByApp`, written from the background capture queue.
    private static let liveAXContextLock = NSLock()
    /// bundleID -> the last live-AX cursor context we accepted for that app.
    private static var lastLiveAXContextByApp: [String: String] = [:]

    /// Record this live-AX context and report whether it is a REPEAT for the same app.
    ///
    /// 2026-07-26 — the three Electron trust gates in `readTextBeforeCursor` all reject things
    /// that are too BIG (cursor not at end, >1200 chars, >4 newlines). They were built to keep
    /// out the VS Code terminal scrollback. What actually got through was too SMALL: on 07-26,
    /// 83 of the day's reads in VS Code returned one of exactly two constant strings (22 and 32
    /// chars), while every genuine context length appeared once or twice. speakfree read that
    /// fixed UI string as "the text before your cursor" and therefore prepended a space and
    /// lowercased the first word — 57 wrongly-lowercased dictations that day, 63 the day before,
    /// and 0 on the two days before the Electron AX unlock shipped.
    ///
    /// A real cursor context changes: he types, or our own insertion lands in the field. A value
    /// byte-identical to the previous one for the same app is chrome, not his text. Rejecting it
    /// falls back to no-context, which disables exactly the two features that were misfiring,
    /// and only for the reads that were wrong.
    static func liveAXContextIsRepeat(_ context: String, bundleID: String?) -> Bool {
        let key = bundleID ?? "?"
        liveAXContextLock.lock()
        defer { liveAXContextLock.unlock() }
        let isRepeat = lastLiveAXContextByApp[key] == context
        lastLiveAXContextByApp[key] = context
        return isRepeat
    }

    /// Test seam — the table is process-global, so tests must be able to clear it.
    static func resetLiveAXContextMemory() {
        liveAXContextLock.lock()
        lastLiveAXContextByApp.removeAll()
        liveAXContextLock.unlock()
    }

    static func liveCursorContext(_ context: String?, isElectronClass: Bool) -> String? {
        isElectronClass ? nil : context
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
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBundle = frontApp?.bundleIdentifier
        // Resolve the Electron classification on main, where `frontmostApplication` is
        // authoritative, rather than re-reading it from the background reader below.
        let electronClass = TextInserter.prefersClipboardPaste(app: frontApp)
        let avoidLiveWindowContext = TextInserter.shouldAvoidLiveWindowContext(
            bundleID: frontBundle, bundleURL: frontApp?.bundleURL)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var capturedElement: AXUIElement?
            var capturedContext: String?
            let systemWide = AXUIElementCreateSystemWide()
            var elementRef: CFTypeRef?
            // Electron-class apps get the trust gates on EVERY read (2026-07-25:
            // AXManualAccessibility persists per-app once flipped, so subsequent
            // reads succeed on this FIRST attempt — the gates must not live only
            // on the unlock-retry path). Native apps keep full-fidelity context.
            let result = avoidLiveWindowContext
                ? AXError.cannotComplete
                : AXUIElementCopyAttributeValue(
                    systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
            if result == .success, let element = elementRef {
                // swiftlint:disable:next force_cast
                let axElement = element as! AXUIElement
                capturedElement = axElement
                if !electronClass {
                    capturedContext = Self.liveCursorContext(
                        self?.readTextBeforeCursor(in: axElement),
                        isElectronClass: electronClass)
                }
            }

            // Electron AX unlock (2026-07-25): Electron apps ship with their AX tree
            // DISABLED and expose the app-level `AXManualAccessibility` switch to turn
            // it on without VoiceOver. Without it, typed-then-dictate in Superhuman/
            // VS Code has no cursor context, so the mid-sentence-lowercase feature
            // can't fire ("Search for X " + dictation came out capitalized). Flip the
            // switch on first failure, give the tree a beat to build, retry once.
            // We're on a background queue — the wait never touches main; pre-roll
            // covers the audio. Idempotent and harmless on non-Electron apps.
            if !electronClass, capturedContext == nil,
               let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let appEl = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString,
                                             kCFBooleanTrue)
                Thread.sleep(forTimeInterval: 0.25)
                var retryRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(systemWide,
                                                 kAXFocusedUIElementAttribute as CFString,
                                                 &retryRef) == .success,
                   let element = retryRef {
                    // swiftlint:disable:next force_cast
                    let axElement = element as! AXUIElement
                    capturedElement = axElement
                    capturedContext = self?.readTextBeforeCursor(in: axElement,
                                                                 requireCursorAtEnd: true)
                    if capturedContext != nil {
                        DiagnosticLogger.shared.log(
                            "captureFocusedElement: AXManualAccessibility unlock succeeded (cursor at end)")
                    }
                }
            }

            // Repeat-value gate (2026-07-26). A live-AX context identical to the previous read
            // for this app is fixed UI chrome, not his cursor — see liveAXContextIsRepeat.
            if let live = capturedContext,
               AppDelegate.liveAXContextIsRepeat(live, bundleID: frontBundle) {
                DiagnosticLogger.shared.log(
                    "captureFocusedElement: discarded repeated live-AX context (\(live.count) chars, "
                    + "identical to the previous read for \(frontBundle ?? "?")) — treating as no context")
                capturedContext = nil
            }

            // Electron editors (VS Code) expose no AXValue — fall back to the tail of our
            // own last insertion when it plausibly still sits before the cursor, so the
            // mid-sentence-lowercase and prepend-space features keep working there.
            var contextSource = capturedContext != nil ? "liveAX" : "none"
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
                    contextSource = "fallbackTail"
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
            // When source=none, say WHY the live read produced nothing: an AX-opaque /
            // Chromium-class app has its live read deliberately skipped (context can only
            // come from the remembered insertion tail), which is a very different state from
            // a native app whose AX read was attempted and came back empty. Without this
            // distinction the "source=none len=0" line reads as "AX is failing" when the read
            // never ran (2026-08-18 bug hunt was misdirected by exactly this ambiguity).
            let noneReason = contextSource == "none"
                ? (avoidLiveWindowContext
                    ? " (liveAX skipped: AX-opaque/Chromium-class \(frontBundle ?? "?"))"
                    : " (liveAX attempted, empty)")
                : ""
            DiagnosticLogger.shared.log("captureFocusedElement: context source=\(contextSource) len=\(capturedContext?.count ?? 0)\(noneReason)")
            self?.focusCapture.publish((capturedElement, capturedContext), token: token)
        }
    }

    /// Reads up to 500 characters before the cursor without changing selection or focus.
    /// `requireCursorAtEnd`: trust gate for the AXManualAccessibility-unlocked
    /// Electron read (2026-07-25: VS Code's reported cursor offset can be stale/
    /// wrong, yielding context that "ends mid-sentence" and wrongly lowercasing a
    /// fresh paragraph — the engine had capitalized "As usual" correctly). When
    /// set, context is only returned if the cursor is verifiably at the END of
    /// the field — the appending flow dictation actually uses.
    /// AX roles that can actually hold a text cursor. Everything else is chrome.
    ///
    /// 2026-07-26 — walking VS Code's full AX tree (14 windows, 20k+ nodes) found the string
    /// behind 45 of the day's bad reads: `⌘ Esc to focus or unfocus Claude`, exactly 32
    /// characters, the Claude Code panel's hint label. It carries no terminal punctuation and no
    /// trailing space, which is precisely the `prependSpace=true midSentence=true` signature the
    /// log recorded 45 times. It is a LABEL. speakfree read it as "the text before your cursor"
    /// and lowercased the first word of the dictation that followed.
    ///
    /// The size gates could never have caught this (a 32-char label is small), and the
    /// repeat-value gate only half-catches it (reads alternate between two chrome strings, so
    /// only 40 of 150 were identical to their predecessor). Asking what KIND of element it is
    /// separates a label from an input in one attribute.
    static let cursorBearingRoles: Set<String> = [
        kAXTextAreaRole as String, kAXTextFieldRole as String,
        kAXComboBoxRole as String, "AXSearchField",
    ]

    private func readTextBeforeCursor(in element: AXUIElement,
                                      requireCursorAtEnd: Bool = false) -> String? {
        // Role gate, before anything else: a label, button or static text never holds a cursor,
        // so its text is never "what he typed before dictating".
        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                                 &roleRef) == .success
            ? (roleRef as? String ?? "?") : "?"
        guard Self.cursorBearingRoles.contains(role) else {
            DiagnosticLogger.shared.log(
                "readTextBeforeCursor: ignoring focused element of role \(role) — not a text input")
            return nil
        }

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
            if requireCursorAtEnd {
                // Electron trust gates (2026-07-25): offset must be at field end, AND
                // the field must be input-sized — VS Code hands us the TERMINAL
                // SCROLLBACK document as the "focused element", whose tail never ends
                // in whitespace (phantom leading spaces + wrongful lowercase). Real
                // inputs (search boxes, chat prompts) are short; documents are not.
                if cursorIndex < fullText.utf16.count { return nil }
                // Input-shaped only: a VS Code TUI screen can be under 4000 chars,
                // but no search box or chat prompt is 5+ lines of text ending in a
                // shell prompt. (2026-07-25, third phantom-space report.)
                if fullText.utf16.count > 1200 { return nil }
                if fullText.filter({ $0.isNewline }).count > 4 { return nil }
            }
            if cursorIndex > 0, let before = TextInserter.textBeforeUTF16Offset(fullText, cursorIndex) {
                // Take last 500 chars to stay within whisper's prompt limits
                return String(before.suffix(500))
            }
        }

        // No cursor info: DO NOT guess from the whole field's tail (2026-07-25:
        // the AXManualAccessibility unlock opened Electron fields whose tail is
        // arbitrary document text — it rarely ends in a space, so the prepend-space
        // logic added phantom leading spaces to every dictation). nil lets the
        // last-insertion fallback chain decide, which carries real cursor knowledge.
        return nil
    }

    private func handleRecordingStart() {
        guard !isPressed else { return }
        let startRequestedAt = CFAbsoluteTimeGetCurrent()

        // A stale Secure-Input retry must never fire mid-take or after a newer dictation —
        // starting a new recording supersedes the parked text.
        cancelSecureInputRetry()

        // Microphone gate: never silently record silence. If access is missing, this prompts
        // (notDetermined) or shows an actionable alert (denied) and aborts this attempt.
        guard Permissions.ensureMicrophoneForRecording() else { return }

        isPressed = true

        // Verify all subsystems before every recording
        verifySubsystems(context: "pre-recording")
        let healthFinishedAt = CFAbsoluteTimeGetCurrent()

        // Detect style mode from frontmost app before menu bar steals focus. The
        // bundle id is also kept for the .meta.json sidecar — the edit-feedback batch
        // (tune-corpus) correlates dictations with where the text landed.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBundleID = frontApp?.bundleIdentifier
        let avoidLiveWindowContext = TextInserter.shouldAvoidLiveWindowContext(
            bundleID: frontBundleID, bundleURL: frontApp?.bundleURL)
        recordingTargetBundleID = frontBundleID
        inserter.livePrependProbeSuppressed =
            TextInserter.prefersClipboardPaste(app: frontApp)
        recordingStyleMode = TextPostProcessor.detectStyleMode(bundleID: frontBundleID)
        let classificationFinishedAt = CFAbsoluteTimeGetCurrent()

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
        // engineUsesPrompt no longer gates the capture (2026-07-25): OCR now also
        // feeds the screen-aware NAME corrector, which works on every engine —
        // Parakeet users get on-screen spellings (Kris vs Chris) even though the
        // engine ignores prompts.
        if config.screenContext?.value == true && !isRemoteDesktop && !avoidLiveWindowContext {
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
        recordingOverlay.style = min(5, max(1, config.overlayStyle ?? 5))
        recordingOverlay.show(state: .recording, recorder: recorder)
        let overlayFinishedAt = CFAbsoluteTimeGetCurrent()
        startRecordingWatchdog()
        do {
            // Always write to recordings dir — crash recovery works regardless of maxRecordings
            let outputURL = RecordingStore.newRecordingURL()
            RecordingStore.writeSentinel(recordingURL: outputURL)
            try recorder.startRecording(to: outputURL)
            let recordingStartedAt = CFAbsoluteTimeGetCurrent()
            if recordingStartedAt - startRequestedAt >= 0.25 {
                DiagnosticLogger.shared.log(String(
                    format: "Recording start slow: health=%.2fs classify=%.2fs overlay=%.2fs file=%.2fs total=%.2fs",
                    healthFinishedAt - startRequestedAt,
                    classificationFinishedAt - healthFinishedAt,
                    overlayFinishedAt - classificationFinishedAt,
                    recordingStartedAt - overlayFinishedAt,
                    recordingStartedAt - startRequestedAt))
            }

            // Start streaming transcription timer — processes audio every 2s for live preview
            startStreamingTimer()
        } catch {
            // MUST be visible in the diagnostic log: this branch used to print only to
            // stdout, so the 2026-07-23 every-press-fails outage looked like a silent
            // no-op ("Health check: all OK" then nothing) and took a live stdout
            // capture to see. Error description only — never transcript content.
            DiagnosticLogger.shared.log("Recording start FAILED: \(error)")
            stopRecordingWatchdog()
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
            // LOUD failure (2026-07-25): the overlay used to flash for one frame and
            // hide — the user pressed the key, spoke, and got nothing. Now a red
            // center-screen banner says so (auto-hides).
            recordingOverlay.show(state: .error("Recording failed: check your microphone"))
        }
    }

    // MARK: - Secure-Input retry dialog (Michael 2026-08-12)
    //
    // "A little box that says secure input activated, hit Command V to paste your
    // dictation … keeps retrying, and if it gets it, it shuts down the box."
    // The dialog reuses the center-screen overlay banner; the retry polls every 0.5s and
    // lives exactly as long as the concealed clipboard hold (secureInputClipboardClearDelay),
    // so the box never promises a paste the clipboard can no longer deliver.

    private var secureInputRetryTimer: Timer?

    private func beginSecureInputRetry(text: String) {
        cancelSecureInputRetry()
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let generalPasteboard = NSPasteboard.general
        let heldChangeCount = generalPasteboard.changeCount
        let deadline = Date().addingTimeInterval(inserter.secureInputClipboardClearDelay)
        let holder = TextInserter.secureInputHolderName()
        let blocker = holder.map { " (\($0))" } ?? ""
        recordingOverlay.show(
            state: .error("Secure Input\(blocker) blocked dictation — press ⌘V to paste"),
            autoHideError: false)
        DiagnosticLogger.shared.log(
            "SecureInputRetry: dialog shown, holder=\(holder ?? "unknown"), retrying for "
            + "\(Int(inserter.secureInputClipboardClearDelay))s")
        secureInputRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let action = TextInserter.secureInputRetryAction(
                secureInputActive: self.inserter.isSecureInputActive(),
                clipboardMoved: generalPasteboard.changeCount != heldChangeCount,
                frontmostMatchesTarget:
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleID,
                deadlinePassed: Date() >= deadline)
            switch action {
            case .wait:
                break
            case .dismiss:
                DiagnosticLogger.shared.log(
                    "SecureInputRetry: dismissed without auto-insert (clipboard moved or hold expired)")
                self.cancelSecureInputRetry()
            case .insert:
                self.cancelSecureInputRetry()
                DiagnosticLogger.shared.log("SecureInputRetry: Secure Input cleared — auto-inserting")
                self.inserter.insert(text: text)
                self.statusBar.state = .idle
                self.statusBar.buildMenu()
            }
        }
    }

    private func cancelSecureInputRetry() {
        guard secureInputRetryTimer != nil else { return }
        secureInputRetryTimer?.invalidate()
        secureInputRetryTimer = nil
        recordingOverlay.hide()
        if statusBar.state == .secureInputCopied {
            statusBar.state = .idle
            statusBar.buildMenu()
        }
    }

    /// A real key was pressed while fn was held — this is a keyboard shortcut, not dictation.
    /// Cancel recording silently and let the shortcut pass through.
    private func handleRecordingAbort() {
        guard isPressed else { return }
        isPressed = false

        stopRecordingWatchdog()
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

    /// In-recording dead-audio watchdog (2026-07-25 audit C3/C5): the ONLY health
    /// checks used to run before recording started — a 60-minute hold had none. Every
    /// 5s this compares the last-buffer timestamp; >3s of no audio mid-recording means
    /// the tap/route died (AirPods handoff, config change) and the user must know NOW,
    /// not after dictating 40 minutes into a dead mic. The overlay flips to a red
    /// banner while audio is dead and back to the recording pill if it recovers.
    private func startRecordingWatchdog() {
        recordingWatchdogTimer?.invalidate()
        watchdogWarnedDeadAudio = false
        recordingWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isPressed else { return }
            let deadFor = self.recorder.secondsSinceLastBuffer()
            let peak = self.recorder.peakSinceLastCheck()
            // Two dead shapes (codex review #4): NO buffers (tap/route died), and
            // buffers of pure digital silence (muted mic / stale route still
            // delivering zeros — the 2026-07-25 lost VS Code dictation). A live mic's
            // noise floor peaks well above 0.001; zeros don't. Two consecutive silent
            // ticks (10s) before warning so a quiet pause can't false-positive.
            let buffersDead = deadFor > 3.0
            if buffersDead {
                self.watchdogSilentTicks = 0
            } else if peak < 0.001 {
                self.watchdogSilentTicks += 1
            } else {
                self.watchdogSilentTicks = 0
            }
            let silentMic = self.watchdogSilentTicks >= 2
            if buffersDead || silentMic {
                if !self.watchdogWarnedDeadAudio {
                    self.watchdogWarnedDeadAudio = true
                    DiagnosticLogger.shared.log(String(
                        format: "WATCHDOG: %@ mid-recording (no-buffers %.1fs, peak %.4f)",
                        buffersDead ? "capture dead" : "mic delivering silence", deadFor, peak))
                    self.recordingOverlay.show(
                        state: .error("Mic went silent: audio is not being captured"),
                        autoHideError: false)
                    if buffersDead {
                        self.recorder.recoverDeadCaptureDuringRecording()
                    }
                }
            } else if self.watchdogWarnedDeadAudio {
                self.watchdogWarnedDeadAudio = false
                DiagnosticLogger.shared.log("WATCHDOG: audio resumed")
                self.recordingOverlay.show(state: .recording, recorder: self.recorder)
            }
        }
    }

    private func stopRecordingWatchdog() {
        recordingWatchdogTimer?.invalidate()
        recordingWatchdogTimer = nil
        watchdogWarnedDeadAudio = false
        watchdogSilentTicks = 0
    }

    private func handleRecordingStop() {
        guard isPressed else { return }
        isPressed = false

        stopRecordingWatchdog()

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
        // Hard deadline = the EXTENDED cap (2026-07-25): the policy's decided wait stays ≤220ms
        // for quiet releases and only exceeds it when trailing speech energy shows the speaker
        // finishing a word across the release — the deadline must not amputate that extension
        // (a word spoken across release died at the old 220ms ceiling: "…the last word, ⟨release⟩
        // selectors" → transcript ended at "word."). Latency for quiet releases is unchanged;
        // the deadline is the runaway guard only.
        let capMs = PostBufferPolicy.defaultExtendedCapMs
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
            if case .captureFailed = failure {
                DiagnosticLogger.shared.log(
                    "Finalize: zero-payload take; capture failed with zero PCM frames")
            }
            // A 0-sample or silent primary means a dead engine, not an accidental tap —
            // kick a rebuild now regardless of how the dictation resolves.
            switch failure {
            case .captureFailed:
                recorder.ensureAudioHealthy()
            case .silent:
                recorder.ensureAudioHealthy()
            default:
                break
            }
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
            }
            // Keep the wav on a SILENT failure even when saving is off (2026-07-25
            // audit F11): a silent capture means the mic/route is broken, and the
            // audio is the diagnostic evidence. Only genuine accidental taps
            // (.tooShort with real samples) honor the opt-out deletion.
            let isSilentFailure: Bool
            if case .silent = failure { isSilentFailure = true } else { isSilentFailure = false }
            let isCaptureFailure: Bool
            if case .captureFailed = failure {
                isCaptureFailure = true
                try? FileManager.default.removeItem(at: audioURL)
            } else {
                isCaptureFailure = false
            }
            if !DevMode.effectiveSaveRecordings(config) && !isSilentFailure {
                try? FileManager.default.removeItem(at: audioURL)
            }
            if isCaptureFailure {
                statusBar.state = .captureFailed
                statusBar.buildMenu()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if self.statusBar.state == .captureFailed {
                        self.statusBar.state = .idle
                        self.statusBar.buildMenu()
                    }
                }
                recordingOverlay.show(state: .error("Capture failed: please try again"))
                showCaptureFailureAlert()
            } else if isSilentFailure {
                // Empty sidecar (review #6): the kept wav is diagnostic evidence,
                // NOT a recoverable dictation — without this the launch sweep
                // re-offers known-silent audio every launch and masks real orphans.
                RecordingStore.saveTranscription(text: "", for: audioURL)
            }
            RecordingStore.clearSentinel()
            focusCapture.reset()
            // I4: a gate-failed dictation never consumes its OCR, so clear it and invalidate any
            // in-flight capture — otherwise this recording's screenContextText survives and biases
            // the NEXT dictation's prompt with stale on-screen text.
            screenContextText = nil
            screenCaptureGeneration = UUID()
            if isSilentFailure {
                // The user held the key and spoke into a dead mic — say so (F12:
                // gate failures were a silent no-op; the empty-transcript fix
                // didn't cover this path).
                statusBar.state = .noSpeech
                statusBar.buildMenu()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if self.statusBar.state == .noSpeech {
                        self.statusBar.state = .idle
                        self.statusBar.buildMenu()
                    }
                }
                recordingOverlay.show(state: .error("No speech captured: check your mic"))
            } else {
                statusBar.state = .idle
                recordingOverlay.hide()
            }
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
        DiagnosticLogger.shared.log(
            "Finalize: prependSpace=\(capturedPrependSpace) midSentence=\(TextPipeline.isMidSentence(contextBefore: capturedInputText)) ctxLen=\(capturedInputText?.count ?? 0)")

        // Snapshot ALL config-derived state on main before crossing into the async Task.
        // Accessing self.config.* from a background queue is a torn-read race — Config is a
        // struct so reads and writes are not atomic across threads.
        let maxRecordings = (config.preserveAllRecordings?.value ?? false) ? 0 : Config.effectiveMaxRecordings(config.maxRecordings)
        // Recordings privacy: persisting audio + transcripts is opt-in (2026-07-14).
        let keepRecording = DevMode.effectiveSaveRecordings(config)
        // Resolved through the one shared default (Michael 2026-08-12). The full history of
        // why a missing key means `.off` — including the reverted 2026-07-26 flip to
        // `.hybrid` and the text corruption it caused — lives on
        // `Config.effectivePunctuationMode`, which every consumer (here, Settings, Help,
        // ProcessCommand) now reads. Do not reintroduce a site-local `??` default.
        let mode = config.effectivePunctuationMode
        let glossary = Config.loadVocabulary()
        let overrides = Config.loadOverrides()
        let capturedStyleMode = recordingStyleMode
        // Provenance snapshot for the .meta.json sidecar — engine/model from the ACTIVE
        // transcriber (not config, which can disagree after a model fallback).
        let metaEngine = activeEngineID
        let metaDevice = recorder.currentCaptureDeviceName()
        let metaTargetApp = recordingTargetBundleID

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

                let pipelineContext = TextPipeline.Input(
                    punctuationMode: mode,
                    cursorContextText: capturedInputText,
                    screenContextText: capturedScreenText,
                    styleMode: capturedStyleMode,
                    glossaryWords: glossary
                )
                let prompt = TextPipeline.assemblePromptHints(input: pipelineContext)
                let makeInput: (String, Int) -> TextPipeline.Input = { raw, sampleCount in
                    TextPipeline.Input(
                        raw: raw,
                        punctuationMode: mode,
                        cursorContextText: capturedInputText,
                        screenContextText: capturedScreenText,
                        styleMode: capturedStyleMode,
                        glossaryWords: glossary,
                        overrides: overrides,
                        audioDurationSeconds: Double(sampleCount) / 16000.0
                    )
                }

                if !transcriber.isLoaded {
                    DiagnosticLogger.shared.log(
                        "Finalize: dictation waiting on model load (cold start)")
                    DispatchQueue.main.async {
                        self.recordingOverlay.updateStreamingText("Loading speech model…")
                    }
                }

                let (primaryRaw, reusedPartial) = try await FinalizePipeline.resolveRaw(
                    reuseDecision: reuseDecision
                ) {
                    try await transcriber.transcribe(
                        audioURL: audioURL, samples: samples, prompt: prompt)
                }
                if reusedPartial {
                    DiagnosticLogger.shared.log(
                        "T2.3: reused last streaming partial (skipped final inference)")
                }
                let text = TextPipeline.run(
                    makeInput(primaryRaw, samples.count),
                    precomputedPrompt: .some(prompt)).finalText
                RecordingStore.finishRecording(
                    audioURL: audioURL, keep: keepRecording, raw: primaryRaw, text: text,
                    meta: RecordingStore.RecordingMeta(
                        appVersion: SpeakFree.version,
                        engine: metaEngine,
                        model: transcriber.modelID,
                        inputDevice: metaDevice,
                        date: ISO8601DateFormatter().string(from: Date()),
                        durationSeconds: Double(samples.count) / 16_000.0,
                        transcriptChars: text.count,
                        targetApp: metaTargetApp,
                        transcriptionDiagnostics: transcriber.lastDiagnostics
                    ))
                RecordingStore.clearSentinel()
                if keepRecording && maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    if keepRecording {
                        self.statusBar.noteFinishedRecording(url: audioURL, text: text)
                    }
                    self.presentFinalizedText(
                        text,
                        sampleCount: samples.count,
                        stopTime: stopTime,
                        prependSpace: capturedPrependSpace,
                        contextBefore: capturedInputText,
                        element: capturedElement
                    )
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

    private func presentFinalizedText(
        _ text: String,
        sampleCount: Int,
        stopTime: Double,
        prependSpace: Bool,
        contextBefore: String?,
        element: AXUIElement?
    ) {
        recordingOverlay.hide()
        if !text.isEmpty {
            let insertText = FinalizePipeline.composeInsertText(
                text, prependSpace: prependSpace)
            let spacing = TextInserter.spacingDiagnosis(
                contextBefore: contextBefore, insertText: insertText)
            DiagnosticLogger.shared.log(
                "Insertion boundary: prev=\(TextInserter.charClass(contextBefore?.last)) "
                    + "first=\(TextInserter.charClass(insertText.first)) → \(spacing.rawValue)")
            lastTranscription = text
            let audioSeconds = Double(sampleCount) / 16_000.0
            UsageStats.shared.recordDictation(
                characters: text.count, audioSeconds: audioSeconds)
            inserter.onSecureInputFallback = { text, reason in
                self.statusBar.state = .secureInputCopied
                self.statusBar.buildMenu()
                switch reason {
                case .axTimeoutMayHaveCommitted:
                    // The AX write MAY have landed — never prompt a paste or auto-retry
                    // here, both risk a duplicate. Checkmark only, as before.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.statusBar.state = .idle
                        self.statusBar.buildMenu()
                    }
                case .secureInput:
                    // Definitely NOT inserted: show the retry dialog (Michael 2026-08-12)
                    // and auto-insert the moment Secure Input clears.
                    self.beginSecureInputRetry(text: text)
                }
            }
            let pasted = inserter.insert(
                text: insertText,
                refocusing: element,
                onFocusLost: {
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
                lastInsertionTail = String(((contextBefore ?? "") + insertText).suffix(500))
                lastInsertionBundleID =
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                lastInsertionAt = Date()
                lastInsertionElement = element
                lastInsertionInteractionGeneration = currentUserInteractionGeneration()
                let elapsed = CFAbsoluteTimeGetCurrent() - stopTime
                DiagnosticLogger.shared.log(
                    "Transcription complete: \(String(format: "%.2f", elapsed))s "
                        + "from key-release to text-inserted, \(text.count) chars")
                statusBar.state = .idle
                statusBar.buildMenu()
            }
        } else {
            let audioSeconds = Double(sampleCount) / 16_000.0
            DiagnosticLogger.shared.log(String(
                format: "Transcription EMPTY, nothing inserted (%.1fs of audio)",
                audioSeconds))
            statusBar.state = .noSpeech
            statusBar.buildMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.statusBar.state == .noSpeech {
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
        }
    }

    private func showCaptureFailureAlert() {
        let now = Date()
        guard lastTranscriptionFailureAlert.map({ now.timeIntervalSince($0) > 300 }) ?? true else {
            return
        }
        lastTranscriptionFailureAlert = now
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Capture Failed"
        alert.informativeText = "No audio reached the recorder. Please try again. "
            + "If this repeats, check that the selected microphone is connected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    /// Background auto-recovery: transcribe each orphan serially, but only START one
    /// while the app is idle — the engines serialize inference, so a recovery chunk in
    /// flight would queue a live dictation behind it. Busy → poll again in 30s.
    private func autoRecoverOrphans(_ urls: [URL]) {
        var queue = urls
        func next() {
            guard let url = queue.first else { return }
            let busy = isPressed || statusBar.state == .recording || statusBar.state == .transcribing
            if busy {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { next() }
                return
            }
            queue.removeFirst()
            guard let transcriber = self.transcriber else { return }
            Task.detached(priority: .utility) { [weak self] in
                do {
                    let text = try await transcriber.transcribeFile(
                        url: url, progressHandler: { _, _, _ in }, isCancelled: { false })
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    RecordingStore.saveTranscription(text: trimmed, for: url)
                    DiagnosticLogger.shared.log(
                        "Recovery: auto-transcribed \(url.lastPathComponent) (\(trimmed.count) chars)"
                        + (trimmed.isEmpty ? " — silent/room tone" : " — in Recent Dictations"))
                } catch {
                    DiagnosticLogger.shared.log(
                        "Recovery: auto-transcribe FAILED for \(url.lastPathComponent): \(error.localizedDescription) — will retry next launch")
                }
                await MainActor.run { [weak self] in
                    guard self != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { next() }
                }
            }
        }
        DispatchQueue.main.async { next() }
    }

    /// MANUAL crash recovery (2026-07-25): transcribe the orphaned wav through the chunked
    /// file path (no 30-min cap), save the transcript sidecar (so the orphan leaves the
    /// sweep and appears in Recent Dictations), and copy the text to the clipboard.
    /// Superseded by autoRecoverOrphans for the launch path; kept for explicit invocations.
    public func recoverOrphan(audioURL: URL) {
        guard statusBar.state == .idle || statusBar.state == .ready else {
            // Busy (recording/transcribing). The menu entry persists — retry later.
            DiagnosticLogger.shared.log("Recovery: busy (\(statusBar.state)) — try again when idle")
            return
        }
        guard let transcriber = transcriber else {
            DiagnosticLogger.shared.log("Recovery: no transcriber loaded — cannot recover")
            return
        }
        statusBar.state = .transcribing
        statusBar.buildMenu()
        Task.detached { [weak self] in
            do {
                let text = try await transcriber.transcribeFile(
                    url: audioURL, progressHandler: { _, _, _ in }, isCancelled: { false })
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    guard let self = self else { return }
                    // A dictation may have started during a long recovery (review #7):
                    // only touch shared UI state and the clipboard if the status is
                    // still OUR .transcribing; the transcript sidecar is saved either
                    // way and reachable via Recent Dictations.
                    let stillOurs = self.statusBar.state == .transcribing
                    if trimmed.isEmpty {
                        DiagnosticLogger.shared.log(
                            "Recovery: \(audioURL.lastPathComponent) transcribed EMPTY (silent capture)")
                        // Sidecar the emptiness too, so the sweep stops re-offering it.
                        RecordingStore.saveTranscription(text: "", for: audioURL)
                        self.statusBar.clearCrashRecovery()
                        guard stillOurs else { return }
                        self.statusBar.state = .noSpeech
                        self.statusBar.buildMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if self.statusBar.state == .noSpeech {
                                self.statusBar.state = .idle
                                self.statusBar.buildMenu()
                            }
                        }
                        return
                    }
                    RecordingStore.saveTranscription(text: trimmed, for: audioURL)
                    self.statusBar.clearCrashRecovery()
                    guard stillOurs else {
                        DiagnosticLogger.shared.log(
                            "Recovery: transcribed \(audioURL.lastPathComponent) (\(trimmed.count) chars) while a dictation was active; text is in Recent Dictations")
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(trimmed, forType: .string)
                    self.lastTranscription = trimmed
                    DiagnosticLogger.shared.log(
                        "Recovery: transcribed \(audioURL.lastPathComponent) — \(trimmed.count) chars, copied to clipboard")
                    self.statusBar.state = .copiedToClipboard
                    self.statusBar.buildMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.statusBar.state == .copiedToClipboard {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    DiagnosticLogger.shared.log(
                        "Recovery FAILED for \(audioURL.lastPathComponent): \(error.localizedDescription)")
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
        }
    }

    public func reprocess(audioURL: URL) {
        // `.ready` is the state before the first dictation of a session, so gating on `.idle`
        // alone made every Recent Dictations click a silent no-op until you had dictated once
        // (2026-08-01). Both states mean "not busy"; the busy ones below are the real exclusion.
        guard statusBar.state == .idle || statusBar.state == .ready else {
            DiagnosticLogger.shared.log(
                "Reprocess: ignored — status bar is \(statusBar.state), not idle/ready")
            return
        }

        // Read saved transcription text — no need to re-transcribe
        let textURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        guard let text = try? String(contentsOf: textURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Reprocess: no saved transcription for \(audioURL.lastPathComponent)")
            return
        }

        lastTranscription = text

        // Insert into the frontmost window (Michael, 2026-07-25 — was clipboard-only).
        // The status-bar menu has just closed; give macOS a beat to return key focus
        // to the user's app before the AX read / synthetic paste, or the insert
        // targets the dying menu session. Clipboard remains the fallback whenever
        // insertion can't land (no focused element, focus lost, secure input).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            let copyFallback = {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.statusBar.state = .copiedToClipboard
                self.statusBar.buildMenu()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
            let inserted = self.inserter.insert(text: text, onFocusLost: copyFallback)
            if inserted {
                DiagnosticLogger.shared.log(
                    "Reprocess: inserted \(text.count) chars from recent dictation")
            } else if self.statusBar.state != .copiedToClipboard {
                copyFallback()
            }
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
