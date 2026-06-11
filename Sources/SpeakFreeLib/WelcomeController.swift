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
        controller.selectedWhisperModel = suggestedModel
        controller.completion = { engine, model, lang, ok in result = (engine, model, lang, ok) }
        NSApp.showDockIconIfNeeded()
        NSApp.installMinimalMenu()
        controller.buildPanel()
        NSApp.runModal(for: controller.panel)
        return result
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
        enginePicker.addItem(withTitle: "Whisper (CPU/GPU)")
        enginePicker.addItem(withTitle: "Parakeet (Apple Neural Engine) (Faster)")
        enginePicker.selectItem(at: 1)
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
        errorLabel.frame = NSRect(x: 88, y: h - 398, width: 352, height: 16)
        errorLabel.isHidden = true
        c.addSubview(errorLabel)

        // ── Bottom ───────────────────────────────────────────────
        loginCheckbox = NSButton(checkboxWithTitle: "Launch SpeakFree at login", target: nil, action: nil)
        loginCheckbox.font = NSFont.systemFont(ofSize: 12)
        loginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
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
        startButton.isEnabled = false; configureButton.isEnabled = false
        enginePicker.isEnabled = true; modelPicker.isEnabled = true
        if languagePicker != nil { languagePicker.isEnabled = true }
    }

    private func markDownloaded() {
        isDownloading = false; isPaused = false; isModelReady = true
        downloadButton.title = "✓ Downloaded"; downloadButton.isEnabled = false; downloadButton.isHidden = false
        pauseButton.isHidden = true; stopButton.isHidden = true
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        percentLabel.isHidden = true; bytesLabel.isHidden = true
        statusLabel.stringValue = "Model ready."
        startButton.isEnabled = true; configureButton.isEnabled = true
        enginePicker.isEnabled = true; modelPicker.isEnabled = true
        if languagePicker != nil { languagePicker.isEnabled = true }
    }

    private func showError(_ message: String) {
        isDownloading = false; isPaused = false
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        percentLabel.isHidden = true; bytesLabel.isHidden = true
        downloadButton.title = "Retry"; downloadButton.isEnabled = true; downloadButton.isHidden = false
        pauseButton.isHidden = true; stopButton.isHidden = true
        statusLabel.stringValue = ""
        errorLabel.stringValue = message; errorLabel.isHidden = false
        enginePicker.isEnabled = true; modelPicker.isEnabled = true
        if languagePicker != nil { languagePicker.isEnabled = true }
    }

    private func showDownloadingUI(label: String, indeterminate: Bool) {
        isDownloading = true; isPaused = false
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
        selectedEngine = enginePicker.indexOfSelectedItem == 1 ? "parakeet" : "whisper"
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
                parakeetTask?.cancel(); parakeetTask = nil
            } else {
                whisperCoordinator?.pause()
            }
            statusLabel.stringValue = "Paused."
        }
    }

    @objc private func stopTapped() {
        cancelCurrentDownload(); resetDownloadUI(); updateLanguagePicker()
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
        parakeetTask?.cancel(); parakeetTask = nil
        isDownloading = false; isPaused = false
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
        let sizeStr = EngineCatalog.parakeetModels.first(where: { $0.id == modelName })?.sizeDescription ?? "~600 MB"
        showDownloadingUI(label: "Downloading \(modelName)…", indeterminate: false)

        parakeetTask = Task {
            do {
                // Phase 1: real byte-level download progress via AsrModels.download()
                // FluidAudio maps download to [0, 0.5]; multiply by 2 for 0–100% display.
                try await ParakeetModelManager.shared.downloadOnly(modelName) { [weak self] fraction in
                    guard fraction.isFinite, fraction >= 0 else { return }
                    DispatchQueue.main.async {
                        guard let self = self, !self.isPaused else { return }
                        let display = min(fraction * 2.0, 1.0)
                        self.progressBar.doubleValue = display
                        self.percentLabel.stringValue = "\(Int(display * 100))%"
                        let downloaded = WelcomeController.formatBytes(Int64(fraction * 2.0 * 650_000_000))
                        self.bytesLabel.stringValue = "\(downloaded) of \(sizeStr)"
                        self.bytesLabel.isHidden = false
                        self.progressBar.display(); self.percentLabel.display(); self.bytesLabel.display()
                    }
                }

                // Phase 2: compilation (indeterminate — no granular signal available)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.progressBar.isIndeterminate = true
                    self.progressBar.startAnimation(nil)
                    self.percentLabel.isHidden = true
                    self.bytesLabel.isHidden = true
                    self.statusLabel.stringValue = "Compiling model for your device…"
                    self.progressBar.display(); self.statusLabel.display()
                }

                try await ParakeetModelManager.shared.compileAndCache(modelName)
                await MainActor.run { [weak self] in self?.markDownloaded() }

            } catch {
                await MainActor.run { [weak self] in self?.showError(error.localizedDescription) }
            }
        }
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
        coordinator.onSuccess = { [weak self] _ in self?.markDownloaded() }
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
