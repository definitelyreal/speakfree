import AppKit
import SwiftUI

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(viewModel: SettingsViewModel) {
        if shared == nil { shared = SettingsWindowController(viewModel: viewModel) }
        shared?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    convenience init(viewModel: SettingsViewModel) {
        let hostingController = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        hostingController.preferredContentSize = NSSize(width: 480, height: 640)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "speakfree Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 640))
        window.minSize = NSSize(width: 480, height: 580)
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

// MARK: - Hotkey Options

private struct HotkeyOption: Hashable, Identifiable {
    let label: String
    let keyCode: UInt16
    var id: UInt16 { keyCode }
}

private let standardHotkeyOptions: [HotkeyOption] = [
    HotkeyOption(label: "\u{1F310}  Globe / fn",       keyCode: 63),
    HotkeyOption(label: "\u{2318}  Left Command",      keyCode: 55),
    HotkeyOption(label: "\u{2318}  Right Command",     keyCode: 54),
    HotkeyOption(label: "\u{2325}  Left Option",       keyCode: 58),
    HotkeyOption(label: "\u{2325}  Right Option",      keyCode: 61),
    HotkeyOption(label: "\u{2303}  Left Control",      keyCode: 59),
]

/// Sentinel value for the "Other..." menu item in the hotkey picker.
private let otherHotkeyTag: UInt16 = 999

// MARK: - Model Helpers

private struct ModelInfo: Identifiable, Hashable {
    let id: String
    let memory: String
    let speed: String
    let isRecommended: Bool

    var label: String {
        "\(id) (\(memory), \(speed) load)"
    }
}

private func availableModels(language: String) -> [ModelInfo] {
    let isEnglish = (language == "en")
    let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)

    let recommendedBase: String
    if ramGB >= 32 { recommendedBase = "medium" }
    else if ramGB > 8 { recommendedBase = "small" }
    else { recommendedBase = "base" }

    struct RawModel {
        let enId: String
        let multiId: String
        let base: String
        let memory: String
        let speed: String
    }

    let raw: [RawModel] = [
        RawModel(enId: "tiny.en",   multiId: "tiny",   base: "tiny",   memory: "~230 MB", speed: "~0.2s"),
        RawModel(enId: "base.en",   multiId: "base",   base: "base",   memory: "~330 MB", speed: "~0.3s"),
        RawModel(enId: "small.en",  multiId: "small",  base: "small",  memory: "~800 MB", speed: "~0.5s"),
        RawModel(enId: "medium.en", multiId: "medium",  base: "medium", memory: "~2.1 GB", speed: "~1.0s"),
        RawModel(enId: "large-v3",  multiId: "large-v3", base: "large", memory: "~3.9 GB", speed: "~2.0s"),
    ]

    return raw.map { r in
        let modelId = (isEnglish && r.base != "large") ? r.enId : r.multiId
        return ModelInfo(
            id: modelId,
            memory: r.memory,
            speed: r.speed,
            isRecommended: r.base == recommendedBase
        )
    }
}

// MARK: - Max Recordings Options

private let maxRecordingsOptions: [(label: String, value: Int)] = [
    ("Off", 0),
    ("10", 10),
    ("20", 20),
    ("30", 30),
    ("50", 50),
    ("100", 100),
]

// MARK: - Key Recorder Monitor

/// Holds the NSEvent monitor reference so it can be cleaned up reliably.
private class KeyMonitorHolder: ObservableObject {
    var monitor: Any?

    func install(onCapture: @escaping (UInt16, [String]) -> Void, onCancel: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                onCancel()
                return nil
            }

            var mods: [String] = []
            let flags = event.modifierFlags
            if flags.contains(.command) { mods.append("cmd") }
            if flags.contains(.shift) { mods.append("shift") }
            if flags.contains(.option) { mods.append("option") }
            if flags.contains(.control) { mods.append("ctrl") }

            onCapture(event.keyCode, mods)
            return nil
        }
    }

    func remove() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit { remove() }
}

// MARK: - Hotkey Validation

private enum HotkeyValidation {
    case allowed
    case rejected(String)
}

private enum HotkeyValidator {
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]

    static func validate(keyCode: UInt16, modifiers: [String]) -> HotkeyValidation {
        let hasModifiers = !modifiers.isEmpty

        // Single modifier key — always fine
        if !hasModifiers && modifierKeyCodes.contains(keyCode) { return .allowed }

        // Function key alone — fine
        if !hasModifiers && functionKeyCodes.contains(keyCode) { return .allowed }

        // Character key without modifier — reject
        if !hasModifiers {
            return .rejected("Add a modifier key (\u{2318}, \u{2325}, \u{2303}) or choose a function key.")
        }

        // Modifier + any key — allowed
        return .allowed
    }
}

// MARK: - Key Recorder Overlay

private struct KeyRecorderOverlay: View {
    var onCapture: (_ keyCode: UInt16, _ modifiers: [String]) -> Void
    var onCancel: () -> Void

    @StateObject private var holder = KeyMonitorHolder()
    @State private var rejectionMessage: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Press a key or combination\u{2026}")
                    .font(.headline)
                Text("Waiting for input\u{2026}")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let msg = rejectionMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 250)
                }

                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(radius: 20)
            )
        }
        .onAppear {
            holder.install(
                onCapture: { keyCode, modifiers in
                    let validation = HotkeyValidator.validate(keyCode: keyCode, modifiers: modifiers)
                    switch validation {
                    case .allowed:
                        rejectionMessage = nil
                        onCapture(keyCode, modifiers)
                    case .rejected(let reason):
                        rejectionMessage = reason
                    }
                },
                onCancel: {
                    rejectionMessage = nil
                    onCancel()
                }
            )
        }
        .onDisappear { holder.remove() }
    }
}

// MARK: - Inline Model Download Manager

/// Manages inline model downloads for the settings panel using URLSession with progress.
private class InlineDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?

    private var downloadTask: URLSessionDownloadTask?
    private var modelSize: String = ""
    private var onComplete: (() -> Void)?

    /// The StatusBarController to update with download progress (set by the view).
    weak var statusBarController: StatusBarController?

    func startDownload(modelSize: String, onComplete: @escaping () -> Void) {
        self.modelSize = modelSize
        self.onComplete = onComplete
        self.errorMessage = nil

        let modelFileName = "ggml-\(modelSize).bin"
        let urlString = "\(ModelDownloader.baseURL)/\(modelFileName)"
        guard let url = URL(string: urlString) else {
            self.errorMessage = "Invalid download URL"
            return
        }

        // Ensure models directory exists
        let modelsDir = Config.configDir.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Clean up any partial download
        let destPath = modelsDir.appendingPathComponent(modelFileName)
        let tmpPath = destPath.appendingPathExtension("downloading")
        try? FileManager.default.removeItem(at: tmpPath)

        // If model already exists, succeed immediately
        if FileManager.default.fileExists(atPath: destPath.path) {
            onComplete()
            return
        }

        isDownloading = true
        progress = 0

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        progress = 0
        updateStatusBar(nil)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let prog: Double
        if totalBytesExpectedToWrite > 0 {
            prog = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            prog = 0
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progress = prog
            let pct = Int(prog * 100)
            self.updateStatusBar("Downloading \(self.modelSize)... \(pct)%")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let modelFileName = "ggml-\(modelSize).bin"
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let destPath = modelsDir.appendingPathComponent(modelFileName)
        let tmpPath = destPath.appendingPathExtension("downloading")

        do {
            try? FileManager.default.removeItem(at: tmpPath)
            try FileManager.default.moveItem(at: location, to: tmpPath)

            // Validate: GGML files should be at least 1MB
            let attrs = try? FileManager.default.attributesOfItem(atPath: tmpPath.path)
            let fileSize = attrs?[.size] as? Int ?? 0
            if fileSize < 1_000_000 {
                try? FileManager.default.removeItem(at: tmpPath)
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "Downloaded file is not a valid Whisper model"
                    self?.isDownloading = false
                    self?.updateStatusBar(nil)
                }
                return
            }

            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.moveItem(at: tmpPath, to: destPath)
            print("Model downloaded to \(destPath.path)")

            DispatchQueue.main.async { [weak self] in
                self?.isDownloading = false
                self?.progress = 1.0
                self?.updateStatusBar(nil)
                self?.onComplete?()
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Failed to save model: \(error.localizedDescription)"
                self?.isDownloading = false
                self?.updateStatusBar(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Download failed: \(error.localizedDescription)"
                self?.isDownloading = false
                self?.updateStatusBar(nil)
            }
        }
    }

    private func updateStatusBar(_ text: String?) {
        DispatchQueue.main.async { [weak self] in
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.statusBar?.updateDownloadProgress(text)
            }
            _ = self  // prevent unused warning
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isRecordingHotkey = false
    @State private var pendingModelDownload: String? = nil
    @StateObject private var downloadManager = InlineDownloadManager()
    @State private var launchAtLogin = false
    /// Tracks the previous language so we can save its model on switch
    @State private var previousLanguage: String = ""

    /// Tracks the picker selection separately so we can intercept "Other..." (999)
    @State private var hotkeyPickerSelection: UInt16 = 0

    /// Consistent label width for aligned rows
    private let labelWidth: CGFloat = 180

    /// Sorted language list for the picker
    private var sortedLanguages: [WhisperLanguage] {
        WhisperLanguage.all.sorted { $0.name < $1.name }
    }

    /// Whether current hotkey matches one of the standard options
    private var isCustomHotkey: Bool {
        !standardHotkeyOptions.contains(where: { $0.keyCode == viewModel.hotkeyKeyCode })
    }

    /// Display string for the current hotkey
    private var hotkeyDisplay: String {
        KeyCodes.describe(keyCode: viewModel.hotkeyKeyCode, modifiers: viewModel.hotkeyModifiers)
    }

    /// Helper for consistent label-control rows
    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Text("\(UsageStats.shared.totalDictations) dictations, saving \(UsageStats.shared.timeSavedDescription) and \(UsageStats.shared.keystrokesDescription) keystrokes")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

            ScrollView {
                VStack(spacing: 16) {
                // -- GENERAL -----------------------------------------------
                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(.checkbox)
                            .onChange(of: launchAtLogin) { newValue in
                                LaunchAtLogin.isEnabled = newValue
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    launchAtLogin = LaunchAtLogin.isEnabled
                                }
                            }

                        hotkeyRow

                        storageRow
                    }
                    .padding(.vertical, 4)
                }

                // -- TRANSCRIPTION -----------------------------------------
                GroupBox("Transcription") {
                    VStack(alignment: .leading, spacing: 10) {
                        languageRow
                        modelRow
                        inlineDownloadSection
                        punctuationRow
                    }
                    .padding(.vertical, 4)
                }

                // -- PERFORMANCE -------------------------------------------
                GroupBox("Performance") {
                    VStack(alignment: .leading, spacing: 10) {
                        preBufferRow
                        streamingPreviewRow
                        keepModelLoadedRow
                    }
                    .padding(.vertical, 4)
                }

                // -- VOCABULARY & CONTEXT ----------------------------------
                GroupBox("Vocabulary & Context") {
                    VStack(alignment: .leading, spacing: 10) {
                        correctionsRow
                        screenContextRow
                        vocabularyStatusRow
                    }
                    .padding(.vertical, 4)
                }

                // -- ADVANCED ----------------------------------------------
                GroupBox("Advanced") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Diagnostic Logging", isOn: $viewModel.diagnosticLogging)
                                .toggleStyle(.checkbox)
                                .onChange(of: viewModel.diagnosticLogging) { newValue in
                                    viewModel.save()
                                    DiagnosticLogger.shared.setEnabled(newValue)
                                }
                            Spacer()
                            Button("Open Logs Folder\u{2026}") {
                                let logsDir = Config.configDir.appendingPathComponent("logs")
                                try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(logsDir)
                            }
                            .controlSize(.small)
                        }
                        Text("Logs session activity to help diagnose issues. Logs are stored locally.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // -- EXPERIMENTAL ------------------------------------------
                GroupBox("Experimental") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Live Preview", isOn: $viewModel.streamingEnabled)
                            .toggleStyle(.checkbox)
                            .onChange(of: viewModel.streamingEnabled) { _ in viewModel.save() }
                        Text("Shows transcribed text as you speak. Work in progress — text may flicker or change.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                } // end VStack
                .padding(16)
            } // end ScrollView
            } // end VStack

            if isRecordingHotkey {
                KeyRecorderOverlay(
                    onCapture: { keyCode, modifiers in
                        viewModel.hotkeyKeyCode = keyCode
                        viewModel.hotkeyModifiers = modifiers
                        hotkeyPickerSelection = keyCode
                        viewModel.save()
                        isRecordingHotkey = false
                    },
                    onCancel: {
                        hotkeyPickerSelection = viewModel.hotkeyKeyCode
                        isRecordingHotkey = false
                    }
                )
            }
        }
        .onAppear {
            hotkeyPickerSelection = viewModel.hotkeyKeyCode
            launchAtLogin = LaunchAtLogin.isEnabled
            previousLanguage = viewModel.language
            checkPendingDownload()
        }
        .onChange(of: hotkeyPickerSelection) { newValue in
            if newValue == otherHotkeyTag {
                isRecordingHotkey = true
            } else {
                viewModel.hotkeyKeyCode = newValue
                viewModel.hotkeyModifiers = []
                viewModel.save()
            }
        }
        .onChange(of: viewModel.toggleMode) { _ in viewModel.save() }
        .onChange(of: viewModel.modelSize) { newModel in
            viewModel.save()
            checkPendingDownload()
        }
        .onChange(of: viewModel.language) { _ in
            viewModel.save()
            checkPendingDownload()
        }
        .onChange(of: viewModel.punctuationMode) { _ in viewModel.save() }
        .onChange(of: viewModel.rememberWords) { _ in viewModel.save() }
        .onChange(of: viewModel.screenContext) { newValue in
            viewModel.save()
            if newValue && !ScreenContext.hasPermission {
                _ = ScreenContext.requestPermission()
            }
        }
        .onChange(of: viewModel.maxRecordings) { _ in viewModel.save() }
        .onChange(of: viewModel.preBuffer) { _ in viewModel.save() }
        .onChange(of: viewModel.keepModelLoaded) { _ in viewModel.save() }
        .onChange(of: viewModel.streamingEnabled) { _ in viewModel.save() }
    }

    /// Check if the currently selected model needs downloading
    private func checkPendingDownload() {
        if !SettingsViewModel.modelExists(viewModel.modelSize) {
            pendingModelDownload = viewModel.modelSize
        } else {
            pendingModelDownload = nil
        }
    }

    // MARK: - Hotkey Row

    private var hotkeyRow: some View {
        settingsRow("Hotkey") {
            Picker("", selection: $hotkeyPickerSelection) {
                if isCustomHotkey {
                    Text(hotkeyDisplay).tag(viewModel.hotkeyKeyCode)
                    Divider()
                }
                ForEach(standardHotkeyOptions) { option in
                    Text(option.label).tag(option.keyCode)
                }
                Divider()
                Text("Other\u{2026}").tag(otherHotkeyTag)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 170)

            Picker("", selection: $viewModel.toggleMode) {
                Text("Hold").tag(false)
                Text("Toggle").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 100)
        }
    }

    // MARK: - Language Row

    private var languageRow: some View {
        settingsRow("Language") {
            Picker("", selection: $viewModel.language) {
                Text("Auto-detect").tag("auto")
                Divider()
                ForEach(sortedLanguages) { lang in
                    Text(lang.name).tag(lang.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: - Model Row

    private var modelRow: some View {
        let models = availableModels(language: viewModel.language)
        return VStack(alignment: .leading, spacing: 2) {
            settingsRow("Model") {
                Picker("", selection: $viewModel.modelSize) {
                    ForEach(models) { model in
                        Text(model.label)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 240)
                .lineLimit(1)
                .onChange(of: viewModel.language) { newLang in
                    if previousLanguage != newLang {
                        viewModel.languageModels[previousLanguage] = viewModel.modelSize
                    }
                    previousLanguage = newLang

                    if let savedModel = viewModel.languageModels[newLang] {
                        let newModels = availableModels(language: newLang)
                        if newModels.contains(where: { $0.id == savedModel }) {
                            viewModel.modelSize = savedModel
                            return
                        }
                    }

                    let newModels = availableModels(language: newLang)
                    if !newModels.contains(where: { $0.id == viewModel.modelSize }) {
                        let base = viewModel.modelSize.replacingOccurrences(of: ".en", with: "")
                        if let match = newModels.first(where: { $0.id.hasPrefix(base) }) {
                            viewModel.modelSize = match.id
                        }
                    }
                }
            }

            Text("Larger models are more accurate but use more memory.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, labelWidth)

            if let delegate = NSApplication.shared.delegate as? AppDelegate,
               delegate.activeModelSize != viewModel.modelSize {
                Text("Currently using: \(delegate.activeModelSize)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, labelWidth)
            }
        }
    }

    // MARK: - Inline Download Section

    @ViewBuilder
    private var inlineDownloadSection: some View {
        if let pending = pendingModelDownload {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(pending) (\(SettingsViewModel.modelDownloadSize(pending)))")
                        .font(.body.weight(.medium))
                    Text("\u{2014} not downloaded")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let error = downloadManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if downloadManager.isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Downloading... \(Int(downloadManager.progress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        ProgressView(value: downloadManager.progress, total: 1.0)
                            .progressViewStyle(.linear)
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                downloadManager.cancelDownload()
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    HStack {
                        Button("Download") {
                            downloadManager.startDownload(modelSize: pending) { [self] in
                                pendingModelDownload = nil
                            }
                        }

                        Spacer()

                        Button("Open Models Folder\u{2026}") {
                            let modelsDir = SettingsViewModel.modelsDirectory
                            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(modelsDir)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Punctuation Row

    private var punctuationRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingsRow("Punctuation") {
                Picker("", selection: $viewModel.punctuationMode) {
                    Text("Automatic & Spoken").tag(PunctuationMode.hybrid)
                    Text("Automatic Only").tag(PunctuationMode.off)
                    Text("Spoken Only").tag(PunctuationMode.spoken)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Automatic Only: Natural punctuation. \u{201C}comma\u{201D} transcribes as a word.")
                Text("Spoken Only: No auto-punctuation. Say \u{201C}comma\u{201D} or \u{201C}period\u{201D} explicitly.")
                Text("Automatic & Spoken: Auto-punctuation plus spoken commands.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, labelWidth)
        }
    }

    // MARK: - Corrections Row

    private var correctionsRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle("Learn From My Corrections", isOn: $viewModel.rememberWords)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Reset") { WordMemory.resetAll() }
                    .controlSize(.small)
            }
            Text("Corrected words are added to your vocabulary to improve future transcriptions.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Screen Context Row

    private var screenContextRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Use Screen Context", isOn: $viewModel.screenContext)
                .toggleStyle(.checkbox)
            Text("Uses local OCR to read on-screen text, helping match names and terms.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Vocabulary Status Row

    private var vocabularyStatusRow: some View {
        HStack {
            Spacer()
            let count = WordMemory.loadVocabularyEntries().count
            Button("Edit Vocabulary File") {
                let url = Config.vocabularyFile
                let dir = Config.configDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    let template = "# Vocabulary for speakfree\n# One word or phrase per line.\n# Lines starting with # are ignored.\n"
                    try? template.write(to: url, atomically: true, encoding: .utf8)
                }
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
            Text("(\(count) word\(count == 1 ? "" : "s"))")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Storage Row

    private var storageRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingsRow("Show Past Recordings") {
                Picker("", selection: $viewModel.maxRecordings) {
                    ForEach(maxRecordingsOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
            }
            Text("Shows recent dictations in the toolbar menu.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, labelWidth)
        }
    }

    // MARK: - Pre-Buffer Row

    private var preBufferRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingsRow("Pre-Buffer Audio") {
                Picker("", selection: $viewModel.preBuffer) {
                    Text("On").tag(true)
                    Text("Off").tag(false)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
            }

            Text("Captures audio before you press the hotkey so no words are lost. Recording indicator stays on.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, labelWidth)
        }
    }

    // MARK: - Streaming Preview Row

    private var streamingPreviewRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Show Live Preview", isOn: $viewModel.streamingEnabled)
                .toggleStyle(.checkbox)
            Text("Shows transcribed text in the overlay as you speak. May use more CPU.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Keep Model Loaded Row

    private var keepModelLoadedRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingsRow("Keep Model Loaded") {
                Picker("", selection: $viewModel.keepModelLoaded) {
                    Text("Automatic").tag("auto")
                    Text("Always").tag("always")
                    Text("Off").tag("off")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Loading the model takes about \(SettingsViewModel.modelLoadTimeDescription(viewModel.modelSize)) on your Mac.")
                Text("Keeping it loaded uses \(SettingsViewModel.modelMemoryDescription(viewModel.modelSize)).")
                Text("Automatic unloads the model whenever your Mac needs the memory.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, labelWidth)
        }
    }
}
