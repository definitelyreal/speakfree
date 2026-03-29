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
        hostingController.preferredContentSize = NSSize(width: 440, height: 580)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "speakfree Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 440, height: 580))
        window.minSize = NSSize(width: 440, height: 580)
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

// MARK: - Model Helpers

private struct ModelInfo: Identifiable, Hashable {
    let id: String
    let memory: String
    let speed: String
    let isRecommended: Bool

    var label: String {
        var s = "\(id) \u{2014} \(memory), \(speed)"
        if isRecommended { s += " (Recommended)" }
        return s
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
        RawModel(enId: "tiny.en",   multiId: "tiny",   base: "tiny",   memory: "~230 MB", speed: "~0.6s"),
        RawModel(enId: "base.en",   multiId: "base",   base: "base",   memory: "~330 MB", speed: "~0.6s"),
        RawModel(enId: "small.en",  multiId: "small",  base: "small",  memory: "~800 MB", speed: "~0.6s"),
        RawModel(enId: "medium.en", multiId: "medium",  base: "medium", memory: "~2.1 GB", speed: "~1.3s"),
        RawModel(enId: "large-v3",  multiId: "large-v3", base: "large", memory: "~3.9 GB", speed: "~2.1s"),
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

// MARK: - Idle Timeout Options

private let idleTimeoutOptions: [(label: String, value: Int)] = [
    ("Always", 0),
    ("2 min", 120),
    ("5 min", 300),
    ("10 min", 600),
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

// MARK: - Key Recorder Overlay

private struct KeyRecorderOverlay: View {
    var onCapture: (_ keyCode: UInt16, _ modifiers: [String]) -> Void
    var onCancel: () -> Void

    @StateObject private var holder = KeyMonitorHolder()

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
        .onAppear { holder.install(onCapture: onCapture, onCancel: onCancel) }
        .onDisappear { holder.remove() }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isRecordingHotkey = false

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

    var body: some View {
        ZStack {
            Form {
                // ── GENERAL ──────────────────────────────────
                Section("General") {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { LaunchAtLogin.isEnabled },
                        set: { LaunchAtLogin.isEnabled = $0 }
                    ))
                    .toggleStyle(.checkbox)

                    hotkeyRow
                }

                // ── TRANSCRIPTION ────────────────────────────
                Section {
                    languageRow
                    modelRow
                    punctuationRow
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Larger models are more accurate but use more memory. Model downloads automatically when selected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // ── CORRECTIONS & CONTEXT ────────────────────
                Section("Corrections & Context") {
                    correctionsRow
                    screenContextRow
                    editVocabularyButton
                }

                // ── PERFORMANCE ──────────────────────────────
                Section {
                    performanceRow
                } footer: {
                    Text("Memory: \(SettingsViewModel.modelMemoryDescription(viewModel.modelSize)) when loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // ── STORAGE ──────────────────────────────────
                Section {
                    storageRow
                } footer: {
                    Text("Recent dictations appear in the menu bar. Set to Off to delete recordings after transcription.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            if isRecordingHotkey {
                KeyRecorderOverlay(
                    onCapture: { keyCode, modifiers in
                        viewModel.hotkeyKeyCode = keyCode
                        viewModel.hotkeyModifiers = modifiers
                        viewModel.save()
                        isRecordingHotkey = false
                    },
                    onCancel: { isRecordingHotkey = false }
                )
            }
        }
        .onChange(of: viewModel.hotkeyKeyCode) { _ in viewModel.save() }
        .onChange(of: viewModel.toggleMode) { _ in viewModel.save() }
        .onChange(of: viewModel.modelSize) { _ in viewModel.save() }
        .onChange(of: viewModel.language) { _ in viewModel.save() }
        .onChange(of: viewModel.punctuationMode) { _ in viewModel.save() }
        .onChange(of: viewModel.rememberWords) { _ in viewModel.save() }
        .onChange(of: viewModel.screenContext) { newValue in
            viewModel.save()
            if newValue && !ScreenContext.hasPermission {
                _ = ScreenContext.requestPermission()
            }
        }
        .onChange(of: viewModel.maxRecordings) { _ in viewModel.save() }
        .onChange(of: viewModel.idleTimeout) { _ in viewModel.save() }
    }

    // MARK: - Hotkey Row

    private var hotkeyRow: some View {
        LabeledContent("Hotkey") {
            HStack(spacing: 6) {
                if isCustomHotkey {
                    Text(hotkeyDisplay)
                        .font(.body)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                } else {
                    Picker("", selection: $viewModel.hotkeyKeyCode) {
                        ForEach(standardHotkeyOptions) { option in
                            Text(option.label).tag(option.keyCode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                Button("Other\u{2026}") {
                    isRecordingHotkey = true
                }

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
    }

    // MARK: - Language Row

    private var languageRow: some View {
        LabeledContent("Language") {
            Picker("", selection: $viewModel.language) {
                Text("Auto-detect").tag("auto")
                Divider()
                ForEach(sortedLanguages) { lang in
                    Text(lang.name).tag(lang.id)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    // MARK: - Model Row

    private var modelRow: some View {
        let models = availableModels(language: viewModel.language)
        let current = models.first(where: { $0.id == viewModel.modelSize })
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Model") {
                Picker("", selection: $viewModel.modelSize) {
                    ForEach(models) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
                .onChange(of: viewModel.language) { newLang in
                    let newModels = availableModels(language: newLang)
                    if !newModels.contains(where: { $0.id == viewModel.modelSize }) {
                        let base = viewModel.modelSize.replacingOccurrences(of: ".en", with: "")
                        if let match = newModels.first(where: { $0.id.hasPrefix(base) }) {
                            viewModel.modelSize = match.id
                        }
                    }
                }
            }
            Text("\(current?.memory ?? "~800 MB"), \(current?.speed ?? "~0.6s") on your Mac")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Punctuation Row

    private var punctuationRow: some View {
        LabeledContent("Punctuation") {
            Picker("", selection: $viewModel.punctuationMode) {
                Text("Automatic").tag(PunctuationMode.off)
                Text("Spoken").tag(PunctuationMode.spoken)
                Text("Both").tag(PunctuationMode.hybrid)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 200)
        }
    }

    // MARK: - Corrections Row

    private var correctionsRow: some View {
        HStack {
            Toggle("Learn From My Corrections", isOn: $viewModel.rememberWords)
                .toggleStyle(.checkbox)
            Spacer()
            Button("Reset") {
                WordMemory.resetAll()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Screen Context Row

    private var screenContextRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use Screen Context", isOn: $viewModel.screenContext)
                .toggleStyle(.checkbox)
            Text("Reads text on your screen via local OCR to help the model match names and technical terms.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Edit Vocabulary Button

    private var editVocabularyButton: some View {
        Button("Edit Vocabulary File\u{2026}") {
            let url = Config.vocabularyFile
            let dir = Config.configDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                let template = "# Vocabulary for speakfree\n# One word or phrase per line.\n# Lines starting with # are ignored.\n"
                try? template.write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Performance Row

    private var performanceRow: some View {
        LabeledContent("Keep model loaded") {
            Picker("", selection: $viewModel.idleTimeout) {
                ForEach(idleTimeoutOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
    }

    // MARK: - Storage Row

    private var storageRow: some View {
        LabeledContent("Past Recordings") {
            Picker("", selection: $viewModel.maxRecordings) {
                ForEach(maxRecordingsOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(width: 80)
        }
    }
}
