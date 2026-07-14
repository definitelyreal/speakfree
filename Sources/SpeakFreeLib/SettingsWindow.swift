import AppKit
import SwiftUI

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(viewModel: SettingsViewModel) {
        if shared == nil {
            shared = SettingsWindowController(viewModel: viewModel)
            // Hide dock icon when settings window closes
            if let window = shared?.window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { _ in NSApp.hideDockIconIfNoWindows() }
            }
        }
        NSApp.showDockIconIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)

        // LSUIElement apps don't get standard menus, so Cmd+W doesn't work.
        // Install a minimal main menu with Close when settings are shown.
        Self.installMainMenu()
    }

    private static func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit speakfree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    convenience init(viewModel: SettingsViewModel) {
        let hostingController = NSHostingController(rootView: SettingsView(viewModel: viewModel))

        // Size the window to 4/5 of the screen height, capped at a reasonable max
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let windowHeight = min(screenHeight * 0.8, 900)

        hostingController.preferredContentSize = NSSize(width: 480, height: windowHeight)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "speakfree Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 480, height: windowHeight))
        window.minSize = NSSize(width: 480, height: 500)
        window.maxSize = NSSize(width: 600, height: screenHeight)
        window.center()
        window.isReleasedWhenClosed = false

        // Ensure the window stays on-screen when displays change
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            window.constrainFrameRect(window.frame, to: window.screen)
        }

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
        let base = "\(id) (\(memory), \(speed) load)"
        return isRecommended ? "\(base) \u{2014} Recommended" : base
    }
}

private func availableModels(language: String) -> [ModelInfo] {
    let isEnglish = (language == "en")
    let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)

    let recommendedBase: String
    if ramGB >= 16 { recommendedBase = "turbo" }
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
        RawModel(enId: "large-v3-turbo", multiId: "large-v3-turbo", base: "turbo", memory: "~1.6 GB", speed: "~1.1s"),
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

// Keep-everything is the default: recordings are the dictation corpus that makes
// accuracy regressions diagnosable. Pruning is the explicit opt-in.
private let maxRecordingsOptions: [(label: String, value: Int)] = [
    ("Keep everything", 0),
    ("Last 10", 10),
    ("Last 20", 20),
    ("Last 30", 30),
    ("Last 50", 50),
    ("Last 100", 100),
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

/// Manages inline model downloads for the settings panel.
///
/// T2.4: this is now a thin SwiftUI-facing shell over `ModelDownloadCoordinator`.
/// It owns only the `@Published` UI state + status-bar text; the coordinator owns
/// the URLSession, progress, SHA256 verification (T1.5), and the atomic install.
private class InlineDownloadManager: NSObject, ObservableObject {
    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?

    private var coordinator: ModelDownloadCoordinator?
    private var modelSize: String = ""

    func startDownload(modelSize: String, onComplete: @escaping () -> Void) {
        self.modelSize = modelSize
        self.errorMessage = nil
        self.progress = 0

        let coordinator = ModelDownloadCoordinator()
        self.coordinator = coordinator

        coordinator.onProgress = { [weak self] fraction, _, _ in
            guard let self = self else { return }
            self.progress = fraction
            self.updateStatusBar("Downloading \(self.modelSize)... \(Int(fraction * 100))%")
        }
        coordinator.onSuccess = { [weak self] _ in
            guard let self = self else { return }
            self.isDownloading = false
            self.progress = 1.0
            self.updateStatusBar(nil)
            onComplete()
        }
        coordinator.onFailure = { [weak self] error in
            guard let self = self else { return }
            self.errorMessage = self.userMessage(for: error)
            self.isDownloading = false
            self.updateStatusBar(nil)
        }

        // Mark downloading up front; the coordinator's already-exists short-circuit
        // will immediately fire onSuccess (which clears it) when nothing to fetch.
        isDownloading = true
        coordinator.start(modelSize: modelSize)
    }

    func cancelDownload() {
        coordinator?.cancel()
        coordinator = nil
        isDownloading = false
        progress = 0
        updateStatusBar(nil)
    }

    /// Preserve the prior per-error copy: invalid-model and save-failure wording.
    private func userMessage(for error: Error) -> String {
        switch error {
        case ModelDownloadError.invalidModel:
            return "Downloaded file is not a valid Whisper model"
        case ModelDownloadError.hashMismatch:
            return (error as? LocalizedError)?.errorDescription ?? "Download failed integrity check"
        default:
            return "Download failed: \(error.localizedDescription)"
        }
    }

    private func updateStatusBar(_ text: String?) {
        DispatchQueue.main.async {
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.statusBar?.updateDownloadProgress(text)
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isRecordingHotkey = false
    @State private var isHoveringGitHub = false
    @State private var pendingModelDownload: String? = nil
    @StateObject private var downloadManager = InlineDownloadManager()
    @State private var launchAtLogin = false
    /// Tracks the previous language so we can save its model on switch
    @State private var previousLanguage: String = ""
    /// Last model that was actually on disk — used to revert on download cancel
    @State private var previousWorkingModel: String? = nil

    /// Tracks the picker selection separately so we can intercept "Other..." (999)
    @State private var hotkeyPickerSelection: UInt16 = 0
    /// Gates the "Show Recording Folder" button: enabled only when the folder exists
    /// and holds at least one audio file. Refreshed on appear and when the toggle flips.
    @State private var recordingsFolderHasAudio = false

    private func refreshRecordingsFolderState() {
        recordingsFolderHasAudio = RecordingStore.hasAudioFiles()
    }

    /// Consistent label width across ALL Grid sections.
    private let labelWidth: CGFloat = 105

    /// Sorted language list for the picker
    private var sortedLanguages: [WhisperLanguage] {
        WhisperLanguage.all.sorted { $0.name < $1.name }
    }

    /// The currently selected Parakeet model's catalog entry (nil when on Whisper or unknown id).
    private var selectedParakeetModelInfo: ParakeetModelInfo? {
        guard viewModel.engine == "parakeet" else { return nil }
        return EngineCatalog.parakeetModels.first(where: { $0.id == viewModel.parakeetModel })
    }

    /// Languages to offer in the shared Language picker. Whisper supports the full list;
    /// Parakeet is constrained to its selected model's `supportedLanguages` (v2 = English only,
    /// v3 = its multilingual set). Falls back to the full list if the model is unknown.
    private var pickerLanguages: [WhisperLanguage] {
        guard let info = selectedParakeetModelInfo else { return sortedLanguages }
        let allowed = Set(info.supportedLanguages)
        return sortedLanguages.filter { allowed.contains($0.id) }
    }

    /// Footnote describing the Parakeet language constraint, shown only for Parakeet.
    private var parakeetLanguageNote: String? {
        guard let info = selectedParakeetModelInfo else { return nil }
        if info.supportedLanguages == ["en"] {
            return "\(info.displayName) supports English only. Other languages are ignored."
        }
        return "\(info.displayName) supports a fixed set of languages; unsupported selections are ignored."
    }

    /// True when the selected Parakeet model is English-only (v2). A language picker is
    /// pointless then — Parakeet uses language only as a hint and this model ignores it —
    /// so we hide the Language row and let the footnote explain it instead.
    private var isParakeetEnglishOnly: Bool {
        viewModel.engine == "parakeet" && selectedParakeetModelInfo?.supportedLanguages == ["en"]
    }

    /// Whether current hotkey matches one of the standard options
    private var isCustomHotkey: Bool {
        !standardHotkeyOptions.contains(where: { $0.keyCode == viewModel.hotkeyKeyCode })
    }

    /// Display string for the current hotkey
    private var hotkeyDisplay: String {
        KeyCodes.describe(keyCode: viewModel.hotkeyKeyCode, modifiers: viewModel.hotkeyModifiers)
    }

    /// Helper for consistent label-control rows.
    /// Labels left-aligned in a fixed column, controls fill remaining space.
    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                Text("\(UsageStats.shared.totalDictations) dictations, saving \(UsageStats.shared.timeSavedDescription) and \(UsageStats.shared.keystrokesDescription) keystrokes")
                    .font(.callout)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                // -- GENERAL -----------------------------------------------
                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(.checkbox)
                            .onChange(of: launchAtLogin) { newValue in
                                LaunchAtLogin.isEnabled = newValue
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    launchAtLogin = LaunchAtLogin.isEnabled
                                }
                            }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text("Hotkey").frame(width: labelWidth, alignment: .leading).gridColumnAlignment(.leading)
                                HStack(spacing: 8) {
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

                            GridRow {
                                Text("Recordings")
                                Toggle("Save recordings for debugging", isOn: $viewModel.saveRecordings)
                                    .onChange(of: viewModel.saveRecordings) { _ in
                                        viewModel.save()
                                        refreshRecordingsFolderState()
                                    }
                            }

                            if viewModel.saveRecordings {
                                GridRow {
                                    Text("Past Recordings")
                                    Picker("", selection: $viewModel.maxRecordings) {
                                        ForEach(maxRecordingsOptions, id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(width: 150, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 8) {
                            Text("Recordings and transcripts are saved only to this Mac. They are never sent anywhere.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Show Recording Folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([RecordingStore.recordingsDir])
                            }
                            .controlSize(.small)
                            .disabled(!recordingsFolderHasAudio)
                        }
                        .onAppear { refreshRecordingsFolderState() }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }

                // -- TRANSCRIPTION -----------------------------------------
                GroupBox("Transcription") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Parakeet engine picker
                        EnginePickerView(viewModel: viewModel)

                        modelStatusBanner

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            // Language row is hidden for English-only Parakeet (v2) — a
                            // one-item "English" picker is pointless; the footnote covers it.
                            if !isParakeetEnglishOnly {
                            GridRow {
                                Text("Language").frame(width: labelWidth, alignment: .leading).gridColumnAlignment(.leading)
                                Picker("", selection: $viewModel.language) {
                                    Text("Auto-detect").tag("auto")
                                    Divider()
                                    ForEach(pickerLanguages) { lang in
                                        Text(lang.name).tag(lang.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .onChange(of: viewModel.language) { newLang in
                                    // Whisper-only: language switches carry the per-language
                                    // ggml model selection. Parakeet uses language only as a
                                    // hint, so skip all hidden model bookkeeping.
                                    guard viewModel.engine == "whisper" else { return }

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
                            }  // end if !isParakeetEnglishOnly

                            // Whisper-specific ggml model picker. Parakeet's downloadable
                            // model variants (v2/v3) are chosen in EnginePickerView above, so
                            // this per-language ggml dropdown is hidden for that engine.
                            if viewModel.engine == "whisper" {
                                GridRow {
                                    Text("Model")
                                    Picker("", selection: $viewModel.modelSize) {
                                        ForEach(availableModels(language: viewModel.language)) { model in
                                            Text(model.label)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .tag(model.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .lineLimit(1)
                                }
                            }

                            GridRow {
                                Text("Punctuation")
                                Picker("", selection: $viewModel.punctuationMode) {
                                    Text("Automatic & Spoken").tag(PunctuationMode.hybrid)
                                    Text("Automatic Only").tag(PunctuationMode.off)
                                    Text("Spoken Only").tag(PunctuationMode.spoken)
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let note = parakeetLanguageNote {
                            Text(note)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Larger models are more accurate but use more memory.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }

                // -- PERFORMANCE -------------------------------------------
                GroupBox("Performance") {
                    VStack(alignment: .leading, spacing: 14) {
                        preBufferRow

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text("Model Loading").frame(width: labelWidth, alignment: .leading).gridColumnAlignment(.leading)
                                Picker("", selection: $viewModel.keepModelLoaded) {
                                    Text("Automatic").tag("auto")
                                    Text("Always").tag("always")
                                    Text("Off").tag("off")
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(width: 120, alignment: .leading)
                                // Parakeet manages its own model lifecycle; this control has
                                // no effect for it (memory-pressure policy is a no-op).
                                .disabled(viewModel.engine != "whisper")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            if viewModel.engine == "whisper" {
                                Text("Loading the model takes about \(SettingsViewModel.modelLoadTimeDescription(viewModel.modelSize)) on your Mac.")
                                Text("Keeping it loaded uses \(SettingsViewModel.modelMemoryDescription(viewModel.modelSize)).")
                                Text("Automatic unloads the model whenever your Mac needs the memory.")
                            } else {
                                Text("Parakeet manages model loading automatically; this setting has no effect.")
                            }
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }

                // -- VOCABULARY & CONTEXT ----------------------------------
                GroupBox("Vocabulary & Context") {
                    VStack(alignment: .leading, spacing: 14) {
                        vocabularyStatusRow
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }

                // -- ADVANCED ----------------------------------------------
                GroupBox("Advanced") {
                    VStack(alignment: .leading, spacing: 14) {
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
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Live Preview (Experimental)", isOn: $viewModel.streamingEnabled)
                                .toggleStyle(.checkbox)
                                .onChange(of: viewModel.streamingEnabled) { _ in viewModel.save() }
                            Text("Shows transcribed text as you speak. Work in progress \u{2014} text may flicker.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }

                        localAPIRow

                        screenContextRow
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }

                // Footer — scrolls with content, not pinned
                Divider()
                    .padding(.top, 8)
                HStack(spacing: 0) {
                    Text("Proudly vibe coded. ")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/definitelyreal/speakfree")!)
                    } label: {
                        Text("Let's improve it together →")
                            .font(.caption)
                            .foregroundColor(Color(red: 0.6, green: 0.2, blue: 0.8))
                            .underline(isHoveringGitHub)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringGitHub = $0 }
                    Spacer()
                }
                .padding(.vertical, 12)
                } // end VStack
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            } // end ScrollView

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
        .onChange(of: viewModel.engine) { _ in
            // Engine onChange lives in EnginePickerView and only refreshes its own
            // state, so the orange whisper banner can go stale when switching to
            // Parakeet. Re-run here (early-returns nil for non-whisper engines).
            checkPendingDownload()
            reconcilePickerLanguage()
        }
        .onChange(of: viewModel.parakeetModel) { _ in
            // Switching Parakeet variants (v2 English-only <-> v3 multilingual)
            // can drop the bound language tag out of pickerLanguages.
            reconcilePickerLanguage()
        }
        .onChange(of: viewModel.punctuationMode) { _ in viewModel.save() }
        .onChange(of: viewModel.maxRecordings) { _ in viewModel.save() }
        .onChange(of: viewModel.preBuffer) { _ in viewModel.save() }
        .onChange(of: viewModel.keepModelLoaded) { _ in viewModel.save() }
        .onChange(of: viewModel.streamingEnabled) { _ in viewModel.save() }
    }

    /// Check if the currently selected model needs downloading.
    /// Whisper-only: `modelExists`/`modelSize` describe the ggml model. Parakeet manages its
    /// own download state in EnginePickerView, so the orange banner must not appear for it.
    private func checkPendingDownload() {
        guard viewModel.engine == "whisper" else {
            pendingModelDownload = nil
            return
        }
        if !SettingsViewModel.modelExists(viewModel.modelSize) {
            // Remember the last working model so we can revert on cancel
            if previousWorkingModel == nil || SettingsViewModel.modelExists(previousWorkingModel ?? "") {
                // Keep the existing previousWorkingModel if it's still valid
            } else {
                previousWorkingModel = nil
            }
            if pendingModelDownload == nil {
                // Save what we had before this change
                if let delegate = NSApplication.shared.delegate as? AppDelegate {
                    previousWorkingModel = delegate.activeModelSize
                }
            }
            pendingModelDownload = viewModel.modelSize
        } else {
            pendingModelDownload = nil
            previousWorkingModel = viewModel.modelSize
        }
    }

    /// Keep the Language picker's bound selection inside the options it actually renders.
    /// Whisper offers the full list, so its saved language is never out of range. Parakeet
    /// constrains options to the selected model's `supportedLanguages`; when the current
    /// language falls outside that set (e.g. v2 is English-only but language=="fr"), the
    /// Picker would render blank because its tag isn't present. Coerce to "auto", which is
    /// always offered. Only touches the value for Parakeet, so the saved whisper language
    /// is left intact.
    private func reconcilePickerLanguage() {
        guard let info = selectedParakeetModelInfo else { return }
        if viewModel.language != "auto" && !info.supportedLanguages.contains(viewModel.language) {
            viewModel.language = "auto"
        }
    }

    // MARK: - Model Status Banner

    /// Display name for the current language selection (e.g. "Estonian" not "et")
    private var languageDisplayName: String {
        if viewModel.language == "auto" { return "Auto-detect" }
        return WhisperLanguage.all.first(where: { $0.id == viewModel.language })?.name ?? viewModel.language
    }

    /// Dismiss button for banners — large click target
    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modelStatusBanner: some View {
        if let pending = pendingModelDownload {
            // Model needs downloading
            VStack(alignment: .leading, spacing: 8) {
                if downloadManager.isDownloading {
                    // Downloading state
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Downloading \(languageDisplayName) \(pending)\u{2026} \(Int(downloadManager.progress * 100))%")
                                .font(.callout.weight(.medium))
                            ProgressView(value: downloadManager.progress, total: 1.0)
                                .progressViewStyle(.linear)
                        }
                        dismissButton {
                            downloadManager.cancelDownload()
                        }
                    }
                } else {
                    // Not downloaded state
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.orange)
                        Text("\(languageDisplayName) \(pending)")
                            .font(.callout.weight(.medium))
                        Text("(\(SettingsViewModel.modelDownloadSize(pending)))")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Download") {
                            downloadManager.startDownload(modelSize: pending) { [self] in
                                pendingModelDownload = nil
                            }
                        }
                        .controlSize(.small)
                        dismissButton {
                            // Revert to the previous working model
                            if let prev = previousWorkingModel {
                                viewModel.modelSize = prev
                            }
                            pendingModelDownload = nil
                        }
                    }

                    if let error = downloadManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Punctuation Row

    private var punctuationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingsRow("Punctuation") {
                Picker("", selection: $viewModel.punctuationMode) {
                    Text("Automatic & Spoken").tag(PunctuationMode.hybrid)
                    Text("Automatic Only").tag(PunctuationMode.off)
                    Text("Spoken Only").tag(PunctuationMode.spoken)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Automatic Only: Natural punctuation. \u{201C}comma\u{201D} transcribes as a word.")
                Text("Spoken Only: No auto-punctuation. Say \u{201C}comma\u{201D} or \u{201C}period\u{201D} explicitly.")
                Text("Automatic & Spoken: Auto-punctuation plus spoken commands.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 2)
        }
    }

    // MARK: - Local API Row

    private var localAPIRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Local Transcription API (Experimental)", isOn: $viewModel.localAPIEnabled)
                .toggleStyle(.checkbox)
                .onChange(of: viewModel.localAPIEnabled) { _ in viewModel.save() }
            Text("Exposes POST http://localhost:\(viewModel.localAPIPort)/v1/audio/transcriptions — works with any OpenAI-compatible audio client. Beta \u{2014} try it and let us know how it works.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Screen Context Row

    private var screenContextRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Screen Context (Experimental)", isOn: $viewModel.screenContext)
                .toggleStyle(.checkbox)
                .onChange(of: viewModel.screenContext) { newValue in
                    viewModel.save()
                    if newValue && !ScreenContext.hasPermission {
                        _ = ScreenContext.requestPermission()
                    }
                }
            Text("Uses local OCR to read on-screen text as vocabulary hints. Can cause hallucinations \u{2014} whisper may generate text from screen content instead of transcribing speech.")
                .font(.footnote)
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
        VStack(alignment: .leading, spacing: 4) {
            settingsRow("Past Recordings") {
                Picker("", selection: $viewModel.maxRecordings) {
                    ForEach(maxRecordingsOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150, alignment: .leading)
            Spacer()
            }
            Text("Shows recent dictations in the toolbar menu.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 0)
        }
    }

    // MARK: - Pre-Buffer Row

    private var preBufferRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Pre-Buffer Audio", isOn: $viewModel.preBuffer)
                .toggleStyle(.checkbox)
            Text("Captures audio before you press the hotkey so no words are lost.")
                .font(.caption)
                .foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 4) {
            settingsRow("Keep Model Loaded") {
                Picker("", selection: $viewModel.keepModelLoaded) {
                    Text("Automatic").tag("auto")
                    Text("Always").tag("always")
                    Text("Off").tag("off")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120, alignment: .leading)
            Spacer()
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Loading the model takes about \(SettingsViewModel.modelLoadTimeDescription(viewModel.modelSize)) on your Mac.")
                Text("Keeping it loaded uses \(SettingsViewModel.modelMemoryDescription(viewModel.modelSize)).")
                Text("Automatic unloads the model whenever your Mac needs the memory.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 2)
        }
    }
}
