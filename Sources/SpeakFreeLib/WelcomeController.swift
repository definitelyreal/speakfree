import AppKit
import Foundation

/// First-run onboarding dialog. Shown when the selected model is not downloaded.
class WelcomeController: NSObject, NSWindowDelegate {

    // MARK: - UI

    private var panel: NSPanel!
    private var enginePicker: NSPopUpButton!
    private var modelPicker: NSPopUpButton!
    private var languagePicker: NSPopUpButton!
    private var languageLabel: NSTextField!
    private var downloadButton: NSButton!
    private var pauseButton: NSButton!
    private var stopButton: NSButton!
    private var progressBar: NSProgressIndicator!
    private var percentLabel: NSTextField!
    private var bytesLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var errorLabel: NSTextField!
    private var loginCheckbox: NSButton!
    private var configureButton: NSButton!
    private var startButton: NSButton!

    // MARK: - State

    private var selectedEngine: String = "parakeet"
    private var selectedWhisperModel: String = "large-v3-turbo"
    private var selectedParakeetModel: String = "parakeet-tdt-0.6b-v2"
    private var selectedLanguage: String = "en"
    private var isDownloading = false
    private var isPaused = false
    private var isModelReady = false
    private var whisperCoordinator: ModelDownloadCoordinator?
    private var parakeetTask: Task<Void, Never>?
    /// Identifies the live Parakeet download. Bumped whenever a download starts, is cancelled, or is
    /// paused/stopped; every UI callback captures its generation and no-ops if it no longer matches,
    /// so a late callback from an abandoned task can't write stale progress over a reset panel.
    private var parakeetDownloadGeneration = 0
    private var completion: ((String, String, String, Bool) -> Void)?

    private static let modelSizes: [String: String] = [
        "tiny": "75 MB", "tiny.en": "75 MB",
        "base": "142 MB", "base.en": "142 MB",
        "small": "466 MB", "small.en": "466 MB",
        "medium": "1.5 GB", "medium.en": "1.5 GB",
        "large": "3.1 GB", "large-v1": "3.1 GB", "large-v2": "3.1 GB", "large-v3": "3.1 GB",
        "large-v3-turbo": "1.6 GB",
    ]

    static let purple = NSColor(red: 0.6, green: 0.2, blue: 0.8, alpha: 1.0)

    // MARK: - Public API

    static func show(suggestedEngine: String, suggestedModel: String) -> (engine: String, modelID: String, language: String, shouldContinue: Bool) {
        assert(Thread.isMainThread)
        var result = (engine: "parakeet", modelID: "parakeet-tdt-0.6b-v2", language: "en", shouldContinue: false)
        let controller = WelcomeController()
        controller.applySuggestion(engine: suggestedEngine, model: suggestedModel)
        controller.completion = { engine, model, lang, ok in result = (engine, model, lang, ok) }
        NSApp.showDockIconIfNeeded()
        NSApp.installMinimalMenu()
        controller.buildPanel()
        NSApp.runModal(for: controller.panel)
        return result
    }

    /// Apply the caller's suggested engine + model to the correct slot. Extracted from `show`
    /// (which is a modal run loop and not directly testable). The model MUST land in the slot
    /// matching the engine — the old code filed every suggestion into the whisper slot and ignored
    /// the engine, so a suggested Parakeet model was dropped and onboarding defaulted wrong (UI-A).
    func applySuggestion(engine: String, model: String) {
        selectedEngine = engine
        if engine == "parakeet" {
            selectedParakeetModel = model
        } else {
            selectedWhisperModel = model
        }
    }

    /// The engine + model that `dismiss` would report for the current selection. Internal for tests.
    var currentSelection: (engine: String, model: String) {
        (selectedEngine, selectedEngine == "parakeet" ? selectedParakeetModel : selectedWhisperModel)
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let w: CGFloat = 480
        let h: CGFloat = 475

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to SpeakFree"
        panel.center()
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let c = panel.contentView!

        // ── Header ──────────────────────────────────────────────
        let logoView = LogoView(frame: NSRect(x: 20, y: h - 92, width: 72, height: 72))
        c.addSubview(logoView)

        let attrTitle = NSMutableAttributedString(
            string: "SpeakFree",
            attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                         .foregroundColor: NSColor.labelColor])
        attrTitle.append(NSAttributedString(
            string: "  v\(SpeakFree.version)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .baselineOffset: 7]))
        let titleField = NSTextField(labelWithString: "")
        titleField.attributedStringValue = attrTitle
        titleField.frame = NSRect(x: 103, y: h - 58, width: 340, height: 30)
        c.addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: "Local and open source  •  Nothing leaves your Mac")
        subtitleField.font = NSFont.systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.frame = NSRect(x: 103, y: h - 82, width: 340, height: 18)
        c.addSubview(subtitleField)

        // ── Description ─────────────────────────────────────────
        let desc = NSTextField(wrappingLabelWithString:
            "Hold your hotkey to dictate, release to type. Your words appear wherever your cursor is — no clipboard, no switching apps.")
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.frame = NSRect(x: 20, y: h - 155, width: w - 40, height: 54)
        c.addSubview(desc)

        // ── Engine row ──────────────────────────────────────────
        let engineLabel = NSTextField(labelWithString: "Engine:")
        engineLabel.font = NSFont.systemFont(ofSize: 13)
        engineLabel.frame = NSRect(x: 20, y: h - 192, width: 60, height: 18)
        c.addSubview(engineLabel)

        enginePicker = NSPopUpButton(frame: NSRect(x: 88, y: h - 196, width: 372, height: 26))
        // Parakeet (the default) at the top; Whisper below. engineChanged() reads
        // index 0 == parakeet — keep the two in sync if this order ever changes.
        enginePicker.addItem(withTitle: "Parakeet (Apple Neural Engine) — Recommended")
        enginePicker.addItem(withTitle: "Whisper (CPU/GPU)")
        enginePicker.selectItem(at: 0)
        enginePicker.target = self
        enginePicker.action = #selector(engineChanged)
        c.addSubview(enginePicker)

        // ── Model row ───────────────────────────────────────────
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.font = NSFont.systemFont(ofSize: 13)
        modelLabel.frame = NSRect(x: 20, y: h - 230, width: 60, height: 18)
        c.addSubview(modelLabel)

        modelPicker = NSPopUpButton(frame: NSRect(x: 88, y: h - 234, width: 372, height: 26))
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        c.addSubview(modelPicker)

        // ── Language row ────────────────────────────────────────
        languageLabel = NSTextField(labelWithString: "Language:")
        languageLabel.font = NSFont.systemFont(ofSize: 13)
        languageLabel.frame = NSRect(x: 20, y: h - 268, width: 68, height: 18)
        languageLabel.isHidden = true
        c.addSubview(languageLabel)

        languagePicker = NSPopUpButton(frame: NSRect(x: 88, y: h - 272, width: 372, height: 26))
        languagePicker.target = self
        languagePicker.action = #selector(languageChanged)
        languagePicker.isHidden = true
        c.addSubview(languagePicker)

        // ── Download row ─────────────────────────────────────────
        downloadButton = NSButton(title: "Download Model", target: self, action: #selector(downloadTapped))
        downloadButton.bezelStyle = .rounded
        downloadButton.frame = NSRect(x: 88, y: h - 310, width: 135, height: 26)
        c.addSubview(downloadButton)

        pauseButton = NSButton(title: "⏸︎ Pause", target: self, action: #selector(pauseTapped))
        pauseButton.bezelStyle = .rounded
        pauseButton.frame = NSRect(x: 88, y: h - 310, width: 100, height: 26)
        pauseButton.isHidden = true
        c.addSubview(pauseButton)

        stopButton = NSButton(title: "Cancel", target: self, action: #selector(stopTapped))
        stopButton.bezelStyle = .rounded
        stopButton.frame = NSRect(x: 196, y: h - 310, width: 85, height: 26)
        stopButton.isHidden = true
        c.addSubview(stopButton)

        // ── Status / progress ────────────────────────────────────
        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 88, y: h - 338, width: 352, height: 22)
        c.addSubview(statusLabel)

        progressBar = NSProgressIndicator()
        progressBar.frame = NSRect(x: 88, y: h - 360, width: 300, height: 16)
        progressBar.style = .bar
        progressBar.minValue = 0; progressBar.maxValue = 1.0; progressBar.doubleValue = 0
        progressBar.isHidden = true
        c.addSubview(progressBar)

        percentLabel = NSTextField(labelWithString: "")
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: 393, y: h - 360, width: 47, height: 16)
        percentLabel.isHidden = true
        c.addSubview(percentLabel)

        bytesLabel = NSTextField(labelWithString: "")
        bytesLabel.font = NSFont.systemFont(ofSize: 10)
        bytesLabel.textColor = .secondaryLabelColor
        bytesLabel.frame = NSRect(x: 88, y: h - 378, width: 352, height: 14)
        bytesLabel.isHidden = true
        c.addSubview(bytesLabel)

        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        // Spans the full footer width/height: the Parakeet failure message is multi-line and
        // includes a long, copy-pasteable Terminal command. showError() hides the login checkbox
        // and Start/Configure buttons while this is visible so nothing overlaps (see showError).
        errorLabel.frame = NSRect(x: 20, y: h - 470, width: w - 40, height: 112)
        errorLabel.isSelectable = true  // let users copy the manual-install command from the fallback
        errorLabel.isHidden = true
        c.addSubview(errorLabel)

        // ── Bottom ───────────────────────────────────────────────
        loginCheckbox = NSButton(checkboxWithTitle: "Launch SpeakFree at login", target: nil, action: nil)
        loginCheckbox.font = NSFont.systemFont(ofSize: 12)
        // Default ON for new users (onboarding). applyLoginCheckbox() registers it only when
        // they proceed, so unchecking here still opts out. Reflect an already-enabled state too.
        loginCheckbox.state = .on
        loginCheckbox.frame = NSRect(x: 20, y: 52, width: w - 40, height: 20)
        c.addSubview(loginCheckbox)

        configureButton = NSButton(title: "Configure…", target: self, action: #selector(configureTapped))
        configureButton.bezelStyle = .rounded
        configureButton.isEnabled = false
        configureButton.frame = NSRect(x: w - 222, y: 15, width: 105, height: 28)
        c.addSubview(configureButton)

        startButton = NSButton(title: "Start →", target: self, action: #selector(startTapped))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.isEnabled = false
        startButton.frame = NSRect(x: w - 109, y: 15, width: 94, height: 28)
        c.addSubview(startButton)

        refreshModelPicker()

        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Model / language picker

    private func refreshModelPicker() {
        modelPicker.removeAllItems()
        resetDownloadUI()

        if selectedEngine == "parakeet" {
            for model in EngineCatalog.parakeetModels {
                modelPicker.addItem(withTitle: "\(model.displayName) (\(model.sizeDescription))")
                modelPicker.lastItem?.representedObject = model.id
            }
            if let idx = EngineCatalog.parakeetModels.firstIndex(where: { $0.id == selectedParakeetModel }) {
                modelPicker.selectItem(at: idx)
            }
            if ParakeetModelManager.shared.isModelDownloaded(selectedParakeetModel) { markDownloaded() }
        } else {
            for m in whisperModelOptions() {
                modelPicker.addItem(withTitle: m.label)
                modelPicker.lastItem?.representedObject = m.id
            }
            let opts = whisperModelOptions()
            if let idx = opts.firstIndex(where: { $0.id == selectedWhisperModel }) {
                modelPicker.selectItem(at: idx)
            } else if let idx = opts.firstIndex(where: { $0.isRecommended }) {
                modelPicker.selectItem(at: idx)
            }
            let current = (modelPicker.selectedItem?.representedObject as? String) ?? selectedWhisperModel
            if Transcriber.modelExists(modelSize: current) { markDownloaded() }
        }
        updateLanguagePicker()
    }

    private struct WhisperModelOption {
        let id: String; let label: String; let isRecommended: Bool
    }

    private func whisperModelOptions() -> [WhisperModelOption] {
        let ram = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let rec = ram >= 16 ? "turbo" : ram > 8 ? "small" : "base"
        let raw: [(id: String, mem: String, spd: String, base: String)] = [
            ("tiny.en",        "~230 MB", "~0.2s", "tiny"),
            ("base.en",        "~330 MB", "~0.3s", "base"),
            ("small.en",       "~800 MB", "~0.5s", "small"),
            ("medium.en",      "~2.1 GB", "~1.0s", "medium"),
            ("large-v3-turbo", "~1.6 GB", "~1.1s", "turbo"),
            ("large-v3",       "~3.9 GB", "~2.0s", "large"),
        ]
        return raw.map { m in
            let label = "\(m.id) (\(m.mem), \(m.spd) load)" + (m.base == rec ? " — Recommended" : "")
            return WhisperModelOption(id: m.id, label: label, isRecommended: m.base == rec)
        }
    }

    private func supportedLanguageCodes() -> [String]? {
        if selectedEngine == "parakeet" {
            guard let model = EngineCatalog.parakeetModels.first(where: { $0.id == selectedParakeetModel }),
                  model.supportedLanguages.count > 1 else { return nil }
            return model.supportedLanguages
        } else {
            let current = (modelPicker.selectedItem?.representedObject as? String) ?? selectedWhisperModel
            if current.hasSuffix(".en") { return nil }
            return WhisperLanguage.all.map { $0.id }
        }
    }

    private func updateLanguagePicker() {
        guard languagePicker != nil else { return }
        if let codes = supportedLanguageCodes() {
            languagePicker.isHidden = false; languageLabel.isHidden = false
            languagePicker.removeAllItems()
            for code in codes {
                let name = WhisperLanguage.all.first(where: { $0.id == code })?.name ?? code
                languagePicker.addItem(withTitle: name)
                languagePicker.lastItem?.representedObject = code
            }
            if let idx = codes.firstIndex(of: selectedLanguage) {
                languagePicker.selectItem(at: idx)
            } else {
                languagePicker.selectItem(at: 0); selectedLanguage = codes[0]
            }
        } else {
            languagePicker.isHidden = true; languageLabel.isHidden = true
            selectedLanguage = "en"
        }
    }

    // MARK: - UI state

    private func resetDownloadUI() {
        isDownloading = false; isPaused = false; isModelReady = false
        downloadButton.title = "Download Model"
        downloadButton.isEnabled = true; downloadButton.isHidden = false
        pauseButton.isHidden = true; stopButton.isHidden = true
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        progressBar.isIndeterminate = false; progressBar.doubleValue = 0
        percentLabel.isHidden = true; percentLabel.stringValue = ""
        bytesLabel.isHidden = true; bytesLabel.stringValue = ""
        statusLabel.stringValue = ""; errorLabel.isHidden = true; errorLabel.stringValue = ""
        loginCheckbox.isHidden = false; configureButton.isHidden = false; startButton.isHidden = false
        startButton.isEnabled = false; configureButton.isEnabled = false
        enginePicker.isEnabled = true; modelPicker.isEnabled = true
        if languagePicker != nil { languagePicker.isEnabled = true }
    }

    /// - Parameter autoAdvance: pass `true` only when a download just *completed* (not when a model
    ///   was already present on selection). Shows the ready state briefly, then closes the panel and
    ///   proceeds into the app — the same as pressing Start — so a walked-away install finishes itself
    ///   (and the default-on "Launch at login" checkbox actually registers). Never auto-advances when
    ///   a model was merely found already-downloaded, so switching engines/models stays interactive.
    private func markDownloaded(autoAdvance: Bool = false) {
        isDownloading = false; isPaused = false; isModelReady = true
        downloadButton.title = "✓ Downloaded"; downloadButton.isEnabled = false; downloadButton.isHidden = false
        pauseButton.isHidden = true; stopButton.isHidden = true
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        percentLabel.isHidden = true; bytesLabel.isHidden = true
        errorLabel.isHidden = true; errorLabel.stringValue = ""
        loginCheckbox.isHidden = false; configureButton.isHidden = false; startButton.isHidden = false
        statusLabel.stringValue = autoAdvance ? "Model ready — starting…" : "Model ready."
        startButton.isEnabled = true; configureButton.isEnabled = true
        enginePicker.isEnabled = true; modelPicker.isEnabled = true
        if languagePicker != nil { languagePicker.isEnabled = true }

        if autoAdvance {
            // Brief pause so the "ready" state (purple logo + label) is visible as confirmation, then
            // proceed like Start. Guards: bail if the user switched to a not-yet-downloaded model in
            // the meantime (isModelReady flips false), or already closed the panel some other way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, self.isModelReady, self.panel.isVisible else { return }
                self.applyLoginCheckbox()
                self.dismiss(shouldContinue: true)
            }
        }
    }

    private func showError(_ message: String) {
        isDownloading = false; isPaused = false
        setMenuBarState(.idle)  // stop the menu-bar download wave on failure
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        percentLabel.isHidden = true; bytesLabel.isHidden = true
        downloadButton.title = "Retry"; downloadButton.isEnabled = true; downloadButton.isHidden = false
        pauseButton.isHidden = true; stopButton.isHidden = true
        statusLabel.stringValue = ""
        // The fallback message is multi-line (includes a Terminal command), so the error label
        // expands into the footer zone, so hide the login checkbox and Start/Configure buttons while
        // it shows so nothing overlaps. They are restored when leaving the error state.
        loginCheckbox.isHidden = true; configureButton.isHidden = true; startButton.isHidden = true
        errorLabel.stringValue = message; errorLabel.isHidden = false
        enginePicker.isEnabled = true; modelPicker.isEnabled = true
        if languagePicker != nil { languagePicker.isEnabled = true }
    }

    private func showDownloadingUI(label: String, indeterminate: Bool) {
        isDownloading = true; isPaused = false
        // Reflect the download in the menu-bar icon too (rolling-wave animation), so it's visible even
        // with the panel focused. Cleared back to idle on stop/cancel/error; on success the panel
        // closes and setup takes over, switching the icon to the green "ready" state.
        setMenuBarState(.downloading)
        // Restore footer controls in case a prior error hid them (see showError).
        loginCheckbox.isHidden = false; configureButton.isHidden = false; startButton.isHidden = false
        downloadButton.isHidden = true
        pauseButton.isHidden = false; pauseButton.title = "⏸︎ Pause"
        stopButton.isHidden = false; stopButton.title = indeterminate ? "Cancel" : "Stop"
        statusLabel.stringValue = label
        progressBar.isIndeterminate = indeterminate
        progressBar.doubleValue = 0; progressBar.isHidden = false
        if indeterminate {
            percentLabel.isHidden = true; bytesLabel.isHidden = true
            progressBar.startAnimation(nil)
        } else {
            percentLabel.stringValue = "0%"; percentLabel.isHidden = false
            bytesLabel.isHidden = true  // shown once first bytes arrive
        }
        enginePicker.isEnabled = false; modelPicker.isEnabled = false
        if languagePicker != nil { languagePicker.isEnabled = false }
    }

    // MARK: - Actions

    @objc private func engineChanged() {
        cancelCurrentDownload()
        // Index 0 == Parakeet (see the enginePicker item order above).
        selectedEngine = enginePicker.indexOfSelectedItem == 0 ? "parakeet" : "whisper"
        refreshModelPicker()
    }

    @objc private func modelChanged() {
        guard !isDownloading else { return }
        if selectedEngine == "parakeet" {
            let idx = modelPicker.indexOfSelectedItem
            if idx >= 0 && idx < EngineCatalog.parakeetModels.count {
                selectedParakeetModel = EngineCatalog.parakeetModels[idx].id
            }
        } else {
            if let id = modelPicker.selectedItem?.representedObject as? String { selectedWhisperModel = id }
        }
        resetDownloadUI()
        updateLanguagePicker()
        if selectedEngine == "parakeet" {
            if ParakeetModelManager.shared.isModelDownloaded(selectedParakeetModel) { markDownloaded() }
        } else {
            let current = (modelPicker.selectedItem?.representedObject as? String) ?? selectedWhisperModel
            if Transcriber.modelExists(modelSize: current) { markDownloaded() }
        }
    }

    @objc private func languageChanged() {
        // If a download error is showing, changing language clears it and restores the footer
        // controls that showError hid, so the user can't get stranded with a hidden Start button.
        if !isDownloading && !errorLabel.isHidden {
            resetDownloadUI()
            if selectedEngine == "parakeet",
                ParakeetModelManager.shared.isModelDownloaded(selectedParakeetModel) {
                markDownloaded()
            }
        }
        if let code = languagePicker.selectedItem?.representedObject as? String {
            selectedLanguage = code
            if selectedEngine == "whisper" {
                let current = (modelPicker.selectedItem?.representedObject as? String) ?? selectedWhisperModel
                if code != "en" && current.hasSuffix(".en") {
                    let multilingual = current.replacingOccurrences(of: ".en", with: "")
                    if let idx = whisperModelOptions().firstIndex(where: { $0.id == multilingual }) {
                        modelPicker.selectItem(at: idx); selectedWhisperModel = multilingual
                    }
                }
            }
        }
    }

    @objc private func downloadTapped() {
        errorLabel.isHidden = true
        if selectedEngine == "parakeet" {
            let idx = modelPicker.indexOfSelectedItem
            if idx >= 0 && idx < EngineCatalog.parakeetModels.count {
                selectedParakeetModel = EngineCatalog.parakeetModels[idx].id
            }
            beginParakeetDownload(modelName: selectedParakeetModel)
        } else {
            if let id = modelPicker.selectedItem?.representedObject as? String { selectedWhisperModel = id }
            beginWhisperDownload(modelSize: selectedWhisperModel)
        }
    }

    @objc private func pauseTapped() {
        if isPaused {
            isPaused = false; pauseButton.title = "⏸︎ Pause"
            if selectedEngine == "parakeet" {
                let model = selectedParakeetModel
                showDownloadingUI(label: "Downloading \(model)…", indeterminate: false)
                beginParakeetDownload(modelName: model)
            } else {
                whisperCoordinator?.resume(); statusLabel.stringValue = "Downloading…"
            }
        } else {
            isPaused = true; pauseButton.title = "▶︎ Resume"
            if selectedEngine == "parakeet" {
                parakeetDownloadGeneration += 1  // invalidate in-flight callbacks from the paused task
                parakeetTask?.cancel(); parakeetTask = nil
            } else {
                whisperCoordinator?.pause()
            }
            statusLabel.stringValue = "Paused."
        }
    }

    @objc private func stopTapped() {
        cancelCurrentDownload(); resetDownloadUI(); updateLanguagePicker()
        setMenuBarState(.idle)  // stop the menu-bar download wave
    }

    @objc private func startTapped() {
        guard isModelReady else { return }
        applyLoginCheckbox(); dismiss(shouldContinue: true)
    }

    @objc private func configureTapped() {
        guard isModelReady else { return }
        applyLoginCheckbox()
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.openSettingsAfterSetup = true
        }
        dismiss(shouldContinue: true)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // If a model is already downloaded, closing the window just means "done" — proceed into the
        // app like the Start button, no nag.
        if isModelReady {
            applyLoginCheckbox()
            dismiss(shouldContinue: true)
            return false
        }
        let alert = NSAlert()
        alert.messageText = "You must download a model to use SpeakFree."
        alert.informativeText = "Download one in Settings at any time."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Back")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            cancelCurrentDownload(); dismiss(shouldContinue: false)
        }
        return false
    }

    // MARK: - Helpers

    private func dismiss(shouldContinue: Bool) {
        let engine = selectedEngine
        let model = engine == "parakeet" ? selectedParakeetModel : selectedWhisperModel
        panel.orderOut(nil); NSApp.stopModal()
        completion?(engine, model, selectedLanguage, shouldContinue)
        completion = nil
        NSApp.hideDockIconIfNoWindows()
    }

    private func cancelCurrentDownload() {
        whisperCoordinator?.cancel(); whisperCoordinator = nil
        parakeetDownloadGeneration += 1  // invalidate in-flight callbacks from the cancelled task
        parakeetTask?.cancel(); parakeetTask = nil
        isDownloading = false; isPaused = false
    }

    /// Drive the shared menu-bar icon from the onboarding panel (download → wave, etc.).
    private func setMenuBarState(_ state: StatusBarController.State) {
        (NSApplication.shared.delegate as? AppDelegate)?.statusBar.state = state
    }

    private func applyLoginCheckbox() {
        let want = loginCheckbox.state == .on
        if want != LaunchAtLogin.isEnabled { LaunchAtLogin.isEnabled = want }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Parakeet download (two-phase: download → compile)

    private func beginParakeetDownload(modelName: String) {
        // v2 has a direct-download plan, so we show a true byte-progress bar. Other models (v3) have
        // no usable progress from FluidAudio, so start an animated indeterminate bar immediately so it
        // never shows a frozen number.
        let smoothProgress = ParakeetModelManager.shared.hasDirectDownloadPlan(modelName)
        showDownloadingUI(
            label: smoothProgress ? "Downloading Parakeet model…" : "Downloading Parakeet model (~600 MB)…",
            indeterminate: !smoothProgress)
        // A Parakeet download is essentially one large file fetched without resume data, so "pause"
        // would just restart it from zero (and orphan the partial download). Offer only Stop.
        pauseButton.isHidden = true

        // Capture this download's generation; every UI callback below no-ops if a later
        // pause/stop/new-download has superseded it (guards against stale late callbacks).
        parakeetDownloadGeneration += 1
        let generation = parakeetDownloadGeneration

        parakeetTask = Task {
            do {
                // Phase 1: byte-accurate direct pre-fetch of the large bundles (~99% of the bytes),
                // so the bar moves smoothly instead of freezing on FluidAudio's progress-less fetch.
                try await ParakeetModelManager.shared.prefetchLargeFiles(modelName) { [weak self] written, total in
                    guard total > 0 else { return }
                    DispatchQueue.main.async {
                        guard let self = self, self.parakeetDownloadGeneration == generation,
                            !self.isPaused else { return }
                        let display = min(Double(written) / Double(total), 1.0) * 0.92  // download fills 0–92%
                        self.progressBar.isIndeterminate = false
                        self.progressBar.doubleValue = display
                        self.percentLabel.stringValue = "\(Int(display * 100))%"
                        self.percentLabel.isHidden = false
                        self.bytesLabel.stringValue =
                            "\(WelcomeController.formatBytes(written)) of \(WelcomeController.formatBytes(total))"
                        self.bytesLabel.isHidden = false
                        self.statusLabel.stringValue = "Downloading Parakeet model…"
                        self.progressBar.display(); self.percentLabel.display()
                        self.bytesLabel.display(); self.statusLabel.display()
                    }
                }

                // Phase 2: FluidAudio fetches the small remainder (skipping the pre-fetched bundles)
                // and compiles each model on the Neural Engine. FluidAudio reports no usable progress
                // here, so show an animated bar with an honest label rather than a frozen number.
                await MainActor.run { [weak self] in
                    guard let self = self, self.parakeetDownloadGeneration == generation else { return }
                    self.percentLabel.isHidden = true
                    self.bytesLabel.isHidden = true
                    self.progressBar.isIndeterminate = true
                    self.progressBar.startAnimation(nil)
                    // For v2 the download is essentially done (pre-fetched), so this is genuinely the
                    // compile step; for v3 the whole download happens here, so label it accordingly.
                    self.statusLabel.stringValue =
                        smoothProgress ? "Preparing model for your Mac…" : "Downloading Parakeet model (~600 MB)…"
                    self.progressBar.display(); self.statusLabel.display()
                }

                try await ParakeetModelManager.shared.downloadOnly(modelName) { _ in }
                try await ParakeetModelManager.shared.compileAndCache(modelName)
                await MainActor.run { [weak self] in
                    guard let self = self, self.parakeetDownloadGeneration == generation else { return }
                    self.markDownloaded(autoAdvance: true)
                }

            } catch {
                // Pause/Stop cancels the task, surfacing as CancellationError / URLError.cancelled.
                // Treat any cancellation as user-initiated and stay silent; the pause/stop handlers
                // already set the correct UI.
                if Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled { return }
                await MainActor.run { [weak self] in
                    guard let self = self, self.parakeetDownloadGeneration == generation,
                        !self.isPaused else { return }
                    self.showError(WelcomeController.parakeetErrorMessage(error, modelName: modelName))
                }
            }
        }
    }

    /// Download-failure copy for Parakeet, with a manual-install fallback the user (or their AI
    /// assistant) can run when the in-app download won't complete.
    private static func parakeetErrorMessage(_ error: Error, modelName: String) -> String {
        // Action first (command + help) so the copy-pasteable line is never pushed off-screen by a
        // long error string; the raw detail is truncated and shown last.
        let detail = error.localizedDescription
        let shortDetail = detail.count > 140 ? String(detail.prefix(140)) + "…" : detail
        return "Download didn't finish. Tap Retry, or install it manually in Terminal:\n"
            + "/Applications/speakfree.app/Contents/MacOS/speakfree download-parakeet \(modelName)\n"
            + "More help: definitelyreal.github.io/speakfree\n"
            + "(\(shortDetail))"
    }

    // MARK: - Whisper download (T2.4: via ModelDownloadCoordinator)

    private func beginWhisperDownload(modelSize: String) {
        let sizeStr = WelcomeController.modelSizes[modelSize] ?? "unknown size"
        showDownloadingUI(label: "Downloading \(modelSize) (\(sizeStr))…", indeterminate: false)

        let coordinator = ModelDownloadCoordinator()
        whisperCoordinator = coordinator

        coordinator.onProgress = { [weak self] fraction, written, total in
            guard let self = self, !self.isPaused else { return }
            self.progressBar.doubleValue = fraction
            self.percentLabel.stringValue = "\(Int(fraction * 100))%"
            if total > 0 {
                self.bytesLabel.stringValue =
                    "\(WelcomeController.formatBytes(written)) of \(WelcomeController.formatBytes(total))"
                self.bytesLabel.isHidden = false
            }
            self.progressBar.display(); self.percentLabel.display(); self.bytesLabel.display()
        }
        coordinator.onSuccess = { [weak self] _ in self?.markDownloaded(autoAdvance: true) }
        coordinator.onFailure = { [weak self] error in
            self?.showError(WelcomeController.whisperErrorMessage(error))
        }

        coordinator.start(modelSize: modelSize)
    }

    /// Map a coordinator error to the Welcome panel's prior copy.
    private static func whisperErrorMessage(_ error: Error) -> String {
        switch error {
        case ModelDownloadError.invalidModel:
            return "Downloaded file is not a valid model"
        case ModelDownloadError.hashMismatch:
            return (error as? LocalizedError)?.errorDescription ?? "Download failed integrity check"
        default:
            return "Download failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Logo view

private class LogoView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        WelcomeController.purple.setFill()
        let heights: [CGFloat] = [0.28, 0.52, 0.78, 0.52, 0.28]
        let barW = bounds.width * 0.12
        let gap  = bounds.width * 0.09
        let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
        let startX = bounds.midX - total / 2
        for (i, frac) in heights.enumerated() {
            let h = bounds.height * frac
            let x = startX + CGFloat(i) * (barW + gap)
            let y = bounds.midY - h / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
