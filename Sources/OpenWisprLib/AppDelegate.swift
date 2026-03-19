import AppKit
import ApplicationServices

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

    // The AXUIElement focused when recording started — used to refocus before pasting
    private var recordingSourceElement: AXUIElement?
    // Text before cursor at recording start — passed to whisper as context prompt
    private var recordingContextText: String?

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

        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

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

        if Permissions.didUpgrade() {
            print("Accessibility: upgrade detected, resetting permissions...")
            Permissions.resetAccessibility()
            Thread.sleep(forTimeInterval: 1)
        }

        if !AXIsProcessTrusted() {
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
            }
        }

        Permissions.ensureMicrophone()

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted — clearing stale entry and re-prompting")
            Permissions.resetAccessibility()
            Thread.sleep(forTimeInterval: 0.5)
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

        if !Transcriber.modelExists(modelSize: config.modelSize) {
            // Auto-download the default model silently — show progress in the menu bar
            DispatchQueue.main.async { self.statusBar.state = .downloading }
            do {
                try ModelDownloader.download(modelSize: config.modelSize)
            } catch {
                print("Model download failed: \(error.localizedDescription)")
                // Not fatal — user can try again via Settings
            }
            DispatchQueue.main.async { self.statusBar.state = .idle }
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
    }

    public func reloadConfig() {
        config = Config.load()
        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

        hotkeyManager?.stop()
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )
        hotkeyManager?.start(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() }
        )

        statusBar.buildMenu()
        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        print("Config reloaded: hotkey=\(hotkeyDesc) model=\(config.modelSize)")
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
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
        if result == .success, let element = elementRef {
            let axElement = element as! AXUIElement
            recordingSourceElement = axElement
            recordingContextText = readTextBeforeCursor(in: axElement)
        } else {
            recordingSourceElement = nil
            recordingContextText = nil
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
           let rangeValue = rangeRef {
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

        // Capture focused element before anything else changes
        captureFocusedElement()

        statusBar.state = .recording
        do {
            // Always write to recordings dir — crash recovery works regardless of maxRecordings
            let outputURL = RecordingStore.newRecordingURL()
            RecordingStore.writeSentinel(recordingURL: outputURL)
            try recorder.startRecording(to: outputURL)
        } catch {
            print("Error: \(error.localizedDescription)")
            RecordingStore.clearSentinel()
            isPressed = false
            recordingSourceElement = nil
            statusBar.state = .idle
        }
    }

    private func handleRecordingStop() {
        guard isPressed else { return }
        isPressed = false

        guard let audioURL = recorder.stopRecording() else {
            RecordingStore.clearSentinel()
            recordingSourceElement = nil
            statusBar.state = .idle
            return
        }

        statusBar.state = .transcribing

        let capturedElement = recordingSourceElement
        let capturedContext = recordingContextText
        recordingSourceElement = nil
        recordingContextText = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let maxRecordings = Config.effectiveMaxRecordings(self.config.maxRecordings)
            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL, prompt: capturedContext)
                let mode = self.config.spokenPunctuation ?? .off
                let text = (mode == .spoken || mode == .hybrid) ? TextPostProcessor.process(raw) : raw
                RecordingStore.saveTranscription(text: text, for: audioURL)

                RecordingStore.clearSentinel()
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }

                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        let pasted = self.inserter.insert(text: text, refocusing: capturedElement, onFocusLost: {
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
                RecordingStore.clearSentinel()
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    print("Error: Transcription failed")
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
        }
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
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                let mode = self.config.spokenPunctuation ?? .off
                let text = (mode == .spoken || mode == .hybrid) ? TextPostProcessor.process(raw) : raw
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        let pasted = self.inserter.insert(text: text, refocusing: capturedElement, onFocusLost: {
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
}
