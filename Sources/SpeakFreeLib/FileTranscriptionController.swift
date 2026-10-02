// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// NSWindowController for "Transcribe audio file…".
/// Presents a single NSPanel that cycles through Config → Progress → Completion / Error states.
public class FileTranscriptionController: NSWindowController {

    // MARK: - Singleton

    private static var shared: FileTranscriptionController?

    public static func show(url: URL? = nil) {
        if shared == nil { shared = FileTranscriptionController() }
        if shared!.window == nil { shared!.loadWindow() }
        shared!.showWindow(nil)
        NSApp.showDockIconIfNeeded()
        NSApp.installMinimalMenu()
        shared!.window?.makeKeyAndOrderFront(nil)
        if let url = url { shared!.setSourceFile(url) }
    }

    // MARK: - Layout constants

    private let W: CGFloat = 500
    private let H: CGFloat = 310

    // MARK: - Config-state UI

    private var enginePicker: NSPopUpButton!
    private var modelPicker: NSPopUpButton!
    private var languagePicker: NSPopUpButton!
    private var formatControl: NSSegmentedControl!
    private var savePathField: NSTextField!
    private var transcribeButton: NSButton!
    private var fileLabel: NSTextField!        // shows dropped/chosen filename
    private var chooseFileButton: NSButton!

    // MARK: - Progress-state UI

    private var progressBar: NSProgressIndicator!
    private var progressLabel: NSTextField!   // "Chunk N of M" or "N%"
    private var cancelButton: NSButton!
    private var progressFileLabel: NSTextField!

    // MARK: - Completion-state UI

    private var doneLabel: NSTextField!
    private var openFolderButton: NSButton!
    private var closeButton: NSButton!

    // MARK: - Error-state UI

    private var errorLabel: NSTextField!
    private var tryAgainButton: NSButton!

    // MARK: - Container views (for state switching)

    private var configView: NSView!
    private var progressView: NSView!
    private var completionView: NSView!
    private var errorView: NSView!

    // MARK: - State

    private var settings = FileTranscriptionSettings.load()
    private var sourceURL: URL?
    private var outputURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var isCancelled = false

    // MARK: - Init

    public init() {
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Window loading

    public override func loadWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Transcribe Audio File"
        panel.center()
        panel.delegate = self
        panel.minSize = NSSize(width: W, height: H)
        panel.maxSize = NSSize(width: W, height: H)
        let dropView = FileTranscriptionDropView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        dropView.canAcceptFile = { [weak self] in
            guard let self else { return false }
            return self.transcriptionTask == nil
        }
        dropView.selectFile = { [weak self] url in self?.handleDroppedURLs([url]) ?? false }
        panel.contentView = dropView
        self.window = panel
        buildUI()
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        configView    = buildConfigView()
        progressView  = buildProgressView()
        completionView = buildCompletionView()
        errorView     = buildErrorView()

        for v in [configView!, progressView!, completionView!, errorView!] {
            v.frame = content.bounds
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
        }
        showState(.config)
    }

    // MARK: - Config view

    private func buildConfigView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        let lw: CGFloat = 72   // label column width
        let px: CGFloat = 20   // left margin
        let fw: CGFloat = W - px - 20  // field width

        // File row
        let fileRowLabel = label("File:", x: px, y: H - 44, w: lw)
        v.addSubview(fileRowLabel)

        chooseFileButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFileTapped))
        chooseFileButton.bezelStyle = .rounded
        chooseFileButton.frame = NSRect(x: W - 100, y: H - 48, width: 80, height: 26)
        v.addSubview(chooseFileButton)

        fileLabel = NSTextField(labelWithString: "Drop a file or click Choose…")
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.font = NSFont.systemFont(ofSize: 12)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.frame = NSRect(x: px + lw + 4, y: H - 44, width: fw - lw - 8 - 88, height: 18)
        v.addSubview(fileLabel)

        // Engine row
        v.addSubview(label("Engine:", x: px, y: H - 82, w: lw))
        enginePicker = NSPopUpButton(frame: NSRect(x: px + lw + 4, y: H - 86, width: 180, height: 26))
        for e in EngineCatalog.engines { enginePicker.addItem(withTitle: e.displayName) }
        enginePicker.selectItem(withTitle: EngineCatalog.engines.first(where: { $0.id == settings.engine })?.displayName ?? "")
        enginePicker.target = self; enginePicker.action = #selector(engineChanged)
        v.addSubview(enginePicker)

        // Model row
        v.addSubview(label("Model:", x: px, y: H - 118, w: lw))
        modelPicker = NSPopUpButton(frame: NSRect(x: px + lw + 4, y: H - 122, width: 260, height: 26))
        v.addSubview(modelPicker)

        // Language row
        v.addSubview(label("Language:", x: px, y: H - 154, w: lw))
        languagePicker = NSPopUpButton(frame: NSRect(x: px + lw + 4, y: H - 158, width: 200, height: 26))
        v.addSubview(languagePicker)

        // Format row
        v.addSubview(label("Format:", x: px, y: H - 190, w: lw))
        formatControl = NSSegmentedControl(labels: ["TXT", "MD"], trackingMode: .selectOne,
                                           target: self, action: #selector(formatChanged))
        formatControl.frame = NSRect(x: px + lw + 4, y: H - 192, width: 120, height: 24)
        formatControl.selectedSegment = settings.format == .md ? 1 : 0
        v.addSubview(formatControl)

        // Save-to row
        v.addSubview(label("Save to:", x: px, y: H - 226, w: lw))
        savePathField = NSTextField(labelWithString: settings.saveDirectoryURL?.path ?? "~/Documents")
        savePathField.lineBreakMode = .byTruncatingMiddle
        savePathField.font = NSFont.systemFont(ofSize: 11)
        savePathField.textColor = .secondaryLabelColor
        savePathField.frame = NSRect(x: px + lw + 4, y: H - 226, width: fw - lw - 8 - 80, height: 18)
        v.addSubview(savePathField)

        let chooseDirBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseDirTapped))
        chooseDirBtn.bezelStyle = .rounded
        chooseDirBtn.frame = NSRect(x: W - 100, y: H - 230, width: 80, height: 26)
        v.addSubview(chooseDirBtn)

        // Transcribe button
        transcribeButton = NSButton(title: "Transcribe →", target: self, action: #selector(transcribeTapped))
        transcribeButton.bezelStyle = .rounded
        transcribeButton.keyEquivalent = "\r"
        transcribeButton.isEnabled = false
        transcribeButton.frame = NSRect(x: W - 130, y: 16, width: 110, height: 28)
        v.addSubview(transcribeButton)

        // Populate pickers now that all UI is created
        refreshModelPicker()
        refreshLanguagePicker()

        return v
    }

    // MARK: - Progress view

    private func buildProgressView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        progressFileLabel = NSTextField(labelWithString: "")
        progressFileLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        progressFileLabel.lineBreakMode = .byTruncatingMiddle
        progressFileLabel.frame = NSRect(x: 20, y: H - 60, width: W - 40, height: 20)
        v.addSubview(progressFileLabel)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.frame = NSRect(x: 20, y: H - 100, width: W - 40, height: 20)
        v.addSubview(progressBar)

        progressLabel = NSTextField(labelWithString: "Loading model…")
        progressLabel.font = NSFont.systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: 20, y: H - 126, width: W - 40, height: 16)
        v.addSubview(progressLabel)

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 20, y: 16, width: 80, height: 28)
        v.addSubview(cancelButton)

        return v
    }

    // MARK: - Completion view

    private func buildCompletionView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        doneLabel = NSTextField(labelWithString: "")
        doneLabel.font = NSFont.systemFont(ofSize: 13)
        doneLabel.lineBreakMode = .byTruncatingMiddle
        doneLabel.frame = NSRect(x: 20, y: H - 80, width: W - 40, height: 20)
        v.addSubview(doneLabel)

        openFolderButton = NSButton(title: "Open Folder", target: self, action: #selector(openFolderTapped))
        openFolderButton.bezelStyle = .rounded
        openFolderButton.frame = NSRect(x: 20, y: 16, width: 110, height: 28)
        v.addSubview(openFolderButton)

        closeButton = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 140, y: 16, width: 80, height: 28)
        v.addSubview(closeButton)

        return v
    }

    // MARK: - Error view

    private func buildErrorView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = NSFont.systemFont(ofSize: 13)
        errorLabel.textColor = .systemRed
        errorLabel.frame = NSRect(x: 20, y: H - 120, width: W - 40, height: 80)
        v.addSubview(errorLabel)

        tryAgainButton = NSButton(title: "Try Again", target: self, action: #selector(tryAgainTapped))
        tryAgainButton.bezelStyle = .rounded
        tryAgainButton.frame = NSRect(x: 20, y: 16, width: 90, height: 28)
        v.addSubview(tryAgainButton)

        return v
    }

    // MARK: - State management

    private enum State { case config, progress, completion, error }

    private func showState(_ state: State) {
        configView.isHidden     = state != .config
        progressView.isHidden   = state != .progress
        completionView.isHidden = state != .completion
        errorView.isHidden      = state != .error
    }

    // MARK: - Config actions

    @discardableResult
    public func setSourceFile(_ url: URL) -> Bool {
        // A cancelled task may still be unwinding or writing its output. Keep its source
        // stable until the completion cleanup runs, including Finder/Open With requests.
        guard transcriptionTask == nil, let url = FileTranscriptionDropPolicy.singleMediaFile([url]) else { return false }
        if !isWindowLoaded { loadWindow() }
        sourceURL = url
        fileLabel.stringValue = url.lastPathComponent
        fileLabel.textColor = .labelColor
        // Picking a file must not re-enable the button that `refreshModelPicker` disabled for
        // having no model on disk — that gave an enabled Transcribe that failed straight into
        // the error view (2026-08-01). Whisper with zero downloaded models is the only case;
        // Parakeet always has a model id, so it stays enabled as before.
        let hasModel = settings.engine == "parakeet" || !downloadedWhisperModels().isEmpty
        transcribeButton.isEnabled = hasModel
        showState(.config)
        return true
    }

    @objc private func chooseFileTapped() {
        guard transcriptionTask == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Audio File"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = FileTranscriptionDropPolicy.allowedContentTypes
        if panel.runModal() == .OK, let url = panel.url { setSourceFile(url) }
    }

    @objc private func chooseDirTapped() {
        let panel = NSOpenPanel()
        panel.title = "Choose Save Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryURL = url
            savePathField.stringValue = url.path
            settings.save()
        }
    }

    @objc private func engineChanged() {
        let idx = enginePicker.indexOfSelectedItem
        settings.engine = EngineCatalog.engines[safe: idx]?.id ?? "whisper"
        settings.save()
        refreshModelPicker()
        refreshLanguagePicker()
    }

    @objc private func formatChanged() {
        settings.format = formatControl.selectedSegment == 1 ? .md : .txt
        settings.save()
    }

    private func refreshModelPicker() {
        modelPicker.removeAllItems()
        if settings.engine == "parakeet" {
            for m in EngineCatalog.parakeetModels {
                modelPicker.addItem(withTitle: "\(m.displayName) (\(m.sizeDescription))")
                modelPicker.lastItem?.representedObject = m.id
            }
            if let idx = EngineCatalog.parakeetModels.firstIndex(where: { $0.id == settings.parakeetModel }) {
                modelPicker.selectItem(at: idx)
            }
        } else {
            let models = downloadedWhisperModels()
            if models.isEmpty {
                modelPicker.addItem(withTitle: "No model downloaded")
                transcribeButton.isEnabled = false
            } else {
                for m in models { modelPicker.addItem(withTitle: m) }
                if let idx = models.firstIndex(of: settings.modelSize) { modelPicker.selectItem(at: idx) }
                else { modelPicker.selectItem(at: 0) }
            }
        }
        modelPicker.target = self; modelPicker.action = #selector(modelChanged)
    }

    @objc private func modelChanged() {
        if settings.engine == "parakeet" {
            let idx = modelPicker.indexOfSelectedItem
            if let id = modelPicker.selectedItem?.representedObject as? String { settings.parakeetModel = id }
            else if let m = EngineCatalog.parakeetModels[safe: idx] { settings.parakeetModel = m.id }
        } else {
            settings.modelSize = modelPicker.titleOfSelectedItem ?? settings.modelSize
        }
        settings.save()
        refreshLanguagePicker()
    }

    private func downloadedWhisperModels() -> [String] {
        let allModels = ["tiny.en","base.en","small.en","medium.en","large-v3-turbo","large-v3",
                         "tiny","base","small","medium","large"]
        return allModels.filter { Transcriber.modelExists(modelSize: $0) }
    }

    private func refreshLanguagePicker() {
        languagePicker.removeAllItems()
        languagePicker.addItem(withTitle: "Auto-detect")
        languagePicker.lastItem?.representedObject = "auto"
        let codes: [String]
        if settings.engine == "parakeet" {
            codes = EngineCatalog.parakeetModels
                .first(where: { $0.id == settings.parakeetModel })?.supportedLanguages ?? ["en"]
        } else {
            codes = WhisperLanguage.all.map { $0.id }
        }
        for code in codes {
            let name = WhisperLanguage.all.first(where: { $0.id == code })?.name ?? code
            languagePicker.addItem(withTitle: name)
            languagePicker.lastItem?.representedObject = code
        }
        // Select saved language
        for i in 0..<languagePicker.numberOfItems {
            if (languagePicker.item(at: i)?.representedObject as? String) == settings.language {
                languagePicker.selectItem(at: i); break
            }
        }
        languagePicker.target = self; languagePicker.action = #selector(languagePickerChanged)
    }

    @objc private func languagePickerChanged() {
        settings.language = (languagePicker.selectedItem?.representedObject as? String) ?? "en"
        settings.save()
    }

    // MARK: - Transcription

    @objc private func transcribeTapped() {
        guard transcriptionTask == nil, let sourceURL = sourceURL else { return }
        guard let saveDir = settings.saveDirectoryURL else {
            showError("No save folder selected."); return
        }

        // Save latest picker selections
        modelChanged()
        languagePickerChanged()

        // Build output path
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext  = settings.format.rawValue
        let outputPath = uniqueOutputURL(in: saveDir, stem: stem, ext: ext)

        // Resolve transcriber for selected engine + model
        let config = Config.load()
        var cfg = config
        cfg.engine = settings.engine
        cfg.modelSize = settings.engine == "whisper" ? settings.modelSize : config.modelSize
        cfg.parakeetModel = settings.engine == "parakeet" ? settings.parakeetModel : config.parakeetModel
        cfg.language = settings.language == "auto" ? "en" : settings.language

        let activityLease: RecordingActivity.Lease
        do { activityLease = try RecordingActivity.shared.acquireReading(sourceURL) }
        catch { showError(error.localizedDescription); return }
        let engine = EngineFactory.make(config: cfg)
        let transcriber = Transcriber(engine: engine,
                                      modelID: settings.engine == "parakeet" ? settings.parakeetModel : settings.modelSize,
                                      language: cfg.language)
        transcriber.whisperFallbackEnabled = WhisperFallback.isEnabled(cfg)

        // Switch to progress state
        progressFileLabel.stringValue = "Transcribing \(sourceURL.lastPathComponent)…"
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        progressLabel.stringValue = "Loading model…"
        showState(.progress)

        isCancelled = false
        outputURL = outputPath

        transcriptionTask = Task { [activityLease] in
            defer {
                activityLease.release()
                Task { @MainActor in
                    self.transcriptionTask = nil
                    self.chooseFileButton.isEnabled = true
                    self.transcribeButton.isEnabled = self.sourceURL != nil
                        && (self.settings.engine == "parakeet" || !self.downloadedWhisperModels().isEmpty)
                }
            }
            do {
                var modelLoaded = false
                let text = try await transcriber.transcribeFile(
                    url: sourceURL,
                    progressHandler: { [weak self] chunk, total, pct in
                        guard let self = self else { return }
                        if !modelLoaded {
                            modelLoaded = true
                            self.progressBar.isIndeterminate = false
                            self.progressBar.stopAnimation(nil)
                        }
                        let overall = total > 1
                            ? (Double(chunk) + Double(pct) / 100.0) / Double(total)
                            : Double(pct) / 100.0
                        self.progressBar.doubleValue = overall
                        self.progressLabel.stringValue = total > 1
                            ? "Chunk \(chunk + 1) of \(total) — \(pct)%"
                            : "\(pct)%"
                        self.progressBar.display()
                        self.progressLabel.display()
                    },
                    isCancelled: { [weak self] in self?.isCancelled ?? true }
                )
                if self.isCancelled { return }
                try self.writeOutput(text: text, to: outputPath, source: sourceURL, cfg: cfg)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.doneLabel.stringValue = "Done — \(outputPath.lastPathComponent) saved."
                    self.showState(.completion)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self, !self.isCancelled else { return }
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func writeOutput(text: String, to url: URL, source: URL, cfg: Config) throws {
        let outputLease = try RecordingActivity.shared.acquire(url)
        defer { outputLease.release() }
        let tmp = url.appendingPathExtension("tmp")
        let content: String
        if settings.format == .md {
            let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let engineStr = "\(cfg.engine)/\(cfg.engine == "parakeet" ? settings.parakeetModel : settings.modelSize)"
            content = "# \(source.lastPathComponent)\nDate: \(date)\nEngine: \(engineStr) · Language: \(cfg.language)\n\n\(text)\n"
        } else {
            content = text + "\n"
        }
        try content.write(to: tmp, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    private func uniqueOutputURL(in dir: URL, stem: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(stem).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: - Error display

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        showState(.error)
    }

    // MARK: - Button actions

    @objc private func cancelTapped() {
        isCancelled = true
        transcriptionTask?.cancel()
        // Cancellation is cooperative. Do not admit a replacement until the job exits.
        chooseFileButton.isEnabled = false
        transcribeButton.isEnabled = false
        progressBar.stopAnimation(nil)
        showState(.config)
    }

    @objc private func openFolderTapped() {
        if let url = outputURL {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    @objc private func closeTapped() {
        window?.close()
        FileTranscriptionController.shared = nil
    }

    @objc private func tryAgainTapped() {
        showState(.config)
    }

    // MARK: - Helpers

    private func label(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = NSFont.systemFont(ofSize: 13)
        f.frame = NSRect(x: x, y: y, width: w, height: 18)
        return f
    }
}

// MARK: - NSWindowDelegate

extension FileTranscriptionController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        isCancelled = true
        transcriptionTask?.cancel()
        FileTranscriptionController.shared = nil
        NSApp.hideDockIconIfNoWindows()
    }
}

// MARK: - Drag and drop

extension FileTranscriptionController {
    @discardableResult
    public func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard transcriptionTask == nil,
              let url = FileTranscriptionDropPolicy.singleMediaFile(urls) else { return false }
        // Selection only: the person still chooses Transcribe and the output options.
        return setSourceFile(url)
    }
}

/// Drag payload validation shared with the normal file chooser. File contents are not
/// opened here; a media type is eligibility, not a claim that a decoder can read the bytes.
enum FileTranscriptionDropPolicy {
    static let allowedContentTypes: [UTType] = [.audio, .movie]

    static func singleMediaFile(_ urls: [URL]) -> URL? {
        guard urls.count == 1, let url = urls.first, url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true,
              let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
              allowedContentTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        return url
    }

    static func singleMediaFile(on pasteboard: NSPasteboard) -> URL? {
        // Reading only filtered URLs would hide an extra unsupported/non-file item and
        // silently select one member of a multiple-item drag.
        guard let items = pasteboard.pasteboardItems, items.count == 1,
              let raw = items[0].string(forType: .fileURL), let url = URL(string: raw) else { return nil }
        return singleMediaFile([url])
    }
}

/// The content view remains the drag destination above every configuration/progress state.
/// Admission is checked again at commit, so a job started after drag-enter cannot be replaced.
final class FileTranscriptionDropView: NSView {
    var canAcceptFile: () -> Bool = { false }
    var selectFile: (URL) -> Bool = { _ in false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    func operation(for pasteboard: NSPasteboard, sourceMask: NSDragOperation) -> NSDragOperation {
        guard canAcceptFile(), sourceMask.contains(.copy),
              FileTranscriptionDropPolicy.singleMediaFile(on: pasteboard) != nil else { return [] }
        return .copy
    }

    func receive(_ pasteboard: NSPasteboard, sourceMask: NSDragOperation) -> Bool {
        guard canAcceptFile(), sourceMask.contains(.copy),
              let url = FileTranscriptionDropPolicy.singleMediaFile(on: pasteboard) else { return false }
        return selectFile(url)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender.draggingPasteboard, sourceMask: sender.draggingSourceOperationMask)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender.draggingPasteboard, sourceMask: sender.draggingSourceOperationMask)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        operation(for: sender.draggingPasteboard, sourceMask: sender.draggingSourceOperationMask) == .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        receive(sender.draggingPasteboard, sourceMask: sender.draggingSourceOperationMask)
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
