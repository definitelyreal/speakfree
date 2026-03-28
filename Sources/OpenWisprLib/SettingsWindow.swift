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
        // Set preferred content size so the hosting controller knows its bounds
        hostingController.preferredContentSize = NSSize(width: 460, height: 580)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "speakfree Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

// MARK: - Reusable Components

struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 120, alignment: .leading)
            content
            Spacer()
        }
    }
}

// MARK: - Hotkey Option

private struct HotkeyOption: Hashable {
    let label: String
    let keyCode: UInt16
}

private let hotkeyOptions: [HotkeyOption] = [
    HotkeyOption(label: "\u{1F310}  Globe / fn",       keyCode: 63),
    HotkeyOption(label: "\u{2318}  Left Command",      keyCode: 55),
    HotkeyOption(label: "\u{2318}  Right Command",     keyCode: 54),
    HotkeyOption(label: "\u{2325}  Left Option",       keyCode: 58),
    HotkeyOption(label: "\u{2325}  Right Option",      keyCode: 61),
    HotkeyOption(label: "\u{2303}  Left Control",      keyCode: 59),
]

// MARK: - Model Option

private struct ModelOption: Hashable, Identifiable {
    let id: String   // e.g. "small.en"
    let label: String

    static let all: [ModelOption] = [
        ModelOption(id: "tiny.en",    label: "tiny.en"),
        ModelOption(id: "tiny",       label: "tiny (multilingual)"),
        ModelOption(id: "base.en",    label: "base.en"),
        ModelOption(id: "base",       label: "base (multilingual)"),
        ModelOption(id: "small.en",   label: "small.en"),
        ModelOption(id: "small",      label: "small (multilingual)"),
        ModelOption(id: "medium.en",  label: "medium.en"),
        ModelOption(id: "medium",     label: "medium (multilingual)"),
        ModelOption(id: "large-v3",   label: "large-v3"),
    ]
}

// MARK: - Language Combo Box

/// An autocomplete combo-box for selecting a Whisper language.
private struct LanguageComboBox: View {
    @Binding var languageCode: String
    var onCommit: () -> Void

    @State private var query: String = ""
    @State private var isOpen: Bool = false

    /// Resolved display name for the current code.
    private var displayName: String {
        if languageCode == "auto" { return "Auto-detect" }
        return WhisperLanguage.find(languageCode)?.name ?? languageCode
    }

    private var filteredLanguages: [WhisperLanguage] {
        WhisperLanguage.search(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                TextField("Search language...", text: $query, onEditingChanged: { editing in
                    if editing { isOpen = true }
                })
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onAppear { query = displayName }

                if languageCode != "en" && languageCode != "auto" {
                    Button(action: {
                        languageCode = "en"
                        query = "English"
                        isOpen = false
                        onCommit()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Auto-detect at the top
                        languageRow(name: "Auto-detect", code: "auto")

                        Divider()

                        ForEach(filteredLanguages) { lang in
                            languageRow(name: "\(lang.name) (\(lang.id))", code: lang.id)
                        }
                    }
                }
                .frame(width: 200, height: min(CGFloat(filteredLanguages.count + 1) * 26, 200))
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .shadow(radius: 4)
            }
        }
    }

    private func languageRow(name: String, code: String) -> some View {
        Button(action: {
            languageCode = code
            query = name.components(separatedBy: " (").first ?? name
            isOpen = false
            onCommit()
        }) {
            Text(name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Max Recordings Option

private struct MaxRecordingsOption: Hashable {
    let label: String
    let value: Int
}

private let maxRecordingsOptions: [MaxRecordingsOption] = [
    MaxRecordingsOption(label: "Off", value: 0),
    MaxRecordingsOption(label: "10", value: 10),
    MaxRecordingsOption(label: "20", value: 20),
    MaxRecordingsOption(label: "30", value: 30),
    MaxRecordingsOption(label: "50", value: 50),
    MaxRecordingsOption(label: "100", value: 100),
]

// MARK: - Vocabulary List

struct VocabularyList: View {
    @Binding var refreshTrigger: Int
    @State private var entries: [WordMemory.VocabEntry] = []

    var body: some View {
        Group {
            if entries.isEmpty {
                Text("No vocabulary entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 120)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 6) {
                            Text(entry.word)
                                .font(.body)
                            if entry.isAuto {
                                Text("(auto)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                if entry.isAuto {
                                    // Auto entries come from dictionary.json — find the wrong key
                                    let dict = WordMemory.load()
                                    if let wrong = dict.first(where: { $0.value == entry.word })?.key {
                                        WordMemory.forget(wrong)
                                    }
                                } else {
                                    WordMemory.removeFromVocab(entry.word)
                                }
                                entries = WordMemory.loadVocabularyEntries()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.leading, 120)
            }
        }
        .onAppear { entries = WordMemory.loadVocabularyEntries() }
        .onChange(of: refreshTrigger) { _ in entries = WordMemory.loadVocabularyEntries() }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var vocabRefresh: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeader("General")

                SettingsRow("Hotkey") {
                    Picker("", selection: $viewModel.hotkeyKeyCode) {
                        ForEach(hotkeyOptions, id: \.self) { option in
                            Text(option.label).tag(option.keyCode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                SettingsRow("Key Mode") {
                    Picker("", selection: $viewModel.toggleMode) {
                        Text("Hold").tag(false)
                        Text("Toggle").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }

                SettingsRow("Launch at Login") {
                    Toggle("", isOn: Binding(
                        get: { LaunchAtLogin.isEnabled },
                        set: { LaunchAtLogin.isEnabled = $0 }
                    ))
                    .labelsHidden()
                }

                Divider()

                SectionHeader("Transcription")

                SettingsRow("Model") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $viewModel.modelSize) {
                            ForEach(ModelOption.all) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)

                        Text("\(SettingsViewModel.modelMemoryDescription(viewModel.modelSize)), \(SettingsViewModel.modelSpeedDescription(viewModel.modelSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                SettingsRow("Language") {
                    LanguageComboBox(
                        languageCode: $viewModel.language,
                        onCommit: { viewModel.save() }
                    )
                }

                SettingsRow("Punctuation") {
                    Picker("", selection: $viewModel.punctuationMode) {
                        Text("Off").tag(PunctuationMode.off)
                        Text("Spoken words").tag(PunctuationMode.spoken)
                        Text("Hybrid").tag(PunctuationMode.hybrid)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                Divider()

                SectionHeader("Vocabulary")

                SettingsRow("Auto-learn") {
                    Toggle("", isOn: $viewModel.rememberWords)
                        .labelsHidden()
                }

                VocabularyList(refreshTrigger: $vocabRefresh)

                HStack(spacing: 12) {
                    Button("Edit File\u{2026}") {
                        NSWorkspace.shared.open(Config.vocabularyFile)
                    }
                    Button("Reset All") {
                        WordMemory.resetAll()
                        vocabRefresh += 1
                    }
                }
                .padding(.leading, 120)

                Divider()

                SectionHeader("Privacy & Storage")

                SettingsRow("Screen Context") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("", isOn: $viewModel.screenContext)
                            .labelsHidden()
                        Text("Local OCR of active window")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                SettingsRow("Max Recordings") {
                    Picker("", selection: $viewModel.maxRecordings) {
                        ForEach(maxRecordingsOptions, id: \.self) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}
