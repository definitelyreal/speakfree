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
    private var correctionMonitor = CorrectionMonitor()
    private var settingsViewModel: SettingsViewModel?
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

    // Streaming transcription: periodic inference during recording
    private var streamingTimer: Timer?
    private var streamingText: String = ""
    private var isStreamingInFlight = false  // prevents overlapping inference runs
    /// Text that has been "committed" to display — we won't change it even if re-inference differs.
    /// New sentences start on a new line so existing lines don't reflow.
    private var committedStreamingText: String = ""
    /// Monotonically-increasing token bumped every time streaming stops. Stale partial-result
    /// callbacks that arrive on main after recording ended compare against this and are dropped.
    private var streamingGeneration: UInt = 0

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        recorder = AudioRecorder()
        inserter = TextInserter()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    private func setup() {
        do {
            try setupInner()
        } catch {
            print("Fatal setup error: \(error.localizedDescription)")
        }
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

        // Resolve the engine + the model identifier it should load. Whisper uses a model-size
        // string (with multilingual upgrade + on-disk fallback chain); Parakeet uses its own
        // model id (downloaded on first use by FluidAudio — no whisper-style fallback chain).
        // Compute the EFFECTIVE engine id once, honoring SPEAKFREE_ENGINE the same way
        // EngineFactory does, so engine creation and model-id selection can't disagree.
        let engineID = effectiveEngineID
        let modelID: String
        if engineID == "parakeet" {
            modelID = config.parakeetModel ?? "parakeet-tdt-0.6b-v3"
        } else {
            // Determine effective model (multilingual if needed)
            var effectiveModelSize = config.modelSize
            if config.language != "en" && WhisperLanguage.isEnglishOnly(config.modelSize) {
                effectiveModelSize = WhisperLanguage.multilingualModel(for: config.modelSize)
                print("Language \(config.language) requires multilingual model — using \(effectiveModelSize)")
            }

            // Model fallback chain
            if !Transcriber.modelExists(modelSize: effectiveModelSize) {
                // Fallback 1: if we wanted multilingual but only have .en, use .en
                if effectiveModelSize != config.modelSize && Transcriber.modelExists(modelSize: config.modelSize) {
                    print("Multilingual model \(effectiveModelSize) not found — using \(config.modelSize) as fallback")
                    effectiveModelSize = config.modelSize
                }
                // Fallback 2: try any model already on disk
                else if let anyModel = findAnyDownloadedModel() {
                    print("Model \(effectiveModelSize) not found — using \(anyModel) as fallback")
                    effectiveModelSize = anyModel
                }
                // Fallback 3: no model at all — must download with progress dialog
                else {
                    let modelToDownload = effectiveModelSize
                    DispatchQueue.main.sync {
                        ModelDownloadController.downloadModel(modelToDownload) { _ in }
                    }
                    // After download, verify the model is now available
                    if !Transcriber.modelExists(modelSize: effectiveModelSize) {
                        print("Model download failed or was cancelled — cannot proceed")
                    }
                }
            }
            modelID = effectiveModelSize
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
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: 0.5)
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
            self?.startListening()
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
        print("openwisprmod v\(OpenWispr.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        print("Ready.")
        DiagnosticLogger.shared.log("Ready — hotkey=\(hotkeyDesc) model=\(config.modelSize)")

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

    /// The effective engine id, honoring SPEAKFREE_ENGINE the same way EngineFactory does.
    /// Single source of truth so engine creation, model-id selection, and activeEngineID
    /// tracking can never disagree (e.g. building Parakeet but loading a whisper model size).
    private var effectiveEngineID: String {
        ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"] ?? config.engine ?? "whisper"
    }

    public func reloadConfig() {
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
        alert.informativeText = "openwisprmod needs Accessibility access to type your dictation.\n\nClick \"Open Settings\" below, then find openwisprmod in the list and turn it on. Come back here when done — it will start automatically."
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

        // Capture key-release time NOW — finalizeRecording is called 300ms later, so
        // measuring inside it would undercount the post-buffer delay in the latency log.
        let keyReleaseTime = CFAbsoluteTimeGetCurrent()

        // Keep recording for 300ms after key release to capture trailing audio.
        // AVAudioEngine buffers audio in chunks — releasing fn mid-word loses
        // the tail of the last buffer. This post-buffer ensures the last word
        // isn't cut off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.finalizeRecording(keyReleaseTime: keyReleaseTime)
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

        // Snapshot ALL config-derived state on main before crossing into the async Task.
        // Accessing self.config.* from a background queue is a torn-read race — Config is a
        // struct so reads and writes are not atomic across threads.
        let maxRecordings = (config.preserveAllRecordings?.value ?? false) ? 0 : Config.effectiveMaxRecordings(config.maxRecordings)
        let mode = config.spokenPunctuation ?? .off
        let glossary = Config.loadVocabulary()
        let capturedStyleMode = recordingStyleMode

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

                // Build pipeline inputs with placeholder raw; we need promptHints
                // before whisper runs, then re-run with the real raw text.
                let makeInput: (String) -> TextPipeline.Input = { raw in
                    TextPipeline.Input(
                        raw: raw,
                        cursorContextText: capturedInputText,
                        screenContextText: capturedScreenText,
                        punctuationMode: mode,
                        styleMode: capturedStyleMode,
                        glossaryWords: glossary
                    )
                }
                let prompt = TextPipeline.assemblePromptHints(input: makeInput(""))
                let raw = try await transcriber.transcribe(audioURL: audioURL, samples: samples, prompt: prompt)
                RecordingStore.saveRaw(text: raw, for: audioURL)
                let text = TextPipeline.run(makeInput(raw)).finalText
                RecordingStore.saveTranscription(text: text, for: audioURL)

                RecordingStore.clearSentinel()
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }

                DispatchQueue.main.async {
                    self.recordingOverlay.hide()
                    if !text.isEmpty {
                        // Prepend space if cursor follows a non-whitespace character
                        let insertText = self.inserter.shouldPrependSpace(before: capturedElement) ? " " + text : text
                        self.lastTranscription = text
                        // Record usage stats
                        let audioSeconds = Double(samples.count) / 16000.0
                        UsageStats.shared.recordDictation(characters: text.count, audioSeconds: audioSeconds)
                        let pasted = self.inserter.insert(text: insertText, refocusing: capturedElement, onFocusLost: {
                            self.statusBar.state = .copiedToClipboard
                            self.statusBar.buildMenu()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.statusBar.state = .idle
                                self.statusBar.buildMenu()
                            }
                        })
                        if pasted {
                            let elapsed = CFAbsoluteTimeGetCurrent() - stopTime
                            DiagnosticLogger.shared.log("Transcription complete: \(String(format: "%.2f", elapsed))s from key-release to text-inserted, \(text.count) chars")
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                            // Monitor for word corrections for 10 seconds (opt-in)
                            if self.config.rememberWords?.value == true, let el = capturedElement {
                                self.correctionMonitor.start(element: el, pastedText: text) { wrong, right in
                                    self.offerCorrection(wrong: wrong, right: right)
                                }
                            }
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
        committedStreamingText = ""
        isStreamingInFlight = false
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.processStreamingChunk()
        }
        DiagnosticLogger.shared.log("Streaming: timer started (2.0s interval)")
    }

    private func stopStreamingTimer() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingText = ""
        committedStreamingText = ""
        isStreamingInFlight = false
        streamingGeneration &+= 1  // invalidate any in-flight partial-result callbacks
        recordingOverlay.clearStreamingText()
    }

    private func processStreamingChunk() {
        guard isPressed, !isStreamingInFlight else { return }

        let currentSamples = recorder.currentSamples()
        // Need at least 1 second of audio for meaningful transcription
        guard currentSamples.count > 16000 else { return }

        isStreamingInFlight = true

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
        let trimmed = rawText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return committedStreamingText }

        // If the new text is shorter than committed, keep committed (prevents regression)
        guard trimmed.count >= committedStreamingText.replacingOccurrences(of: "\n", with: " ").count else {
            return committedStreamingText
        }

        // Find the portion of text beyond what we've committed
        let committedFlat = committedStreamingText.replacingOccurrences(of: "\n", with: " ")
        let newPortion: String
        if trimmed.hasPrefix(committedFlat) {
            newPortion = String(trimmed.dropFirst(committedFlat.count)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.count > committedFlat.count {
            // Text diverged slightly but is longer — take the new tail
            newPortion = String(trimmed.dropFirst(committedFlat.count)).trimmingCharacters(in: .whitespaces)
        } else {
            // Text is same length or shorter — show committed
            return committedStreamingText
        }

        if newPortion.isEmpty { return committedStreamingText }

        // Check if the new portion contains complete sentences (ends with .!?)
        // If so, commit everything up to the last sentence end
        var result = committedStreamingText
        if !result.isEmpty && !newPortion.isEmpty {
            result += "\n"
        }
        result += newPortion

        // Commit text through the last sentence-ending punctuation
        if let lastPunct = newPortion.lastIndex(where: { ".!?".contains($0) }) {
            let throughPunct = String(newPortion[...lastPunct])
            if committedStreamingText.isEmpty {
                committedStreamingText = throughPunct
            } else {
                committedStreamingText += "\n" + throughPunct
            }
        }

        return result
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

    private func offerCorrection(wrong: String, right: String) {
        WordMemory.remember(wrong: wrong, right: right)
        print("Remembered: \(wrong) → \(right)")
        statusBar.buildMenu()
    }

    /// Find any downloaded model on disk, returning the model size string (e.g. "base.en").
    private func findAnyDownloadedModel() -> String? {
        let modelsDir = Config.configDir.appendingPathComponent("models")
        return (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path))?
            .first(where: { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") })
            .map { String($0.dropFirst(5).dropLast(4)) }  // "ggml-base.en.bin" → "base.en"
    }
}
