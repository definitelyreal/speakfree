import AppKit
import SwiftUI

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    /// P2: whether the Settings window is currently on-screen. External config writers
    /// (recordings notice, menu-bar mic selector) use this to know they must re-sync the
    /// cached view model from disk so its next save can't overlay a stale snapshot.
    static var isWindowVisible: Bool {
        shared?.window?.isVisible == true
    }

    static func show(viewModel: SettingsViewModel) {
        let openStart = CFAbsoluteTimeGetCurrent()
        defer {
            // Michael 2026-08-20: "going to the settings menu now has a solid pause."
            // Stage-timed so a recurrence names its culprit instead of needing a profiler.
            let total = CFAbsoluteTimeGetCurrent() - openStart
            if total >= 0.1 {
                DiagnosticLogger.shared.log(String(
                    format: "Settings: slow open — %.2fs from click to window", total))
            }
        }
        // PR-B: the view model is long-lived and cached by AppDelegate. If the recordings
        // notice (or anything else) changed config on disk while the window was closed, the
        // cached view model holds a stale snapshot whose next save would overlay it back.
        // Re-sync from disk whenever we're (re)opening a window that isn't already visible.
        if shared?.window?.isVisible != true {
            viewModel.refreshFromDisk()
        }
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

struct HotkeyOption: Hashable, Identifiable {
    let label: String
    let keyCode: UInt16
    var id: UInt16 { keyCode }
}

/// Internal, not private: HotkeyAdviceTests asserts the Globe-key banner's fix target is
/// actually one of these. Removing Right Option here would leave that link setting a
/// selection with no matching tag (a blank picker) with a fully green suite.
let standardHotkeyOptions: [HotkeyOption] = [
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
    let isDownloaded: Bool

    var label: String {
        var base = "\(id) (\(memory), \(speed) load)"
        if isRecommended { base += " \u{2014} Recommended" }
        // Michael 2026-08-19: un-downloaded models must be visibly different in the
        // dropdown, so picking one is a knowing "this will download" choice.
        if !isDownloaded { base += "  (Not Downloaded)" }
        return base
    }
}

/// Thin adapter over EngineCatalog.whisperModels — the table itself moved there so the Help
/// window reads the same source instead of a hand-typed copy that drifted (2026-07-26).
private func availableModels(language: String) -> [ModelInfo] {
    let recommendedBase = EngineCatalog.recommendedWhisperBase()
    return EngineCatalog.whisperModels.map { model in
        let id = model.id(forLanguage: language)
        return ModelInfo(
            id: id,
            memory: model.memoryDescription,
            speed: model.loadTimeDescription,
            isRecommended: model.base == recommendedBase,
            isDownloaded: Transcriber.modelExists(modelSize: id)
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

    /// Which `modifierFlags` bit a modifier-only keyCode raises, so a `.flagsChanged` event can be
    /// told apart as a PRESS (bit now set) from a RELEASE (bit now clear). Left/right variants of
    /// one modifier share a bit; the keyCode is what distinguishes them, and it is the keyCode we
    /// record.
    private static let modifierFlagForKeyCode: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command,      // right / left ⌘
        56: .shift, 60: .shift,          // left / right ⇧
        58: .option, 61: .option,        // left / right ⌥
        59: .control, 62: .control,      // left / right ⌃
        63: .function,                   // fn
    ]

    func install(onCapture: @escaping (UInt16, [String]) -> Void, onCancel: @escaping () -> Void) {
        // `.flagsChanged` as well as `.keyDown` (2026-08-05). A bare modifier never produces a
        // keyDown, so listening only for keyDown made Shift and Right Control selectable from the
        // config file and CLI but IMPOSSIBLE to pick in Settings — two of the nine supported
        // hotkeys, unreachable through the only UI most people have. `HotkeyValidator.validate`
        // already returns `.allowed` for a lone modifier, so the monitor was the whole gap.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                guard let flag = Self.modifierFlagForKeyCode[event.keyCode] else { return nil }
                // Capture on press only. Without this the release event immediately re-fires and
                // the recorder would resolve twice for one physical tap.
                guard event.modifierFlags.contains(flag) else { return nil }
                // A modifier pressed while ANOTHER modifier is already held is a chord in
                // progress, not a lone-modifier choice — let it settle rather than capturing ⌘
                // the instant the user starts pressing ⌘⇧.
                let others = Self.modifierFlagForKeyCode
                    .filter { $0.key != event.keyCode && $0.value != flag }
                    .values
                if others.contains(where: { event.modifierFlags.contains($0) }) { return nil }
                onCapture(event.keyCode, [])
                return nil
            }

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
    /// Gates the "Open Recordings / Transcripts Folder" button (enabled only when audio
    /// files exist) and feeds the stored-count line. Refreshed on appear, on toggle
    /// flips, and after an in-app delete.
    @State private var recordingsFolderHasAudio = false
    @State private var storedRecordingCount = 0
    @State private var showDeleteRecordingsSheet = false

    /// Microphone pin (moved here from the menu, Michael 2026-08-14). "" = the built-in
    /// default; any other value is a device UID pinned via AppDelegate.selectInputDevice.
    /// Snapshot of the device list is taken on appear — cache-only reads, same rule as the
    /// menu (live CoreAudio reads on main wedged the app on 2026-07-15).
    @State private var micSelection: String = ""
    @State private var micDevices: [AudioInputDevice] = []

    private var micBuiltInUID: String? { AudioDeviceCatalog.cachedBuiltInInput?.uid }

    private var micDefaultLabel: String {
        // Honest default label (2026-08-12): with no explicit pick, speakfree captures the
        // BUILT-IN mic; only a Mac with no built-in input falls back to the system default.
        if let builtIn = AudioDeviceCatalog.cachedBuiltInInput {
            return "\(builtIn.name) (default)"
        }
        let systemName = AudioDeviceCatalog.cachedDefaultInput?.name ?? "System Default"
        return "System Default (\(systemName))"
    }

    private func refreshMicState() {
        micDevices = AudioDeviceCatalog.cachedInputDevices
        let pinned = (NSApplication.shared.delegate as? AppDelegate)?.currentInputDeviceUID()
        // An explicit pin of the built-in mic captures identically to the implicit default,
        // so both states select the default entry (adversarial review 2026-08-12).
        micSelection = (pinned == nil || pinned == micBuiltInUID) ? "" : pinned!
    }

    private func refreshRecordingsFolderState() {
        // M2 + 2026-08-20: the count cache is COLD on the first Settings open each launch,
        // and cachedRecordingCount() then live-scans the recordings dir on the CALLING
        // thread — ~250ms over today's 61k files, on main, inside the window's first
        // render (Michael: "going to the settings menu now has a solid pause"). Hop the
        // read to a background queue; warm-cache refreshes still come back instantly.
        DispatchQueue.global(qos: .userInitiated).async {
            let count = RecordingStore.cachedRecordingCount()
            DispatchQueue.main.async {
                storedRecordingCount = count
                recordingsFolderHasAudio = count > 0
            }
        }
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

    /// Punctuation modes offered for the active engine. Spoken Only is Whisper-only
    /// (see SettingsViewModel.availablePunctuationModes for why).
    private var availablePunctuationModes: [PunctuationMode] {
        SettingsViewModel.availablePunctuationModes(engine: viewModel.engine)
    }

    /// Selection binding for the punctuation picker.
    ///
    /// On Parakeet the picker omits Spoken Only. A config saved on Whisper as .spoken and then
    /// switched to Parakeet would leave the Picker with a selection (.spoken) that matches no tag,
    /// blanking it. So on READ we coalesce .spoken → .hybrid on Parakeet purely for display — the
    /// two are behaviorally identical there. We deliberately do NOT persist that coalescing: the
    /// stored .spoken is untouched, so switching back to Whisper restores the user's Spoken Only.
    private var punctuationSelection: Binding<PunctuationMode> {
        Binding(
            get: {
                if viewModel.engine == "parakeet" && viewModel.punctuationMode == .spoken {
                    return .hybrid
                }
                return viewModel.punctuationMode
            },
            set: { viewModel.punctuationMode = $0 }
        )
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

    /// Are recordings actually being written right now? On a developer machine
    /// (~/.speakfree-dev) they are, whatever the checkbox says — see the checkbox comment
    /// below. Anything that reveals or manages stored recordings must key off this, not the
    /// raw config value, or the UI describes a state the app is not in.
    private var recordingsEffectivelySaving: Bool {
        DevMode.isActive || viewModel.saveRecordings
    }

    /// Shown when the chosen hotkey costs the user the macOS Globe-key action. One click
    /// moves the hotkey to Right Option, which has no system action of its own.
    private var globeKeyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            // No leading glyph: the notice text already carries a 🌐 where it names the key,
            // and two globes in one banner read as a rendering bug.
            VStack(alignment: .leading, spacing: 1) {
                Text(HotkeyAdvice.globeKeyNotice)
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(HotkeyAdvice.globeKeyFixLabel) {
                    // Write the view model DIRECTLY rather than relying on the picker-selection
                    // delta. Persistence hangs off `.onChange(of: hotkeyPickerSelection)`, which
                    // is equality-gated, and nothing re-syncs that @State when the view model
                    // changes underneath it (refreshFromDisk does not touch it). So if the
                    // picker already held Right Option — config changed by the CLI, or a
                    // refreshFromDisk while the window stayed open — the click was a silent
                    // no-op with the banner still showing (2026-07-26 adversarial review).
                    viewModel.hotkeyKeyCode = HotkeyAdvice.globeKeyFixKeyCode
                    viewModel.hotkeyModifiers = []
                    viewModel.save()
                    hotkeyPickerSelection = HotkeyAdvice.globeKeyFixKeyCode
                }
                .buttonStyle(.link)
                .font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow.opacity(0.45), lineWidth: 1)
        )
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                // Keystrokes lead — they are COUNTED, not modelled (Michael 2026-07-26: report
                // hands saved as the headline, time honest-ranged). Saved time is an estimate
                // bracketed across typing speeds and now reads as a range so it stops implying
                // a precision it never had.
                Text("\(UsageStats.shared.totalDictations) dictations, \(UsageStats.shared.keystrokesDescription) keystrokes avoided (roughly \(UsageStats.shared.timeSavedDescription) of typing)")
                    .font(.callout)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                // -- GENERAL -----------------------------------------------
                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 14) {
                        if HotkeyAdvice.suppressesGlobeKeyAction(keyCode: viewModel.hotkeyKeyCode,
                                                                 toggleMode: viewModel.toggleMode) {
                            globeKeyBanner
                        }

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
                                Text("Microphone")
                                VStack(alignment: .leading, spacing: 2) {
                                    Picker("", selection: $micSelection) {
                                        Text(micDefaultLabel).tag("")
                                        ForEach(micDevices.filter { $0.uid != micBuiltInUID },
                                                id: \.uid) { device in
                                            Text(device.name).tag(device.uid)
                                        }
                                        // A pinned device that is currently unplugged still needs
                                        // a matching tag or the Picker renders blank (same hazard
                                        // as the language picker, see reconcilePickerLanguage).
                                        // Keeping the entry also keeps the pin: coercing the
                                        // selection to default would silently clear it.
                                        if !micSelection.isEmpty,
                                           !micDevices.contains(where: { $0.uid == micSelection }) {
                                            Text("Pinned device (disconnected)").tag(micSelection)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(maxWidth: 280, alignment: .leading)
                                    .onChange(of: micSelection) { newValue in
                                        (NSApplication.shared.delegate as? AppDelegate)?
                                            .selectInputDevice(uid: newValue.isEmpty ? nil : newValue)
                                    }
                                    Text("The built-in mic transcribes most reliably. Bluetooth "
                                         + "mics (AirPods) degrade quality unpredictably, and "
                                         + "virtual devices (Zoom, Splashtop) can record silence.")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            GridRow {
                                Text("Recordings")
                                // The checkbox used to bind the RAW config value while
                                // DevMode.effectiveSaveRecordings forced saving ON, so on a
                                // developer machine it read "off" while recordings were in fact
                                // being written (2026-07-26 — Michael ticked it and nothing
                                // changed, because nothing needed to). Same class of dishonesty
                                // as an untagged test build: show the state the app is actually
                                // in, and say who is holding it there.
                                VStack(alignment: .leading, spacing: 2) {
                                    Toggle("Save recordings and transcripts",
                                           isOn: DevMode.isActive
                                               ? .constant(true)
                                               : $viewModel.saveRecordings)
                                        .disabled(DevMode.isActive)
                                        .onChange(of: viewModel.saveRecordings) { _ in
                                            viewModel.save()
                                            refreshRecordingsFolderState()
                                        }
                                    if DevMode.isActive {
                                        Text("Forced on by developer mode "
                                             + "(~/\(DevMode.markerName) exists). Delete that "
                                             + "file to control this yourself.")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }

                            if recordingsEffectivelySaving {
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

                        Button("Open Recordings / Transcripts Folder…") {
                            NSWorkspace.shared.activateFileViewerSelecting([RecordingStore.recordingsDir])
                        }
                        .controlSize(.small)
                        .disabled(!recordingsFolderHasAudio)

                        if storedRecordingCount > 0 {
                            HStack(spacing: 4) {
                                Text("You have \(storedRecordingCount) recordings and their "
                                     + "transcripts stored on your computer.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Button("Click here to delete") { showDeleteRecordingsSheet = true }
                                    .buttonStyle(.link)
                                    .font(.footnote)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .onAppear { refreshRecordingsFolderState() }
                    .sheet(isPresented: $showDeleteRecordingsSheet) {
                        DeleteRecordingsConfirmView(
                            fileCount: RecordingStore.recordingFileCount(),
                            folderPath: RecordingStore.recordingsDir.path,
                            onDeleted: { refreshRecordingsFolderState() }
                        )
                    }
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
                                                // Grey the row for models not on disk. macOS
                                                // menu pickers honor foregroundColor on the
                                                // dropdown rows; the "(Not Downloaded)" label
                                                // suffix carries the state where they don't.
                                                .foregroundColor(model.isDownloaded ? .primary : .secondary)
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
                                Picker("", selection: punctuationSelection) {
                                    // Spoken Only is omitted on Parakeet (Whisper-only).
                                    ForEach(availablePunctuationModes, id: \.self) { mode in
                                        Text(SettingsViewModel.punctuationModeLabel(mode)).tag(mode)
                                    }
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
            refreshMicState()
            checkPendingDownload()
        }
        .onChange(of: hotkeyPickerSelection) { newValue in
            if newValue == otherHotkeyTag {
                isRecordingHotkey = true
            } else if newValue != viewModel.hotkeyKeyCode {
                // Clearing the modifiers is correct ONLY for a real user pick of a different key.
                // The equality guard distinguishes that from the two SYNC writes that also land
                // here, both of which used to destroy a modifier-bearing hotkey (2026-08-01):
                //   1. `.onAppear` assigns `hotkeyPickerSelection = viewModel.hotkeyKeyCode`,
                //      which counts as a change — so merely OPENING Settings wiped modifiers.
                //   2. `KeyRecorderOverlay.onCapture` sets keyCode + modifiers and then syncs the
                //      picker, so capturing e.g. Shift+F13 immediately cleared the Shift again.
                // Modifier-bearing hotkeys are reachable only via config file / CLI / the "Other…"
                // recorder, which is why this survived: the GUI picker itself never sets one.
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

}
