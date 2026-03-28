# speakfree v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Add a SwiftUI settings window, simplify the menu bar, add language support, and improve transcription defaults/performance.

**Architecture:** Replace nested menu bar settings with a single-page SwiftUI settings window hosted in an NSWindow via NSHostingController. Config remains a Codable struct persisted as JSON; a new ObservableObject SettingsViewModel bridges Config to SwiftUI bindings. Menu bar retains only status, recent dictations, and window launchers.

**Tech Stack:** Swift 5.9, SwiftUI (hosted in AppKit NSWindow), macOS 13+ (Ventura), AVFoundation, ServiceManagement (SMAppService for launch-at-login)

---

## Phase 1: Settings Window + Menu Simplification

### Task 1: Create SettingsViewModel

**Files:**
- Create: `Sources/OpenWisprLib/SettingsViewModel.swift`
- Test: `Tests/OpenWisprTests/SettingsViewModelTests.swift`

**Step 1: Write the failing test**

```swift
// Tests/OpenWisprTests/SettingsViewModelTests.swift
import XCTest
@testable import OpenWisprLib

final class SettingsViewModelTests: XCTestCase {

    func testInitLoadsFromConfig() throws {
        let json = """
        {
            "hotkey": {"keyCode": 55, "modifiers": ["cmd"]},
            "modelSize": "small.en",
            "language": "en",
            "spokenPunctuation": "hybrid",
            "maxRecordings": 20,
            "toggleMode": true,
            "screenContext": false,
            "rememberWords": true
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        let vm = SettingsViewModel(config: config)

        XCTAssertEqual(vm.hotkeyKeyCode, 55)
        XCTAssertEqual(vm.modelSize, "small.en")
        XCTAssertEqual(vm.language, "en")
        XCTAssertEqual(vm.punctuationMode, .hybrid)
        XCTAssertEqual(vm.maxRecordings, 20)
        XCTAssertTrue(vm.toggleMode)
        XCTAssertFalse(vm.screenContext)
        XCTAssertTrue(vm.rememberWords)
    }

    func testToConfigRoundTrips() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "base.en",
            "language": "en",
            "spokenPunctuation": false,
            "maxRecordings": 30,
            "toggleMode": false,
            "screenContext": true,
            "rememberWords": false
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        let vm = SettingsViewModel(config: config)
        let roundTripped = vm.toConfig()

        XCTAssertEqual(roundTripped.hotkey.keyCode, 63)
        XCTAssertEqual(roundTripped.modelSize, "base.en")
        XCTAssertEqual(roundTripped.spokenPunctuation, .off)
        XCTAssertEqual(roundTripped.maxRecordings, 30)
    }

    func testModelMemoryDescription() {
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("tiny.en"), "~230 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("base.en"), "~330 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("small.en"), "~800 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("medium.en"), "~2.1 GB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("large-v3"), "~3.9 GB")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsViewModelTests 2>&1 | tail -20`
Expected: Compilation error — SettingsViewModel doesn't exist yet

**Step 3: Write the implementation**

```swift
// Sources/OpenWisprLib/SettingsViewModel.swift
import Foundation
import Combine

public class SettingsViewModel: ObservableObject {
    @Published public var hotkeyKeyCode: UInt16
    @Published public var hotkeyModifiers: [String]
    @Published public var toggleMode: Bool
    @Published public var modelSize: String
    @Published public var language: String
    @Published public var punctuationMode: PunctuationMode
    @Published public var maxRecordings: Int
    @Published public var screenContext: Bool
    @Published public var rememberWords: Bool

    /// Callback fired after save() — lets AppDelegate reload config
    public var onSave: (() -> Void)?

    public init(config: Config? = nil) {
        let c = config ?? Config.load()
        self.hotkeyKeyCode = c.hotkey.keyCode
        self.hotkeyModifiers = c.hotkey.modifiers
        self.toggleMode = c.toggleMode?.value ?? false
        self.modelSize = c.modelSize
        self.language = c.language
        self.punctuationMode = c.spokenPunctuation ?? .off
        self.maxRecordings = c.maxRecordings ?? Config.defaultMaxRecordings
        self.screenContext = c.screenContext?.value ?? false
        self.rememberWords = c.rememberWords?.value ?? false
    }

    public func toConfig() -> Config {
        return Config(
            hotkey: HotkeyConfig(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers),
            modelPath: nil,
            modelSize: modelSize,
            language: language,
            spokenPunctuation: punctuationMode,
            maxRecordings: maxRecordings,
            toggleMode: FlexBool(toggleMode),
            screenContext: FlexBool(screenContext),
            rememberWords: FlexBool(rememberWords)
        )
    }

    public func save() {
        let config = toConfig()
        try? config.save()
        onSave?()
    }

    // MARK: - Model metadata

    private static let modelMemory: [String: String] = [
        "tiny.en": "~230 MB",   "tiny": "~230 MB",
        "base.en": "~330 MB",   "base": "~330 MB",
        "small.en": "~800 MB",  "small": "~800 MB",
        "medium.en": "~2.1 GB", "medium": "~2.1 GB",
        "large-v3": "~3.9 GB",  "large": "~3.9 GB",
    ]

    public static func modelMemoryDescription(_ model: String) -> String {
        return modelMemory[model] ?? "unknown"
    }

    private static let modelSpeed: [String: String] = [
        "tiny.en": "~0.6s", "tiny": "~0.6s",
        "base.en": "~0.6s", "base": "~0.6s",
        "small.en": "~0.6s", "small": "~0.6s",
        "medium.en": "~1.3s", "medium": "~1.3s",
        "large-v3": "~2.1s", "large": "~2.1s",
    ]

    public static func modelSpeedDescription(_ model: String) -> String {
        return modelSpeed[model] ?? "unknown"
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SettingsViewModelTests 2>&1 | tail -20`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/OpenWisprLib/SettingsViewModel.swift Tests/OpenWisprTests/SettingsViewModelTests.swift
git commit -m "feat: add SettingsViewModel bridging Config to SwiftUI bindings"
```

---

### Task 2: Create SettingsWindow shell

**Files:**
- Create: `Sources/OpenWisprLib/SettingsWindow.swift`
- Modify: `Sources/OpenWisprLib/AppDelegate.swift`

**Step 1: Create the settings window with a placeholder view**

```swift
// Sources/OpenWisprLib/SettingsWindow.swift
import AppKit
import SwiftUI

class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(viewModel: SettingsViewModel) {
        if shared == nil {
            shared = SettingsWindowController(viewModel: viewModel)
        }
        shared?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    convenience init(viewModel: SettingsViewModel) {
        let hostingController = NSHostingController(
            rootView: SettingsView(viewModel: viewModel)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "speakfree Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Settings UI coming soon — this is a placeholder.")
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

**Step 2: Wire up Settings window in AppDelegate**

In `Sources/OpenWisprLib/AppDelegate.swift`, add a property and a public method:

```swift
// Add property near other properties:
private var settingsViewModel: SettingsViewModel?

// Add method:
public func showSettings() {
    if settingsViewModel == nil {
        settingsViewModel = SettingsViewModel()
        settingsViewModel?.onSave = { [weak self] in
            self?.reloadConfig()
        }
    }
    SettingsWindowController.show(viewModel: settingsViewModel!)
}
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/OpenWisprLib/SettingsWindow.swift Sources/OpenWisprLib/AppDelegate.swift
git commit -m "feat: add SettingsWindow shell with SwiftUI hosted in NSWindow"
```

---

### Task 3: Implement General section

**Files:**
- Modify: `Sources/OpenWisprLib/SettingsWindow.swift`

**Step 1: Replace placeholder with General section**

Replace the `body` of `SettingsView` with real sections. Start with General:

```swift
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    private let hotkeyOptions: [(label: String, keyCode: UInt16)] = [
        ("🌐  Globe / fn", 63),
        ("⌘  Left Command", 55),
        ("⌘  Right Command", 54),
        ("⌥  Left Option", 58),
        ("⌥  Right Option", 61),
        ("⌃  Left Control", 59),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // GENERAL
                SectionHeader("General")

                SettingsRow("Hotkey") {
                    Picker("", selection: $viewModel.hotkeyKeyCode) {
                        ForEach(hotkeyOptions, id: \.keyCode) { option in
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
                    .frame(width: 140)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: viewModel.hotkeyKeyCode) { _ in viewModel.save() }
        .onChange(of: viewModel.toggleMode) { _ in viewModel.save() }
    }
}

// MARK: - Reusable components

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
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
        HStack {
            Text(label)
                .frame(width: 120, alignment: .leading)
            content
            Spacer()
        }
    }
}
```

**Step 2: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/OpenWisprLib/SettingsWindow.swift
git commit -m "feat: implement General section in settings (hotkey, key mode)"
```

---

### Task 4: Implement Transcription section

**Files:**
- Modify: `Sources/OpenWisprLib/SettingsWindow.swift`
- Create: `Sources/OpenWisprLib/WhisperLanguages.swift`

**Step 1: Create the Whisper language list**

```swift
// Sources/OpenWisprLib/WhisperLanguages.swift
import Foundation

public struct WhisperLanguage: Identifiable, Hashable {
    public let id: String  // whisper code: "en", "es", "ja", etc.
    public let name: String

    public static let all: [WhisperLanguage] = [
        WhisperLanguage(id: "en", name: "English"),
        WhisperLanguage(id: "zh", name: "Chinese"),
        WhisperLanguage(id: "de", name: "German"),
        WhisperLanguage(id: "es", name: "Spanish"),
        WhisperLanguage(id: "ru", name: "Russian"),
        WhisperLanguage(id: "ko", name: "Korean"),
        WhisperLanguage(id: "fr", name: "French"),
        WhisperLanguage(id: "ja", name: "Japanese"),
        WhisperLanguage(id: "pt", name: "Portuguese"),
        WhisperLanguage(id: "tr", name: "Turkish"),
        WhisperLanguage(id: "pl", name: "Polish"),
        WhisperLanguage(id: "ca", name: "Catalan"),
        WhisperLanguage(id: "nl", name: "Dutch"),
        WhisperLanguage(id: "ar", name: "Arabic"),
        WhisperLanguage(id: "sv", name: "Swedish"),
        WhisperLanguage(id: "it", name: "Italian"),
        WhisperLanguage(id: "id", name: "Indonesian"),
        WhisperLanguage(id: "hi", name: "Hindi"),
        WhisperLanguage(id: "fi", name: "Finnish"),
        WhisperLanguage(id: "vi", name: "Vietnamese"),
        WhisperLanguage(id: "he", name: "Hebrew"),
        WhisperLanguage(id: "uk", name: "Ukrainian"),
        WhisperLanguage(id: "el", name: "Greek"),
        WhisperLanguage(id: "ms", name: "Malay"),
        WhisperLanguage(id: "cs", name: "Czech"),
        WhisperLanguage(id: "ro", name: "Romanian"),
        WhisperLanguage(id: "da", name: "Danish"),
        WhisperLanguage(id: "hu", name: "Hungarian"),
        WhisperLanguage(id: "ta", name: "Tamil"),
        WhisperLanguage(id: "no", name: "Norwegian"),
        WhisperLanguage(id: "th", name: "Thai"),
        WhisperLanguage(id: "ur", name: "Urdu"),
        WhisperLanguage(id: "hr", name: "Croatian"),
        WhisperLanguage(id: "bg", name: "Bulgarian"),
        WhisperLanguage(id: "lt", name: "Lithuanian"),
        WhisperLanguage(id: "la", name: "Latin"),
        WhisperLanguage(id: "mi", name: "Maori"),
        WhisperLanguage(id: "ml", name: "Malayalam"),
        WhisperLanguage(id: "cy", name: "Welsh"),
        WhisperLanguage(id: "sk", name: "Slovak"),
        WhisperLanguage(id: "te", name: "Telugu"),
        WhisperLanguage(id: "fa", name: "Persian"),
        WhisperLanguage(id: "lv", name: "Latvian"),
        WhisperLanguage(id: "bn", name: "Bengali"),
        WhisperLanguage(id: "sr", name: "Serbian"),
        WhisperLanguage(id: "az", name: "Azerbaijani"),
        WhisperLanguage(id: "sl", name: "Slovenian"),
        WhisperLanguage(id: "kn", name: "Kannada"),
        WhisperLanguage(id: "et", name: "Estonian"),
        WhisperLanguage(id: "mk", name: "Macedonian"),
        WhisperLanguage(id: "br", name: "Breton"),
        WhisperLanguage(id: "eu", name: "Basque"),
        WhisperLanguage(id: "is", name: "Icelandic"),
        WhisperLanguage(id: "hy", name: "Armenian"),
        WhisperLanguage(id: "ne", name: "Nepali"),
        WhisperLanguage(id: "mn", name: "Mongolian"),
        WhisperLanguage(id: "bs", name: "Bosnian"),
        WhisperLanguage(id: "kk", name: "Kazakh"),
        WhisperLanguage(id: "sq", name: "Albanian"),
        WhisperLanguage(id: "sw", name: "Swahili"),
        WhisperLanguage(id: "gl", name: "Galician"),
        WhisperLanguage(id: "mr", name: "Marathi"),
        WhisperLanguage(id: "pa", name: "Punjabi"),
        WhisperLanguage(id: "si", name: "Sinhala"),
        WhisperLanguage(id: "km", name: "Khmer"),
        WhisperLanguage(id: "sn", name: "Shona"),
        WhisperLanguage(id: "yo", name: "Yoruba"),
        WhisperLanguage(id: "so", name: "Somali"),
        WhisperLanguage(id: "af", name: "Afrikaans"),
        WhisperLanguage(id: "oc", name: "Occitan"),
        WhisperLanguage(id: "ka", name: "Georgian"),
        WhisperLanguage(id: "be", name: "Belarusian"),
        WhisperLanguage(id: "tg", name: "Tajik"),
        WhisperLanguage(id: "sd", name: "Sindhi"),
        WhisperLanguage(id: "gu", name: "Gujarati"),
        WhisperLanguage(id: "am", name: "Amharic"),
        WhisperLanguage(id: "yi", name: "Yiddish"),
        WhisperLanguage(id: "lo", name: "Lao"),
        WhisperLanguage(id: "uz", name: "Uzbek"),
        WhisperLanguage(id: "fo", name: "Faroese"),
        WhisperLanguage(id: "ht", name: "Haitian Creole"),
        WhisperLanguage(id: "ps", name: "Pashto"),
        WhisperLanguage(id: "tk", name: "Turkmen"),
        WhisperLanguage(id: "nn", name: "Nynorsk"),
        WhisperLanguage(id: "mt", name: "Maltese"),
        WhisperLanguage(id: "sa", name: "Sanskrit"),
        WhisperLanguage(id: "lb", name: "Luxembourgish"),
        WhisperLanguage(id: "my", name: "Myanmar"),
        WhisperLanguage(id: "bo", name: "Tibetan"),
        WhisperLanguage(id: "tl", name: "Tagalog"),
        WhisperLanguage(id: "mg", name: "Malagasy"),
        WhisperLanguage(id: "as", name: "Assamese"),
        WhisperLanguage(id: "tt", name: "Tatar"),
        WhisperLanguage(id: "haw", name: "Hawaiian"),
        WhisperLanguage(id: "ln", name: "Lingala"),
        WhisperLanguage(id: "ha", name: "Hausa"),
        WhisperLanguage(id: "ba", name: "Bashkir"),
        WhisperLanguage(id: "jw", name: "Javanese"),
        WhisperLanguage(id: "su", name: "Sundanese"),
        WhisperLanguage(id: "yue", name: "Cantonese"),
    ]

    /// Lookup by code
    public static func find(_ code: String) -> WhisperLanguage? {
        all.first { $0.id == code }
    }

    /// Search by name or code prefix (for autocomplete)
    public static func search(_ query: String) -> [WhisperLanguage] {
        let q = query.lowercased()
        if q.isEmpty { return all }
        return all.filter {
            $0.name.lowercased().hasPrefix(q) || $0.id.lowercased().hasPrefix(q)
        }
    }

    /// The multilingual model equivalent for a given .en model
    /// e.g. "small.en" -> "small", "large-v3" -> "large-v3" (already multilingual)
    public static func multilingualModel(for model: String) -> String {
        if model.hasSuffix(".en") {
            return String(model.dropLast(3))
        }
        return model  // already multilingual
    }

    /// Whether a model is English-only
    public static func isEnglishOnly(_ model: String) -> Bool {
        model.hasSuffix(".en")
    }
}
```

**Step 2: Add Transcription section to SettingsView**

Add after the General section's `.onChange` modifiers, inside the VStack:

```swift
// TRANSCRIPTION
SectionHeader("Transcription")

SettingsRow("Model") {
    Picker("", selection: $viewModel.modelSize) {
        ForEach(modelOptions, id: \.id) { option in
            Text(option.label).tag(option.id)
        }
    }
    .labelsHidden()
    .frame(width: 200)
    Text(SettingsViewModel.modelMemoryDescription(viewModel.modelSize))
        .foregroundColor(.secondary)
        .font(.caption)
}

SettingsRow("Language") {
    LanguageField(language: $viewModel.language)
}

SettingsRow("Punctuation") {
    Picker("", selection: $viewModel.punctuationMode) {
        Text("Off").tag(PunctuationMode.off)
        Text("Spoken words").tag(PunctuationMode.spoken)
        Text("Hybrid (auto + spoken)").tag(PunctuationMode.hybrid)
    }
    .labelsHidden()
    .frame(width: 200)
}
```

With supporting properties and the LanguageField view:

```swift
private var modelOptions: [(id: String, label: String)] {
    [
        ("tiny.en", "tiny.en"),
        ("base.en", "base.en"),
        ("small.en", "small.en"),
        ("medium.en", "medium.en"),
        ("large-v3", "large-v3"),
        // multilingual variants
        ("tiny", "tiny (multilingual)"),
        ("base", "base (multilingual)"),
        ("small", "small (multilingual)"),
        ("medium", "medium (multilingual)"),
    ]
}
```

```swift
struct LanguageField: View {
    @Binding var language: String
    @State private var searchText = ""
    @State private var isShowingPopover = false

    var body: some View {
        HStack(spacing: 4) {
            TextField("Type to search...", text: $searchText, onEditingChanged: { editing in
                isShowingPopover = editing
            })
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    let results = WhisperLanguages.search(searchText)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Auto-detect option
                            Button(action: {
                                language = "auto"
                                searchText = "Auto-detect"
                                isShowingPopover = false
                            }) {
                                Text("Auto-detect")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)

                            Divider()

                            ForEach(results) { lang in
                                Button(action: {
                                    language = lang.id
                                    searchText = lang.name
                                    isShowingPopover = false
                                }) {
                                    Text("\(lang.name) (\(lang.id))")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: 200, height: min(CGFloat(results.count + 1) * 28, 300))
                }
            }

            if language != "en" && language != "auto" {
                Button(action: {
                    language = "en"
                    searchText = "English"
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if language == "auto" {
                searchText = "Auto-detect"
            } else if let lang = WhisperLanguages.find(language) {
                searchText = lang.name
            } else {
                searchText = language
            }
        }
    }
}
```

**Step 3: Add `.onChange` handlers for new fields**

```swift
.onChange(of: viewModel.modelSize) { _ in viewModel.save() }
.onChange(of: viewModel.language) { _ in viewModel.save() }
.onChange(of: viewModel.punctuationMode) { _ in viewModel.save() }
```

**Step 4: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/OpenWisprLib/WhisperLanguages.swift Sources/OpenWisprLib/SettingsWindow.swift
git commit -m "feat: add Transcription section with model picker, language autocomplete, punctuation"
```

---

### Task 5: Implement Vocabulary, Privacy & Storage sections

**Files:**
- Modify: `Sources/OpenWisprLib/SettingsWindow.swift`

**Step 1: Add remaining sections to SettingsView**

Add after Transcription section in the VStack:

```swift
// VOCABULARY
SectionHeader("Vocabulary")

SettingsRow("Auto-learn") {
    Toggle("", isOn: $viewModel.rememberWords)
        .labelsHidden()
}

VocabularyList()

HStack(spacing: 12) {
    Button("Edit File…") {
        let vocabURL = Config.vocabularyFile
        if !FileManager.default.fileExists(atPath: vocabURL.path) {
            try? FileManager.default.createDirectory(
                at: Config.configDir, withIntermediateDirectories: true)
            let template = "# Vocabulary for speakfree\n# One word or phrase per line.\n"
            try? template.write(to: vocabURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(vocabURL)
    }
    Button("Reset All") {
        WordMemory.resetAll()
    }
}
.padding(.leading, 124)

Divider()

// PRIVACY & STORAGE
SectionHeader("Privacy & Storage")

SettingsRow("Screen Context") {
    Toggle("", isOn: $viewModel.screenContext)
        .labelsHidden()
    Text("Local OCR of active window")
        .foregroundColor(.secondary)
        .font(.caption)
}

SettingsRow("Max Recordings") {
    Picker("", selection: $viewModel.maxRecordings) {
        Text("Off").tag(0)
        Text("10").tag(10)
        Text("20").tag(20)
        Text("30").tag(30)
        Text("50").tag(50)
        Text("100").tag(100)
    }
    .labelsHidden()
    .frame(width: 100)
}
```

VocabularyList as a separate view:

```swift
struct VocabularyList: View {
    @State private var entries: [WordMemory.VocabEntry] = []

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.word) { entry in
                    HStack {
                        Text(entry.word)
                            .font(.system(.body, design: .monospaced))
                        if entry.isAuto {
                            Text("auto")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(3)
                        }
                        Spacer()
                        Button(action: {
                            if entry.isAuto {
                                let corrections = WordMemory.load()
                                if let wrong = corrections.first(where: {
                                    $0.value.lowercased() == entry.word.lowercased()
                                })?.key {
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
            .padding(.leading, 124)
        }
    }
}
```

**Step 2: Add `.onChange` handlers**

```swift
.onChange(of: viewModel.rememberWords) { _ in viewModel.save() }
.onChange(of: viewModel.screenContext) { newValue in
    if newValue && !ScreenContext.hasPermission {
        ScreenContext.requestPermission()
    }
    viewModel.save()
}
.onChange(of: viewModel.maxRecordings) { _ in viewModel.save() }
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/OpenWisprLib/SettingsWindow.swift
git commit -m "feat: add Vocabulary and Privacy sections to settings window"
```

---

### Task 6: Simplify menu bar

**Files:**
- Modify: `Sources/OpenWisprLib/StatusBarController.swift`
- Modify: `Sources/OpenWisprLib/AppDelegate.swift`

**Step 1: Strip settings submenus from StatusBarController**

Replace the `buildMenuItems` method in `StatusBarController.swift`. Remove all settings submenus (Hotkey, Model, Punctuation, Key Mode, Max Recordings, Screen Context, Vocabulary). Replace with a single "Settings..." item that calls `AppDelegate.showSettings()`.

The new `buildMenuItems` should contain only:
1. Title ("speakfree v{version}")
2. Status line (Ready / Recording / Transcribing / etc.)
3. Crash recovery (if pending)
4. Recent Dictations submenu (keep as-is)
5. "Settings..." menu item (⌘,)
6. Check for Updates...
7. Help
8. Quit (⌘Q)

Remove `setHotkey`, `setModel`, `setPunctuation`, `setToggleMode`, `setMaxRecordings`, `setRememberWords`, `setScreenContext` private methods. Keep `applyConfig` only if still needed.

**Step 2: Add Settings... menu item wiring**

In the new `buildMenuItems`, add:

```swift
let settingsTarget = MenuItemTarget {
    guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
    delegate.showSettings()
}
menuItemTargets.append(settingsTarget)
let settingsItem = NSMenuItem(title: "Settings...", action: #selector(MenuItemTarget.invoke), keyEquivalent: ",")
settingsItem.target = settingsTarget
settingsItem.keyEquivalentModifierMask = .command
menu.addItem(settingsItem)
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/OpenWisprLib/StatusBarController.swift Sources/OpenWisprLib/AppDelegate.swift
git commit -m "refactor: simplify menu bar, move all settings to Settings window"
```

---

### Task 7: Default to small.en + pass optimization flags

**Files:**
- Modify: `Sources/OpenWisprLib/Config.swift`
- Modify: `Sources/OpenWisprLib/Transcriber.swift`
- Modify: `Sources/OpenWisprLib/HelpController.swift`
- Modify: `Tests/OpenWisprTests/ConfigTests.swift`

**Step 1: Change default model**

In `Config.swift`, change `defaultConfig`:

```swift
public static let defaultConfig = Config(
    hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
    modelPath: nil,
    modelSize: "small.en",  // was "base.en"
    language: "en",
    spokenPunctuation: .hybrid,
    maxRecordings: 30,
    toggleMode: FlexBool(false)
)
```

**Step 2: Add thread count optimization to Transcriber**

In `Transcriber.swift`, add thread count flag to the args array:

```swift
var args = [
    "-m", modelPath,
    "-f", audioURL.path,
    "-l", language,
    "--no-timestamps",
    "-nt",
    "-t", "\(ProcessInfo.processInfo.activeProcessorCount)",
]
```

**Step 3: Update help text**

In `HelpController.swift`, update the "Recommended" label from base.en to small.en:

```swift
row("base.en",   "142 MB · Fast and accurate for everyday use")
row("small.en",  "466 MB · Recommended · Better accuracy, same speed as base")
```

**Step 4: Update test**

In `ConfigTests.swift`, update `testConfigDecodesWithoutMaxRecordings` if it references default model, and add:

```swift
func testDefaultModelIsSmallEn() {
    let config = Config.defaultConfig
    XCTAssertEqual(config.modelSize, "small.en")
}
```

**Step 5: Run tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add Sources/OpenWisprLib/Config.swift Sources/OpenWisprLib/Transcriber.swift Sources/OpenWisprLib/HelpController.swift Tests/OpenWisprTests/ConfigTests.swift
git commit -m "feat: default to small.en, pass thread count to whisper-cli"
```

---

### Task 8: Language support in Transcriber

**Files:**
- Modify: `Sources/OpenWisprLib/Transcriber.swift`
- Modify: `Sources/OpenWisprLib/AppDelegate.swift`
- Test: `Tests/OpenWisprTests/WhisperLanguagesTests.swift`

**Step 1: Write language tests**

```swift
// Tests/OpenWisprTests/WhisperLanguagesTests.swift
import XCTest
@testable import OpenWisprLib

final class WhisperLanguagesTests: XCTestCase {

    func testSearchByNamePrefix() {
        let results = WhisperLanguages.search("jap")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "ja")
    }

    func testSearchByCodePrefix() {
        let results = WhisperLanguages.search("es")
        XCTAssertTrue(results.contains { $0.id == "es" })
        // Also matches "et" (Estonian) by code prefix
    }

    func testSearchEmptyReturnsAll() {
        let results = WhisperLanguages.search("")
        XCTAssertEqual(results.count, WhisperLanguages.all.count)
    }

    func testMultilingualModelConversion() {
        XCTAssertEqual(WhisperLanguages.multilingualModel(for: "small.en"), "small")
        XCTAssertEqual(WhisperLanguages.multilingualModel(for: "base.en"), "base")
        XCTAssertEqual(WhisperLanguages.multilingualModel(for: "large-v3"), "large-v3")
    }

    func testIsEnglishOnly() {
        XCTAssertTrue(WhisperLanguages.isEnglishOnly("small.en"))
        XCTAssertFalse(WhisperLanguages.isEnglishOnly("small"))
        XCTAssertFalse(WhisperLanguages.isEnglishOnly("large-v3"))
    }
}
```

**Step 2: Run tests to verify they pass**

Run: `swift test --filter WhisperLanguagesTests 2>&1 | tail -20`
Expected: All PASS (implementation was written in Task 4)

**Step 3: Update Transcriber to handle language=auto and multilingual models**

When `language` is "auto", pass `-l auto` to whisper-cli. The Transcriber already takes language as init param — just ensure the value flows through from config.

When language is not "en" and model is English-only (.en suffix), the AppDelegate should automatically switch to the multilingual variant when building the Transcriber. Add to `setupInner()` and `reloadConfig()` in AppDelegate:

```swift
// If language isn't English, ensure we use a multilingual model
var effectiveModelSize = config.modelSize
if config.language != "en" && WhisperLanguages.isEnglishOnly(config.modelSize) {
    effectiveModelSize = WhisperLanguages.multilingualModel(for: config.modelSize)
}
transcriber = Transcriber(modelSize: effectiveModelSize, language: config.language)
```

**Step 4: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All PASS

**Step 5: Commit**

```bash
git add Sources/OpenWisprLib/Transcriber.swift Sources/OpenWisprLib/AppDelegate.swift Tests/OpenWisprTests/WhisperLanguagesTests.swift
git commit -m "feat: language support — auto-detect and multilingual model switching"
```

---

### Task 9: Launch at Login

**Files:**
- Modify: `Sources/OpenWisprLib/SettingsWindow.swift`
- Modify: `Sources/OpenWisprLib/AppDelegate.swift`

**Step 1: Add SMAppService support**

In `SettingsWindow.swift`, add to the General section:

```swift
SettingsRow("Launch at Login") {
    Toggle("", isOn: Binding(
        get: { LaunchAtLogin.isEnabled },
        set: { LaunchAtLogin.isEnabled = $0 }
    ))
    .labelsHidden()
}
```

Create a simple helper:

```swift
// Add to AppDelegate.swift or a new LaunchAtLogin.swift
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Launch at login error: \(error.localizedDescription)")
            }
        }
    }
}
```

Note: `SMAppService` requires macOS 13+ (which we target) and the app must be code-signed.

**Step 2: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/OpenWisprLib/SettingsWindow.swift Sources/OpenWisprLib/AppDelegate.swift
git commit -m "feat: add Launch at Login toggle via SMAppService"
```

---

## Phase 2: whisper.cpp Library Integration (Outline)

> Detailed implementation plan to be written when Phase 1 is complete.

### Task 10: Add whisper.cpp C library as SPM dependency

- Add whisper.cpp Swift package to Package.swift
- Verify it builds with Metal support on Apple Silicon
- Create `WhisperEngine.swift` wrapping the C API: `loadModel()`, `transcribe()`, `unloadModel()`
- Write tests: load model, transcribe test audio, verify output

### Task 11: Replace CLI subprocess with library calls

- Modify `Transcriber.swift` to use `WhisperEngine` instead of `Process()`
- Feed PCM samples directly from AudioRecorder buffer (skip WAV file I/O)
- Maintain fallback to CLI for users who prefer Homebrew whisper-cpp
- Write integration test: record → transcribe → verify text

### Task 12: Smart model loading

- Load model on first transcription, not at launch
- Configurable idle timeout (unload after N minutes)
- Add `ProcessInfo` memory pressure observer — unload on pressure
- Add Performance section to settings: "Keep model loaded" toggle, timeout picker, status display
- Write tests: load/unload cycles, memory pressure response

### Task 13: Auto-recommend model based on RAM

- Detect total system RAM via `ProcessInfo.processInfo.physicalMemory`
- Map to recommended model: 8GB→base, 16GB→small, 32GB+→small (suggest medium)
- Show recommendation in model picker: "Recommended for your Mac"
- Only applies on first launch (don't override user choice)

---

## Phase 3: New Capabilities (Outline)

> Detailed implementation plan to be written when Phase 2 is complete.

### Task 14: VAD (Voice Activity Detection)

- Use whisper.cpp built-in VAD or simple energy-based detector
- Trim leading/trailing silence before inference
- Reduces inference time on clips with dead air

### Task 15: Audio input selection

- List available audio input devices via AVCaptureDevice.DiscoverySession
- Add picker in Settings: "Microphone" dropdown
- Store selected device ID in Config
- Use selected device in AudioRecorder instead of default

### Task 16: Streaming transcription

- Depends on library integration (Task 10-11)
- Chunk audio into segments, run inference on each chunk
- Display partial results in floating overlay
- Final pass on complete audio replaces partial text
- Most complex feature — needs careful UX design

### Task 17: Multi-language auto-detect polish

- When language="auto", show detected language in status bar briefly
- Fall back to preferred language for very short clips (<3s)
- Add "Preferred language" setting for fallback
