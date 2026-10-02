// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import SwiftUI

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    private var screenObserver: NSObjectProtocol?

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// P2: whether the Settings window is currently on-screen. External config writers
    /// (recordings notice, menu-bar mic selector) use this to know they must re-sync the
    /// cached view model from disk so its next save can't overlay a stale snapshot.
    static var isWindowVisible: Bool {
        shared?.window?.isVisible == true
    }

    static func show(viewModel: SettingsViewModel) {
        let openStart = CFAbsoluteTimeGetCurrent()
        defer {
            // The maintainer 2026-08-20: "going to the settings menu now has a solid pause."
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
        shared?.fitWindowToVisibleScreen()
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

        hostingController.preferredContentSize = NSSize(width: SettingsSidebarLayout.windowWidth, height: windowHeight)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "speakfree Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: SettingsSidebarLayout.windowWidth, height: windowHeight))
        window.minSize = NSSize(width: SettingsSidebarLayout.minimumWindowWidth, height: 500)
        window.maxSize = NSSize(width: 1000, height: screenHeight)
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        fitWindowToVisibleScreen()
        // constrainFrameRect returns a proposed frame; it does not move the window.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.fitWindowToVisibleScreen() }
    }

    private func fitWindowToVisibleScreen() {
        guard let window,
              let visibleFrame = WindowScreenPlacement.screen(for: window.frame,
                                                               visibleFrames: NSScreen.screens.map(\.visibleFrame)) else { return }
        window.minSize = NSSize(width: min(SettingsSidebarLayout.minimumWindowWidth, visibleFrame.width), height: min(500, visibleFrame.height))
        window.maxSize = NSSize(width: min(1000, visibleFrame.width), height: visibleFrame.height)
        window.setFrame(WindowScreenPlacement.fit(window.frame, to: visibleFrame), display: false)
    }
}

/// Shared by the resizable Settings and Edit windows. A sliver intersecting a display is not
/// enough: keep the title bar reachable after a display is unplugged or resized.
enum WindowScreenPlacement {
    static func screen(for frame: NSRect, visibleFrames: [NSRect]) -> NSRect? {
        var best = visibleFrames.first
        var largestArea: CGFloat = 0
        for candidate in visibleFrames {
            let overlap = frame.intersection(candidate)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestArea { best = candidate; largestArea = area }
        }
        return best
    }

    static func fit(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, visibleFrame.width),
                          height: min(frame.height, visibleFrame.height))
        return NSRect(x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
                      y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height),
                      width: size.width, height: size.height)
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

/// Presentation values are distinct from hardware key codes. A configured modifier chord can
/// use a standard key without sharing the same picker tag as that key's unmodified option.
enum SettingsHotkeyChoice: Hashable {
    case standard(UInt16), custom, other

    static func current(keyCode: UInt16, modifiers: [String]) -> Self {
        modifiers.isEmpty && standardHotkeyOptions.contains(where: { $0.keyCode == keyCode })
            ? .standard(keyCode) : .custom
    }
}

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
        // The maintainer 2026-08-19: un-downloaded models must be visibly different in the
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

// MARK: - Key Recorder Monitor

/// The recorder waits until a modifier is released before choosing it by itself. Committing on
/// its press made the first Command/Option key swallow every attempted multi-key shortcut.
struct SettingsKeyRecorderState {
    enum Action: Equatable {
        case ignore, cancel, capture(UInt16, [String])
    }

    private var loneModifier: UInt16?
    private var modifierChordInProgress = false
    private static let flagsByKey: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command, 56: .shift, 60: .shift,
        58: .option, 61: .option, 59: .control, 62: .control, 63: .function,
    ]
    private static let relevantFlags: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]

    mutating func receive(type: NSEvent.EventType, keyCode: UInt16,
                          flags: NSEvent.ModifierFlags) -> Action {
        if type == .flagsChanged {
            guard let flag = Self.flagsByKey[keyCode] else { return .ignore }
            let held = flags.intersection(Self.relevantFlags)
            if flags.contains(flag) {
                if held == flag, !modifierChordInProgress, loneModifier == nil {
                    loneModifier = keyCode
                } else {
                    loneModifier = nil
                    modifierChordInProgress = true
                }
                return .ignore
            }
            let shouldCapture = loneModifier == keyCode && held.isEmpty && !modifierChordInProgress
            loneModifier = nil
            if held.isEmpty { modifierChordInProgress = false }
            return shouldCapture ? .capture(keyCode, []) : .ignore
        }
        guard type == .keyDown else { return .ignore }
        loneModifier = nil
        modifierChordInProgress = !flags.intersection(Self.relevantFlags).isEmpty
        if keyCode == 53 { return .cancel }
        var modifiers: [String] = []
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.control) { modifiers.append("ctrl") }
        return .capture(keyCode, modifiers)
    }
}

/// Holds the NSEvent monitor reference so it can be cleaned up reliably.
final class KeyMonitorHolder: ObservableObject {
    typealias EventHandler = (NSEvent) -> NSEvent?
    private let recordingGate: ShortcutRecordingGate
    private let notificationCenter: NotificationCenter
    private let installMonitor: (@escaping EventHandler) -> Any?
    private let removeMonitor: (Any) -> Void
    var monitor: Any?
    private var state = SettingsKeyRecorderState()
    private var recordingLease: UUID?
    private var capturedKey: UInt16?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(recordingGate: ShortcutRecordingGate = .shared, notificationCenter: NotificationCenter = .default,
         installMonitor: @escaping (@escaping EventHandler) -> Any? = { handler in
             NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: handler)
         }, removeMonitor: @escaping (Any) -> Void = NSEvent.removeMonitor) {
        self.recordingGate = recordingGate
        self.notificationCenter = notificationCenter
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
    }

    func install(onCapture: @escaping (UInt16, [String]) -> Void, onCancel: @escaping () -> Void) {
        remove()
        state = SettingsKeyRecorderState()
        capturedKey = nil
        recordingLease = recordingGate.begin()
        // A retained Settings host can disappear without SwiftUI immediately destroying its
        // overlay. Closing a window or switching apps always cancels and restores the hotkeys.
        for name in [NSWindow.willCloseNotification, NSApplication.didResignActiveNotification] {
            lifecycleObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard self?.monitor != nil else { return }
                self?.remove()
                onCancel()
            })
        }
        monitor = installMonitor { [weak self] event in
            guard let self else { return event }
            guard event.type != .keyDown || !event.isARepeat else { return nil }
            switch self.state.receive(type: event.type, keyCode: event.keyCode, flags: event.modifierFlags) {
            case .ignore: break
            case .cancel: onCancel()
            case .capture(let code, let modifiers):
                self.capturedKey = event.type == .keyDown ? code : nil
                onCapture(code, modifiers)
            }
            return nil
        }
        if monitor == nil {
            remove()
            onCancel()
        }
    }

    func remove() {
        if let m = monitor {
            removeMonitor(m)
            monitor = nil
        }
        lifecycleObservers.forEach(notificationCenter.removeObserver)
        lifecycleObservers.removeAll()
        if let recordingLease {
            self.recordingLease = nil
            recordingGate.finish(recordingLease, afterKeyRelease: capturedKey)
        }
        capturedKey = nil
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

struct KeyRecorderOverlay: View {
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
                Text("For a single modifier, press and release it.")
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

struct DictationSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// Rendering fixtures never touch login items, mic routing, or the user's corpus.
    var isReview = false
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
    @State private var hotkeyPickerSelection: SettingsHotkeyChoice = .standard(KeyCodes.fnKeyCode)
    /// Gates the "Open Recordings / Transcripts Folder" button (enabled only when audio
    /// files exist) and feeds the stored-count line. Refreshed on appear, on toggle
    /// flips, and after an in-app delete.
    @State private var recordingsFolderHasAudio = false
    @State private var storedRecordingCount = 0
    @State private var pendingRecordingsRecovery: URL?
    @State private var isRestoringRecordings = false
    @State private var recordingsRestoreError: String?
    /// Hand-travel units: false = miles (default), true = kilometers. Click the stats line
    /// to flip (the maintainer 2026-08-20).
    @State private var statsMetricUnits = false
    /// The key mode before the latest change, so cancelling the Edit Mode consent can go back.
    @State private var lastKeyMode: KeyMode = .hold

    private var editModeFootnote: String {
        if !viewModel.editModeCleanup {
            return "On-device only: nothing leaves this Mac."
        }
        return "Only each paragraph's text is sent to Claude, using your Claude account. Never audio, screen contents, or the app name."
    }

    private func showEditModeHelp() {
        let alert = NSAlert()
        alert.messageText = "Edit Mode"
        alert.informativeText = """
        Tap \(hotkeyDisplay) to open a small window and record. Tap it again to end the paragraph; its text \
        appears at once. More taps add more paragraphs. Type anywhere to fix things. Return \
        inserts everything where you started; Shift+Return adds a line break; Esc twice discards.

        \(EditConsentSheet.explanation)

        If the window says the Claude command line tool is missing, install Claude Code, or set \
        "claudeExecutablePath" in the config file to its full path.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    @State private var showDeleteRecordingsSheet = false

    /// Empty selection means automatic live routing with independent pre-listening.
    /// Any device UID is an explicit live microphone choice.
    /// Snapshot of the device list is taken on appear — cache-only reads, same rule as the
    /// menu (live CoreAudio reads on main wedged the app on 2026-07-15).
    @State private var micSelection: String = ""
    @State private var micDevices: [AudioInputDevice] = []

    private var micBuiltInUID: String? { AudioDeviceCatalog.cachedBuiltInInput?.uid }

    private var micDefaultLabel: String { "Automatic (this Mac's microphone)" }

    private func refreshMicState() {
        micDevices = AudioDeviceCatalog.cachedInputDevices
        let pinned = (NSApplication.shared.delegate as? AppDelegate)?.currentInputDeviceUID()
        // Keep an explicit built-in choice distinct from automatic routing.
        micSelection = pinned ?? ""
    }

    private func refreshRecordingsFolderState() {
        if isReview {
            storedRecordingCount = 12_000
            recordingsFolderHasAudio = true
            return
        }
        // M2 + 2026-08-20: the count cache is COLD on the first Settings open each launch,
        // and cachedRecordingCount() then live-scans the recordings dir on the CALLING
        // thread — ~250ms over today's 61k files, on main, inside the window's first
        // render (the maintainer: "going to the settings menu now has a solid pause"). Hop the
        // read to a background queue; warm-cache refreshes still come back instantly.
        DispatchQueue.global(qos: .userInitiated).async {
            let count = RecordingStore.cachedRecordingCount()
            let recovery = RecordingRemoval.pendingRecoveryDirectory(in: RecordingStore.recordingsDir)
            DispatchQueue.main.async {
                pendingRecordingsRecovery = recovery
                storedRecordingCount = count
                recordingsFolderHasAudio = count > 0
            }
        }
    }

    private func restoreRecordings(from recovery: URL) {
        guard !isRestoringRecordings else { return }
        isRestoringRecordings = true
        recordingsRestoreError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = RecordingRemoval.restoreBatch(recovery, to: RecordingStore.recordingsDir)
            RecordingStore.invalidateCachedCount()
            DispatchQueue.main.async {
                NSWorkspace.shared.noteFileSystemChanged(RecordingStore.recordingsDir.path)
                isRestoringRecordings = false
                recordingsRestoreError = outcome.succeeded ? nil :
                    "Some files could not be restored. They remain safe in the recovery folder; resolve any name conflicts or permissions issue and try again."
                refreshRecordingsFolderState()
            }
        }
    }

    /// Consistent label width across ALL Grid sections.
    private let labelWidth = SettingsLayout.labelWidth

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
    private var currentHotkeyChoice: SettingsHotkeyChoice {
        .current(keyCode: viewModel.hotkeyKeyCode, modifiers: viewModel.hotkeyModifiers)
    }

    private var isCustomHotkey: Bool { currentHotkeyChoice == .custom }

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

    private var keepRecordingsSelection: Binding<Int> {
        Binding(
            get: { viewModel.saveRecordings ? viewModel.maxRecordings : -1 },
            set: { value in
                viewModel.selectRecordingRetention(value)
                refreshRecordingsFolderState()
            }
        )
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
                    hotkeyPickerSelection = .standard(HotkeyAdvice.globeKeyFixKeyCode)
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
                VStack(alignment: .leading, spacing: 24) {
                Text("Dictation")
                    .font(.title2.weight(.semibold))
                if let error = viewModel.saveError {
                    Text(error).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Two-line format (the maintainer 2026-08-20). Line 1 = counted facts (dictations,
                // words, time spoken). Line 2 = savings: keystrokes are COUNTED; time keeps
                // the honest range across typing speeds (2026-07-26 ruling); hand-travel
                // distance uses a stated 2 cm/keystroke assumption. Clicking the stats
                // flips the distance between miles and kilometers.
                VStack(spacing: 6) {
                    Text(isReview ? "Total: 1,200 dictations, 48,000 words, 5h 20m" :
                         "Total: \(UsageStats.shared.totalDictations.formatted()) dictations, "
                         + "\(UsageStats.shared.totalWords.formatted()) words, "
                         + "\(UsageStats.formatDaysHoursMinutes(UsageStats.shared.totalAudioSeconds))")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(isReview ? "You would have typed: 240,000 keystrokes, 3.0 miles, and 13h" :
                         "You would have typed: \(UsageStats.shared.keystrokesDescription) keystrokes, "
                         + (statsMetricUnits ? UsageStats.shared.handTravelMetricDescription
                                             : UsageStats.shared.handTravelImperialDescription)
                         + ", and \(UsageStats.formatDaysHours(UsageStats.shared.estimatedTypingTime))")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture { statsMetricUnits.toggle() }
                .help("Click to switch between miles and kilometers")
                // -- GENERAL -----------------------------------------------
                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 14) {
                        // The Globe-key suppression is noticeable on any TAP-driven mode (Toggle and
                        // Edit both tap fn), where macOS would otherwise fire the emoji drawer — not
                        // in Hold. See HotkeyAdvice.
                        if HotkeyAdvice.suppressesGlobeKeyAction(keyCode: viewModel.hotkeyKeyCode,
                                                                 toggleMode: viewModel.keyMode != .hold) {
                            globeKeyBanner
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Launch at Login").frame(width: labelWidth, alignment: .leading)
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .onChange(of: launchAtLogin) { newValue in
                                guard !isReview else { return }
                                LaunchAtLogin.isEnabled = newValue
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    launchAtLogin = LaunchAtLogin.isEnabled
                                }
                            }
                        }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow(alignment: .firstTextBaseline) {
                                Text("Hotkey").frame(width: labelWidth, alignment: .leading).gridColumnAlignment(.leading)
                                HStack(spacing: 8) {
                                    Picker("Hotkey", selection: $hotkeyPickerSelection) {
                                        if isCustomHotkey {
                                            Text(hotkeyDisplay).tag(SettingsHotkeyChoice.custom)
                                            Divider()
                                        }
                                        ForEach(standardHotkeyOptions) { option in
                                            Text(option.label).tag(SettingsHotkeyChoice.standard(option.keyCode))
                                        }
                                        Divider()
                                        Text("Other\u{2026}").tag(SettingsHotkeyChoice.other)
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()

                                    Picker("Hotkey behavior", selection: $viewModel.keyMode) {
                                        Text("Hold").tag(KeyMode.hold)
                                        Text("Toggle").tag(KeyMode.toggle)
                                        Text("Edit").tag(KeyMode.edit)
                                    }
                                    .pickerStyle(.segmented)
                                    .controlSize(.regular)
                                    .labelsHidden()
                                    .frame(width: 200)
                                    .help("Hold: talk while holding. Toggle: tap to start and stop. Edit: tap opens a window where each dictation becomes a paragraph you can fix before Return inserts it.")
                                }
                            }

                            if viewModel.keyMode == .edit {
                                GridRow(alignment: .firstTextBaseline) {
                                    Text("Edit Mode")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Toggle("Clean up with Claude (cloud)", isOn: $viewModel.editModeCleanup)
                                            .toggleStyle(.checkbox)
                                        HStack(spacing: 10) {
                                            Picker("Model", selection: $viewModel.editModeModel) {
                                                ForEach(CleanupService.Model.allCases, id: \.self) { m in
                                                    Text(m.displayName).tag(m)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 100)
                                            .disabled(!viewModel.editModeCleanup)
                                            Button("How it works") { showEditModeHelp() }
                                                .buttonStyle(.link)
                                        }
                                        Text(editModeFootnote)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }

                            GridRow(alignment: .firstTextBaseline) {
                                Text("Microphone")
                                VStack(alignment: .leading, spacing: 2) {
                                    Picker("Microphone", selection: $micSelection) {
                                        Text(micDefaultLabel).tag("")
                                        ForEach(micDevices,
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
                                    .frame(maxWidth: 360, alignment: .leading)
                                    .onChange(of: micSelection) { newValue in
                                        // onAppear's refreshMicState writes the current pin here too;
                                        // re-saving the same pin is not a choice and must not end Stay on.
                                        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
                                              StayOnController.isNewSelection(newValue, current: delegate.currentInputDeviceUID())
                                        else { return }
                                        delegate.selectInputDevice(uid: newValue.isEmpty ? nil : newValue)
                                    }
                                    Text(micSelection.isEmpty
                                         ? "Uses this Mac's built-in mic, or a wired mic if it has none.\nAirPods and other Bluetooth headsets are used only when you choose Stay on in the menu."
                                         : "Uses your selected microphone for dictation. If disconnected, a built-in or wired mic is used.")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            GridRow(alignment: .firstTextBaseline) {
                                Text(RecordingRetention.label)
                                    .frame(width: labelWidth, alignment: .leading)
                                    .gridColumnAlignment(.leading)
                                VStack(alignment: .leading, spacing: 8) {
                                    RecordingRetentionPicker(selection: keepRecordingsSelection,
                                                             developerMode: DevMode.isActive)
                                    if DevMode.isActive {
                                        Text("Keep All is enforced by developer mode (~/\(DevMode.markerName) exists).")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(RecordingRetention.explanation(keepRecordingsSelection.wrappedValue))
                                            .font(.footnote).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    RecordingsFolderButton(folderPath: RecordingStore.recordingsDir.path)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let recovery = pendingRecordingsRecovery {
                            Text("A previous move to Trash did not finish. Your files are safe in a recovery folder.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(isRestoringRecordings ? "Restoring…" : "Restore Recordings") {
                                restoreRecordings(from: recovery)
                            }
                            .disabled(isRestoringRecordings)
                            .help("Return recoverable recordings to their original folder without overwriting newer files")
                            if let recordingsRestoreError {
                                Text(recordingsRestoreError).font(.footnote).foregroundStyle(.red)
                            }
                        }
                        if storedRecordingCount > 0 {
                            VStack(alignment: .center, spacing: 4) {
                                Text("Your corpus: \(storedRecordingCount.formatted()) recordings and "
                                     + "transcripts, stored only on this Mac.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Button(NoticeCopy.deleteLinkText) { showDeleteRecordingsSheet = true }
                                    .help("Move recordings and transcripts to Trash")
                                    .accessibilityLabel("Move recordings and transcripts to Trash")
                                    .buttonStyle(.link)
                                    .font(.footnote)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .onAppear { refreshRecordingsFolderState() }
                    .sheet(isPresented: $showDeleteRecordingsSheet) {
                        RecordingsTrashConfirmView(
                            fileCount: RecordingStore.recordingCount(),
                            folderPath: RecordingStore.recordingsDir.path,
                            onDeleted: { refreshRecordingsFolderState() },
                            onRestored: { refreshRecordingsFolderState() }
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
                            GridRow(alignment: .firstTextBaseline) {
                                Text("Language").frame(width: labelWidth, alignment: .leading).gridColumnAlignment(.leading)
                                Picker("Language", selection: $viewModel.language) {
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
                                GridRow(alignment: .firstTextBaseline) {
                                    Text("Model")
                                    Picker("Model", selection: $viewModel.modelSize) {
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

                            GridRow(alignment: .firstTextBaseline) {
                                Text("Punctuation").frame(width: labelWidth, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Picker("Punctuation", selection: punctuationSelection) {
                                        ForEach(availablePunctuationModes, id: \.self) { mode in
                                            Text(SettingsViewModel.punctuationModeLabel(mode)).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    Text("Choose automatic punctuation, spoken commands like ‘comma’, or both.")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                            }

                            GridRow(alignment: .firstTextBaseline) {
                                Text("Vocabulary")
                                    .frame(width: labelWidth, alignment: .leading)
                                vocabularyStatusRow
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.engine == "whisper" {
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

                        if viewModel.engine == "parakeet" {
                            whisperFallbackRow
                        }

                        if viewModel.engine == "whisper" {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow(alignment: .firstTextBaseline) {
                                Text("Model Loading").frame(width: labelWidth, alignment: .leading).gridColumnAlignment(.leading)
                                Picker("Model Loading", selection: $viewModel.keepModelLoaded) {
                                    Text("Automatic").tag("auto")
                                    Text("Always Loaded").tag("always")
                                    if viewModel.keepModelLoaded == "off" {
                                        Text("Automatic (legacy Off)").tag("off")
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(width: 220, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Estimated loading time: \(SettingsViewModel.modelLoadTimeDescription(viewModel.modelSize)).")
                            Text("Keeping it loaded uses \(SettingsViewModel.modelMemoryDescription(viewModel.modelSize)).")
                            Text("Automatic unloads the model whenever your Mac needs the memory.")
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, labelWidth + 12)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // -- ADVANCED ----------------------------------------------
                GroupBox("Advanced") {
                    VStack(alignment: .leading, spacing: 14) {
                        checkboxRow("Diagnostic Logging", selection: $viewModel.diagnosticLogging,
                                    detail: "Logs session activity locally to help diagnose issues.")
                                .onChange(of: viewModel.diagnosticLogging) { newValue in
                                    viewModel.save()
                                    DiagnosticLogger.shared.setEnabled(newValue)
                                }
                            Button("Open Logs Folder\u{2026}") {
                                let logsDir = Config.configDir.appendingPathComponent("logs")
                                try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(logsDir)
                            }
                            .controlSize(.regular)
                            .padding(.leading, labelWidth + 12)

                        if viewModel.engine == "whisper" {
                        checkboxRow("Live Preview", selection: $viewModel.streamingEnabled,
                                    detail: "Experimental: shows text as you speak. Text may flicker.")
                                .onChange(of: viewModel.streamingEnabled) { _ in viewModel.save() }
                        }

                        localAPIRow

                        screenContextRow

                        insertionByAppRow

                        compatibilityReportRow

                        dictationTraceRow
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }

                if viewModel.engine == "parakeet" {
                    Text("Speech recognition by NVIDIA Parakeet (CC-BY-4.0) via FluidAudio (Apache-2.0).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Footer — scrolls with content, not pinned
                Divider()
                    .padding(.top, 8)
                HStack(spacing: 0) {
                    Text("Proudly vibe coded. ")
                        .foregroundColor(.secondary)
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/definitelyreal/speakfree")!)
                    } label: {
                        Text("Let's improve it together →")
                            .foregroundColor(Color(red: 0.6, green: 0.2, blue: 0.8))
                            .underline(isHoveringGitHub)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringGitHub = $0 }
                    Spacer()
                }
                .padding(.vertical, 12)
                } // end VStack
                .padding(24)
            } // end ScrollView
            .scrollContentBackground(.hidden)

            if isRecordingHotkey {
                KeyRecorderOverlay(
                    onCapture: { keyCode, modifiers in
                        viewModel.hotkeyKeyCode = keyCode
                        viewModel.hotkeyModifiers = modifiers
                        hotkeyPickerSelection = currentHotkeyChoice
                        viewModel.save()
                        isRecordingHotkey = false
                    },
                    onCancel: {
                        hotkeyPickerSelection = currentHotkeyChoice
                        isRecordingHotkey = false
                    }
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .controlSize(.regular)
        .onAppear {
            hotkeyPickerSelection = currentHotkeyChoice
            lastKeyMode = viewModel.keyMode
            if !isReview { launchAtLogin = LaunchAtLogin.isEnabled }
            previousLanguage = viewModel.language
            if !isReview { refreshMicState() }
            checkPendingDownload()
        }
        .onChange(of: hotkeyPickerSelection) { newValue in
            switch newValue {
            case .other:
                isRecordingHotkey = true
            case .custom:
                break // Syncing the custom label never changes its configured chord.
            case .standard(let code):
                guard code != viewModel.hotkeyKeyCode || !viewModel.hotkeyModifiers.isEmpty else { return }
                viewModel.hotkeyKeyCode = code
                viewModel.hotkeyModifiers = []
                viewModel.save()
            }
        }
        .onChange(of: viewModel.keyMode) { newMode in
            // First switch to Edit with cleanup on and no consent yet: explain the cloud part
            // first, with an on-device-only way in. Cancel keeps the old mode.
            if newMode == .edit, !isReview, viewModel.editModeCleanup,
               viewModel.editModeCloudConsent == nil {
                switch EditConsentSheet.run(in: nil, offerOnDeviceOnly: true) {
                case .allow:
                    viewModel.editModeCloudConsent = ISO8601DateFormatter().string(from: Date())
                case .onDeviceOnly:
                    viewModel.editModeCleanup = false
                case .cancel:
                    viewModel.keyMode = lastKeyMode
                    return
                }
            }
            lastKeyMode = newMode
            viewModel.save()
        }
        .onChange(of: viewModel.editModeCleanup) { on in
            if on, !isReview, viewModel.editModeCloudConsent == nil {
                if EditConsentSheet.run(in: nil) == .allow {
                    viewModel.editModeCloudConsent = ISO8601DateFormatter().string(from: Date())
                } else {
                    viewModel.editModeCleanup = false
                    return
                }
            }
            viewModel.save()
        }
        .onChange(of: viewModel.editModeModel) { _ in viewModel.save() }
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
                        .controlSize(.regular)
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
        checkboxRow("Local Transcription API", selection: $viewModel.localAPIEnabled,
                    detail: "Experimental: lets other apps on this Mac request transcription.\nPOST http://localhost:\(viewModel.localAPIPort)/v1/audio/transcriptions")
                .onChange(of: viewModel.localAPIEnabled) { _ in viewModel.save() }
    }

    // MARK: - App compatibility rows (2026-09-24)

    /// A running app someone might want to set an insertion method for.
    private struct RunningAppChoice: Identifiable {
        let id: String      // bundle ID
        let name: String
    }

    /// Regular (Dock) apps that are running now, alphabetically, excluding speakfree itself.
    /// A stranger fixing an app has it open, so this list is enough; config.json takes any ID.
    private var runningAppChoices: [RunningAppChoice] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppChoice? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id.lowercased()).inserted else { return nil }
                return RunningAppChoice(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func appDisplayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private static func detectedClass(for bundleID: String) -> AppClass {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return AppCompatibility.classify(bundleID: bundleID, bundleURL: url).appClass
    }

    /// "Detected: <class>", plus the Report a Problem confirmation while the saved setting is
    /// still the one that was confirmed.
    private func insertionCaption(for bundleID: String) -> String {
        let detected = "Detected: \(Self.detectedClass(for: bundleID).label)"
        let lower = bundleID.lowercased()
        guard let entry = viewModel.insertionConfirmations.first(where: { $0.key.lowercased() == lower })?.value,
              entry.setting == viewModel.insertionOverrides[bundleID]?.rawValue,
              let method = InsertionMethod(rawValue: entry.method) else { return detected }
        return detected + " · you marked \(method.label) as working"
    }

    private func overrideBinding(for bundleID: String) -> Binding<InsertionMethod> {
        Binding(
            get: { viewModel.insertionOverrides[bundleID] ?? .automatic },
            set: { viewModel.setInsertionOverride($0, for: bundleID) })
    }

    private var insertionByAppRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Insertion by App").frame(width: labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.insertionOverrides.keys.sorted(), id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.appDisplayName(for: bundleID)).lineLimit(1)
                            Text(insertionCaption(for: bundleID))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Picker("Method", selection: overrideBinding(for: bundleID)) {
                            ForEach(InsertionMethod.allCases) { method in
                                Text(method == .automatic ? "Automatic (remove)" : method.label).tag(method)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .help(viewModel.insertionOverrides[bundleID]?.detail ?? "")
                    }
                }
                Menu("Add App\u{2026}") {
                    ForEach(runningAppChoices) { app in
                        Menu(app.name) {
                            ForEach(InsertionMethod.allCases.filter { $0 != .automatic }) { method in
                                Button(method.label) {
                                    viewModel.setInsertionOverride(method, for: app.id)
                                }
                            }
                        }
                    }
                }
                .fixedSize()
                Text("If dictation doesn't land in an app, choose a method for that app, or use Report a Problem in the menu bar while that app is in front. Type sends keystrokes, Paste uses the clipboard, Accessibility writes into the field directly. Every other app keeps automatic detection.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @State private var reportCopied = false

    private var compatibilityReportRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            checkboxRow("Compatibility Report", selection: $viewModel.compatibilityReportEnabled,
                        detail: "Keeps a list in memory of which method each app got and whether the text landed, for bug reports. It never includes what you said, and nothing is sent anywhere.")
                .onChange(of: viewModel.compatibilityReportEnabled) { _ in viewModel.save() }
            HStack(spacing: 8) {
                Button("Copy Report") {
                    let report = CompatibilityReport.render(
                        events: CompatibilityReport.shared.snapshot,
                        speakfreeVersion: SpeakFree.version,
                        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString)
                    UserPasteRestoreGate.shared.writeOutsideBorrow {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    reportCopied = true
                }
                .disabled(!viewModel.compatibilityReportEnabled)
                if reportCopied {
                    Text("Copied").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, labelWidth + 12)
        }
    }

    // MARK: - Screen Context Row

    private var screenContextRow: some View {
        checkboxRow("Screen Context", selection: $viewModel.screenContext,
                    detail: viewModel.engine == "parakeet"
                        ? "Experimental: uses local on-screen text to help correct names and spelling. May make incorrect substitutions."
                        : "Experimental: uses local on-screen text as vocabulary hints. Whisper may insert words from the screen that you didn’t say.")
                .onChange(of: viewModel.screenContext) { newValue in
                    viewModel.save()
                    if newValue && !ScreenContext.hasPermission {
                        _ = ScreenContext.requestPermission()
                    }
                }
    }

    // MARK: - Dictation Trace Row

    private var dictationTraceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Dictation Trace").frame(width: labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Picker("Dictation Trace", selection: $viewModel.dictationTrace) {
                    Text("Off").tag("off")
                    Text("Invisible tags").tag("tags")
                    Text("Invisible dot selectors").tag("selectors")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: viewModel.dictationTrace) { _ in viewModel.save() }
                Text("Experimental: after each dictation into Claude, Codex, VS Code, Cursor, terminals, or Claude and ChatGPT in a browser, adds a dot carrying what the speech engine heard, so an AI can recover mis-heard words. Your raw words go wherever you dictate, including code files, commit messages, and shell commands in those apps; never added in chat or mail apps or password fields.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func checkboxRow(_ label: String, selection: Binding<Bool>, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Toggle(label, isOn: selection).labelsHidden().toggleStyle(.checkbox)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Vocabulary Status Row

    private var vocabularyStatusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
            let count = WordMemory.loadVocabularyEntries().count
            Button("📝 Edit Vocabulary File") {
                let url = Config.vocabularyFile
                let dir = Config.configDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    let template = "# Vocabulary for speakfree\n# One word or phrase per line.\n# Lines starting with # are ignored.\n"
                    try? template.write(to: url, atomically: true, encoding: .utf8)
                }
                NSWorkspace.shared.open(url)
            }
            Text("(\(count.formatted()) \(count == 1 ? "entry" : "entries"))")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Text("Add names and phrases, one per line, to improve recognition.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pre-Buffer Row

    /// The maintainer 2026-09-23: "Load Whisper as fallback for errors". Shown checked only when the
    /// fallback can actually run (model installed, or downloading), so a new user never sees a
    /// checked box with no backup behind it. Checking it without the model starts the 1.6 GB
    /// download (progress in the menu); unchecking cancels a download in flight.
    private var whisperFallbackRow: some View {
        let app = NSApp.delegate as? AppDelegate
        _ = viewModel.whisperFallbackDownloadGeneration  // redraw when the download changes state
        let installed = Transcriber.modelExists(modelSize: WhisperFallback.modelSize)
        let downloading = app?.isWhisperFallbackDownloading ?? false
        let binding = Binding<Bool>(
            get: { (viewModel.whisperFallbackSetting ?? true) && (installed || downloading) },
            set: { enabled in
                viewModel.whisperFallbackSetting = enabled
                viewModel.save()
                if enabled, !Transcriber.modelExists(modelSize: WhisperFallback.modelSize) {
                    app?.startWhisperFallbackDownload()
                } else if !enabled {
                    app?.cancelWhisperFallbackDownload()
                }
            })
        let detail = "If the speech model misses a dictation, re-check it with Whisper. "
            + (installed ? "Backup model installed."
               : downloading ? "Downloading the backup model (progress in the menu)."
               : "Turning this on downloads a \(WhisperFallback.downloadSizeDescription) backup model.")
        return checkboxRow("Load Whisper as fallback for errors", selection: binding, detail: detail)
    }

    private var preBufferRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Pre-listening").frame(width: labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
            Toggle("Pre-listening", isOn: $viewModel.preBuffer)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Text("Keeps the previous half-second of audio. The built-in microphone protects the beginning of your thought while AirPods connect.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
