import AppKit
import ApplicationServices
import Sparkle

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyManager: HotkeyManager?
    var recorder: AudioRecorder!
    var transcriber: Transcriber!
    var inserter: TextInserter!
    var config: Config!
    var isPressed = false
    var isReady = false
    public var lastTranscription: String?
    private var recordingOverlay = RecordingOverlay()
    private var correctionMonitor = CorrectionMonitor()
    private var settingsViewModel: SettingsViewModel?

    // Sparkle auto-updater — checks for updates on launch and periodically
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // The AXUIElement focused when recording started — used to refocus before pasting
    private var recordingSourceElement: AXUIElement?
    // Text before cursor at recording start — passed to whisper as context prompt
    private var recordingContextText: String?
    // Screen OCR text captured at recording start (opt-in)
    private var screenContextText: String?
    private let screenContextLock = NSLock()

    // Streaming transcription: periodic inference during recording
    private var streamingTimer: Timer?
    private var streamingText: String = ""
    private var isStreamingInFlight = false  // prevents overlapping inference runs
    /// Text that has been "committed" to display — we won't change it even if re-inference differs.
    /// New sentences start on a new line so existing lines don't reflow.
    private var committedStreamingText: String = ""
    /// Serial queue that ensures streaming and final transcriptions never overlap on the whisper context.
    private let whisperSerialQueue = DispatchQueue(label: "com.speakfree.whisper-serial", qos: .userInitiated)

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

        let maxRecordings = Config.effectiveMaxRecordings(config.maxRecordings)
        if maxRecordings > 0 {
            RecordingStore.prune(maxCount: maxRecordings)
        }

        // One-time migration: clean garbage auto-learned entries
        DispatchQueue.main.sync {
            VocabularyMigration.runIfNeeded()
        }

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

        transcriber = Transcriber(modelSize: effectiveModelSize, language: config.language)
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)
        DiagnosticLogger.shared.log("Model loaded: \(effectiveModelSize)")

        // Configure pre-buffer
        recorder.preBufferEnabled = config.preBuffer?.value ?? true

        // Configure model persistence
        transcriber.engine.keepModelLoaded = config.keepModelLoaded ?? "auto"
        transcriber.engine.startMemoryPressureMonitoring()

        DispatchQueue.main.async {
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.buildMenu()
        }

        if Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        Permissions.ensureMicrophone()

        // On upgrade, the binary changes so macOS invalidates the accessibility trust.
        // Reset the stale entry so the prompt appears fresh instead of silently failing.
        if Permissions.didUpgrade() {
            print("Upgrade detected — resetting Accessibility trust")
            Permissions.resetAccessibility()
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
    }

    /// The model size currently loaded by the transcriber.
    public var activeModelSize: String { transcriber?.modelSize ?? config.modelSize }

    public func reloadConfig() {
        config = Config.load()
        var effectiveModelSize = config.modelSize
        if config.language != "en" && WhisperLanguage.isEnglishOnly(config.modelSize) {
            effectiveModelSize = WhisperLanguage.multilingualModel(for: config.modelSize)
            print("Language \(config.language) requires multilingual model — using \(effectiveModelSize)")
        }

        if !Transcriber.modelExists(modelSize: effectiveModelSize) {
            // Don't auto-download — keep the current transcriber running.
            // The settings UI shows the download prompt inline.
            print("Model \(effectiveModelSize) not on disk — keeping current model (\(activeModelSize))")
            // Still reload hotkey and other settings
            reloadHotkeyAndSettings()
            return
        }

        finishReloadConfig(effectiveModelSize: effectiveModelSize)
    }

    private func finishReloadConfig(effectiveModelSize: String) {
        transcriber = Transcriber(modelSize: effectiveModelSize, language: config.language)
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

        // Configure model persistence
        transcriber.engine.keepModelLoaded = config.keepModelLoaded ?? "auto"
        transcriber.engine.startMemoryPressureMonitoring()

        reloadHotkeyAndSettings()
        print("Config reloaded: hotkey=\(KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)) model=\(effectiveModelSize)")
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
           let rangeValue = rangeRef {
            var range = CFRange()
            // swiftlint:disable:next force_cast
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

        // Verify subsystems are healthy before every recording
        recorder.ensureAudioHealthy()
        hotkeyManager?.ensureTapHealthy()

        // Capture focused element before anything else changes
        captureFocusedElement()

        // Capture screen context in background if enabled
        if config.screenContext?.value == true {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let text = ScreenContext.captureAndRecognize()
                self?.screenContextLock.lock()
                self?.screenContextText = text
                self?.screenContextLock.unlock()
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
        screenContextLock.lock()
        screenContextText = nil
        screenContextLock.unlock()
        statusBar.state = .idle
        recordingOverlay.hide()
        statusBar.buildMenu()
    }

    private func handleRecordingStop() {
        guard isPressed else { return }
        isPressed = false
        let stopTime = CFAbsoluteTimeGetCurrent()

        // Stop streaming timer and clear streaming state
        stopStreamingTimer()

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
        screenContextLock.lock()
        let capturedScreenText = screenContextText
        screenContextText = nil
        screenContextLock.unlock()
        recordingSourceElement = nil
        recordingContextText = nil

        // Use whisperSerialQueue to ensure any in-flight streaming inference finishes first
        whisperSerialQueue.async { [weak self] in
            guard let self = self else { return }
            let maxRecordings = Config.effectiveMaxRecordings(self.config.maxRecordings)
            do {
                // Build Whisper prompt. Only the final 224 tokens (~800 chars) matter.
                // Whisper mimics the style of whatever ENDS the prompt, so put the
                // user's own text last — this makes output match their writing style
                // (capitalization, punctuation, formality).
                let prompt: String? = {
                    var parts: [String] = []
                    // Instructions first (furthest from end = least style influence)
                    let mode = self.config.spokenPunctuation ?? .off
                    if mode == .spoken || mode == .hybrid {
                        parts.append("Spoken punctuation: comma, period, question mark, exclamation mark, semicolon, colon, dash, hyphen, new line.")
                    }
                    if let vocab = Config.loadVocabulary() {
                        parts.append("Glossary: \(vocab).")
                    }
                    if let screen = capturedScreenText {
                        parts.append(screen)
                    }
                    // User's text LAST — whisper will match this style
                    if let input = capturedInputText {
                        parts.append(input)
                    }
                    return parts.isEmpty ? nil : parts.joined(separator: " ")
                }()
                let raw = try self.transcriber.transcribe(audioURL: audioURL, samples: samples, prompt: prompt)
                let mode = self.config.spokenPunctuation ?? .off
                let text = (mode == .spoken || mode == .hybrid) ? TextPostProcessor.process(raw, hybrid: mode == .hybrid) : raw
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
                DispatchQueue.main.async {
                    self.recordingOverlay.hide()
                    print("Error: Transcription failed")
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
        }
    }

    // MARK: - Streaming Transcription

    private func startStreamingTimer() {
        guard config.streamingEnabled?.value ?? true else { return }
        guard transcriber.engine.isLoaded else { return }
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
        recordingOverlay.clearStreamingText()
    }

    private func processStreamingChunk() {
        guard isPressed, !isStreamingInFlight else { return }

        let currentSamples = recorder.currentSamples()
        // Need at least 1 second of audio for meaningful transcription
        guard currentSamples.count > 16000 else { return }

        isStreamingInFlight = true

        let language = config.language
        let suppressRegex = transcriber.suppressAutoPunctuation ? "[,\\.\\?!;:\\-—]" : nil

        whisperSerialQueue.async { [weak self] in
            guard let self = self else { return }
            // Re-check: user may have released hotkey while we waited for the queue
            guard self.isPressed else {
                DispatchQueue.main.async { self.isStreamingInFlight = false }
                return
            }
            do {
                let partial = try self.transcriber.engine.transcribeStreaming(
                    samples: currentSamples,
                    language: language,
                    suppressRegex: suppressRegex,
                    onPartialResult: { text in
                        // Build display text with sentence breaks on new lines
                        let displayText = self.buildStableDisplayText(from: text)
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
        statusBar.state = .transcribing

        // Use the element captured when the menu opened (before it stole focus) — no delay needed
        let capturedElement = statusBar.elementBeforeMenuOpen
        statusBar.elementBeforeMenuOpen = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let mode = self.config.spokenPunctuation ?? .off
                let reprocessPrompt: String? = (mode == .spoken || mode == .hybrid)
                    ? "Spoken punctuation: comma, period, question mark, exclamation mark, semicolon, colon, dash, hyphen, ellipsis, new line."
                    : nil
                let raw = try self.transcriber.transcribe(audioURL: audioURL, samples: nil, prompt: reprocessPrompt)
                let text = (mode == .spoken || mode == .hybrid) ? TextPostProcessor.process(raw, hybrid: mode == .hybrid) : raw
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        let insertText = self.inserter.shouldPrependSpace(before: capturedElement) ? " " + text : text
                        self.lastTranscription = text
                        let pasted = self.inserter.insert(text: insertText, refocusing: capturedElement, onFocusLost: {
                            self.statusBar.state = .copiedToClipboard
                            self.statusBar.buildMenu()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.statusBar.state = .idle
                                self.statusBar.buildMenu()
                            }
                        })
                        if pasted {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    } else {
                        self.statusBar.state = .idle
                        self.statusBar.buildMenu()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("Reprocess error: \(error.localizedDescription)")
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
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
