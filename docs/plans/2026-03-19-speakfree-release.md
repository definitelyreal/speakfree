# speakfree Release Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Rename, rebrand, and polish openwisprmod into speakfree — a self-contained drag-to-Applications macOS app for non-technical users — and publish it to definitelyreal/speakfree on GitHub.

**Architecture:** Swift macOS menu bar app. whisper-cli binary + dylibs bundled inside the .app so no Homebrew is required. A model picker panel shows on first launch (no model found), with base.en pre-selected. Help panel explains settings to non-technical users.

**Tech Stack:** Swift 5.9, AppKit, AVFoundation, whisper-cpp 1.8.3, install_name_tool for dylib rpath fixup.

---

## Task 1: Rename — all identifiers and display strings

**Files:**
- Modify: `Package.swift`
- Rename: `Sources/OpenWispr/` → `Sources/SpeakFree/`
- Modify: `Sources/OpenWisprLib/Config.swift`
- Modify: `Sources/OpenWisprLib/Permissions.swift`
- Modify: `Sources/OpenWisprLib/StatusBarController.swift`
- Modify: `Sources/OpenWisprLib/Version.swift`
- Modify: `Sources/SpeakFree/main.swift`
- Create: `speakfree.app/` (rename from `OpenWisprMod.app`)
- Modify: `speakfree.app/Contents/Info.plist`

**Step 1: Rename source directory**
```bash
mv "Sources/OpenWispr" "Sources/SpeakFree"
```

**Step 2: Update Package.swift**

Change the executable target name and path:
```swift
// Before:
.executableTarget(
    name: "open-wispr",
    dependencies: ["OpenWisprLib"],
    path: "Sources/OpenWispr"
)

// After:
.executableTarget(
    name: "speakfree",
    dependencies: ["OpenWisprLib"],
    path: "Sources/SpeakFree"
)
```

Also update the package name:
```swift
// Before:
let package = Package(name: "open-wispr", ...)

// After:
let package = Package(name: "speakfree", ...)
```

**Step 3: Update Version.swift**
```swift
// Before:
public enum OpenWispr {
    public static let version = "0.27.0"
}

// After:
public enum OpenWispr {
    public static let version = "1.0.0"
}
```
(Keep enum name `OpenWispr` — it's internal, not user-facing.)

**Step 4: Update Config.swift — config dir path**
```swift
// Before:
return home.appendingPathComponent(".config/open-wispr")

// After:
return home.appendingPathComponent(".config/speakfree")
```

**Step 5: Update Config.swift — defaults**
```swift
// Before:
public static let defaultConfig = Config(
    hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
    modelPath: nil,
    modelSize: "base.en",
    language: "en",
    spokenPunctuation: .off,
    maxRecordings: nil,
    toggleMode: FlexBool(false)
)

// After:
public static let defaultConfig = Config(
    hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
    modelPath: nil,
    modelSize: "base.en",
    language: "en",
    spokenPunctuation: .hybrid,
    maxRecordings: 30,
    toggleMode: FlexBool(false)
)
```

**Step 6: Update Permissions.swift — bundle ID in tccutil call**
```swift
// Before:
process.arguments = ["reset", "Accessibility", "com.human37.open-wispr"]

// After:
process.arguments = ["reset", "Accessibility", "com.definitelyreal.speakfree"]
```

**Step 7: Update StatusBarController.swift — menu title**
```swift
// Before:
let titleItem = NSMenuItem(title: "openwisprmod v\(OpenWispr.version)", ...)

// After:
let titleItem = NSMenuItem(title: "speakfree v\(OpenWispr.version)", ...)
```

**Step 8: Update main.swift — all "open-wispr" references**

Replace every occurrence of `open-wispr` with `speakfree` in the usage strings, print statements, and command descriptions. The file is `Sources/SpeakFree/main.swift`.

**Step 9: Rename app bundle**
```bash
mv OpenWisprMod.app speakfree.app
```

**Step 10: Update Info.plist**

Edit `speakfree.app/Contents/Info.plist`:
- `CFBundleExecutable`: `speakfree`
- `CFBundleIdentifier`: `com.definitelyreal.speakfree`
- `CFBundleName`: `speakfree`
- `CFBundleDisplayName`: `speakfree`
- `CFBundleVersion`: `1.0.0`
- `CFBundleShortVersionString`: `1.0.0`
- `NSMicrophoneUsageDescription`: `speakfree needs microphone access to record your voice.`

**Step 11: Also copy Info.plist into source tree for version control**
```bash
cp speakfree.app/Contents/Info.plist Resources/Info.plist
```

**Step 12: Verify build**
```bash
swift package clean && swift build -c release 2>&1 | tail -5
```
Expected: `Build complete!` with binary at `.build/release/speakfree`

**Step 13: Commit**
```bash
git add -A
git commit -m "chore: rename to speakfree, update bundle ID and config dir"
```

---

## Task 2: Bundle whisper-cpp inside the app

**Goal:** whisper-cli binary + all its dylibs live inside the .app. No Homebrew required on the end user's machine.

**Files:**
- Create: `speakfree.app/Contents/Frameworks/` (dylibs)
- Modify: `speakfree.app/Contents/MacOS/whisper-cli` (binary, rpath fixed)
- Modify: `Sources/OpenWisprLib/Transcriber.swift`
- Create: `scripts/build.sh`

**Step 1: Identify the real binary path (not symlink)**
```bash
WHISPER_BIN=$(readlink -f /opt/homebrew/bin/whisper-cli)
WHISPER_LIB_DIR=$(dirname "$WHISPER_BIN")/../lib
echo "Binary: $WHISPER_BIN"
echo "Libs: $WHISPER_LIB_DIR"
ls "$WHISPER_LIB_DIR"/*.dylib
```

**Step 2: Copy binary and dylibs into bundle**
```bash
APP="speakfree.app"
mkdir -p "$APP/Contents/Frameworks"

# Copy the actual binary (not the symlink chain)
cp "$WHISPER_BIN" "$APP/Contents/MacOS/whisper-cli"

# Copy all versioned dylibs (non-symlinks)
for dylib in $(find "$WHISPER_LIB_DIR" -name "*.dylib" -not -L 2>/dev/null); do
    cp "$dylib" "$APP/Contents/Frameworks/"
done

ls -lh "$APP/Contents/Frameworks/"
```
Expected: 6 dylib files, ~2.3MB total.

**Step 3: Fix rpath on the bundled whisper-cli**

The binary uses @rpath to find its dylibs. Add an rpath pointing to our Frameworks dir:
```bash
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/whisper-cli"

# Verify:
otool -l "$APP/Contents/MacOS/whisper-cli" | grep -A2 RPATH
```
Expected: `path @executable_path/../Frameworks`

**Step 4: Update Transcriber.findWhisperBinary() to check bundle path first**

In `Sources/OpenWisprLib/Transcriber.swift`, update `findWhisperBinary()`:
```swift
public static func findWhisperBinary() -> String? {
    // Check bundle first — self-contained app, no Homebrew required
    if let bundlePath = Bundle.main.bundlePath as String? {
        let bundled = bundlePath + "/Contents/MacOS/whisper-cli"
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
    }

    let candidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp",
    ]
    // ... rest unchanged
```

**Step 5: Create scripts/build.sh — the canonical build + deploy script**
```bash
mkdir -p scripts
```

Create `scripts/build.sh` with content:
```bash
#!/bin/bash
set -e

APP="speakfree.app"
WHISPER_BIN=$(readlink -f /opt/homebrew/bin/whisper-cli)
WHISPER_LIB_DIR=$(dirname "$(readlink -f /opt/homebrew/bin/whisper-cli)")/../lib

echo "Building speakfree..."
swift build -c release

echo "Copying binary..."
cp .build/release/speakfree "$APP/Contents/MacOS/speakfree"

echo "Bundling whisper-cli..."
mkdir -p "$APP/Contents/Frameworks"
cp "$WHISPER_BIN" "$APP/Contents/MacOS/whisper-cli"
for dylib in $(find "$WHISPER_LIB_DIR" -maxdepth 1 -name "*.dylib" ! -type l 2>/dev/null); do
    cp "$dylib" "$APP/Contents/Frameworks/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/whisper-cli" 2>/dev/null || true

echo "Signing..."
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
```

Make it executable:
```bash
chmod +x scripts/build.sh
```

**Step 6: Run the build script to verify**
```bash
./scripts/build.sh
```
Expected: `Done: speakfree.app`

**Step 7: Test whisper-cli works from the bundle**
```bash
speakfree.app/Contents/MacOS/whisper-cli --help 2>&1 | head -3
```
Expected: whisper-cpp usage text (not "library not loaded" error)

**Step 8: Commit**
```bash
git add Sources/OpenWisprLib/Transcriber.swift scripts/build.sh
git commit -m "feat: bundle whisper-cli and dylibs inside app, add build.sh"
```

---

## Task 3: Model picker — first-launch window when no model found

**Goal:** When speakfree starts and no Whisper model is installed, show a native panel letting the user pick a model (base.en pre-selected) before downloading.

**Files:**
- Create: `Sources/OpenWisprLib/ModelPickerController.swift`
- Modify: `Sources/OpenWisprLib/AppDelegate.swift`

**Step 1: Create ModelPickerController.swift**

```swift
import AppKit
import Foundation

class ModelPickerController: NSWindowController {
    private var onComplete: ((String) -> Void)?
    private var selectedModel = "base.en"
    private var progressLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var downloadButton: NSButton!
    private var radioButtons: [NSButton] = []

    static func show(onComplete: @escaping (String) -> Void) {
        let controller = ModelPickerController()
        controller.onComplete = onComplete
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func loadWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 310),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Choose Whisper Model"
        panel.center()
        panel.isMovableByWindowBackground = true
        self.window = panel
        buildUI(in: panel)
    }

    private func buildUI(in panel: NSPanel) {
        let content = panel.contentView!

        let intro = NSTextField(wrappingLabelWithString:
            "speakfree needs a Whisper model to transcribe your voice. Choose one to download:")
        intro.font = NSFont.systemFont(ofSize: 13)
        intro.frame = NSRect(x: 20, y: 240, width: 380, height: 40)
        content.addSubview(intro)

        let models: [(id: String, label: String, detail: String)] = [
            ("tiny.en",   "tiny.en   — 75 MB",   "Fastest, good for quick notes"),
            ("base.en",   "base.en  — 142 MB",   "Recommended — fast and accurate"),
            ("small.en",  "small.en  — 466 MB",  "More accurate, slightly slower"),
            ("medium.en", "medium.en — 1.5 GB",  "High accuracy"),
            ("large",     "large      — 3 GB",   "Best accuracy (M1 Pro or better recommended)"),
        ]

        var y: CGFloat = 205
        for (id, label, detail) in models {
            let radio = NSButton(radioButtonWithTitle: label, target: self, action: #selector(modelSelected(_:)))
            radio.frame = NSRect(x: 24, y: y, width: 220, height: 18)
            radio.tag = radioButtons.count
            radio.state = id == "base.en" ? .on : .off
            content.addSubview(radio)
            radioButtons.append(radio)

            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = NSFont.systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.frame = NSRect(x: 248, y: y, width: 155, height: 18)
            content.addSubview(detailLabel)

            y -= 28
        }

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = NSFont.systemFont(ofSize: 12)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: 20, y: 48, width: 280, height: 16)
        content.addSubview(progressLabel)

        progressBar = NSProgressIndicator()
        progressBar.frame = NSRect(x: 20, y: 28, width: 380, height: 12)
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.isHidden = true
        content.addSubview(progressBar)

        downloadButton = NSButton(title: "Download", target: self, action: #selector(downloadTapped))
        downloadButton.bezelStyle = .rounded
        downloadButton.keyEquivalent = "\r"
        downloadButton.frame = NSRect(x: 310, y: 18, width: 90, height: 28)
        content.addSubview(downloadButton)
    }

    @objc private func modelSelected(_ sender: NSButton) {
        let models = ["tiny.en", "base.en", "small.en", "medium.en", "large"]
        selectedModel = models[sender.tag]
    }

    @objc private func downloadTapped() {
        downloadButton.isEnabled = false
        radioButtons.forEach { $0.isEnabled = false }
        progressBar.isHidden = false
        progressBar.startAnimation(nil)
        progressLabel.stringValue = "Downloading \(selectedModel) model..."

        let model = selectedModel
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ModelDownloader.download(modelSize: model)
                DispatchQueue.main.async {
                    self.progressBar.stopAnimation(nil)
                    self.progressBar.isHidden = true
                    self.progressLabel.stringValue = "Download complete."
                    self.close()
                    self.onComplete?(model)
                }
            } catch {
                DispatchQueue.main.async {
                    self.progressBar.stopAnimation(nil)
                    self.progressBar.isHidden = true
                    self.progressLabel.stringValue = "Error: \(error.localizedDescription)"
                    self.downloadButton.isEnabled = true
                    self.radioButtons.forEach { $0.isEnabled = true }
                }
            }
        }
    }
}
```

**Step 2: Update AppDelegate.setupInner() to show picker instead of auto-downloading**

In `Sources/OpenWisprLib/AppDelegate.swift`, replace the block that downloads the model automatically:

```swift
// BEFORE (around line 105):
if !Transcriber.modelExists(modelSize: config.modelSize) {
    DispatchQueue.main.async {
        self.statusBar.state = .downloading
        self.statusBar.updateDownloadProgress("Downloading \(self.config.modelSize) model...")
    }
    print("Downloading \(config.modelSize) model...")
    try ModelDownloader.download(modelSize: config.modelSize)
    DispatchQueue.main.async {
        self.statusBar.updateDownloadProgress(nil)
    }
}

// AFTER:
if !Transcriber.modelExists(modelSize: config.modelSize) {
    // Show model picker on main thread, then continue setup on background thread
    let semaphore = DispatchSemaphore(value: 0)
    var chosenModel = config.modelSize
    DispatchQueue.main.async {
        ModelPickerController.show { selected in
            // Save user's choice to config
            var updatedConfig = Config.load()
            updatedConfig.modelSize = selected
            try? updatedConfig.save()
            chosenModel = selected
            semaphore.signal()
        }
    }
    semaphore.wait()
    // Reload config with the chosen model
    config = Config.load()
    transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
    transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)
}
```

**Step 3: Build and verify the picker appears**
```bash
./scripts/build.sh
```
Then launch `speakfree.app`. If no model exists for the configured size, the picker should appear. If a model exists, skip.

To test without an installed model, temporarily rename the model file:
```bash
mv ~/.config/speakfree/models/ggml-base.en.bin ~/.config/speakfree/models/ggml-base.en.bin.bak
open speakfree.app
# Verify picker appears with base.en selected
# Click Download, verify progress shows, verify picker closes and app becomes Ready
mv ~/.config/speakfree/models/ggml-base.en.bin.bak ~/.config/speakfree/models/ggml-base.en.bin
```

**Step 4: Commit**
```bash
git add Sources/OpenWisprLib/ModelPickerController.swift Sources/OpenWisprLib/AppDelegate.swift
git commit -m "feat: add model picker panel shown on first launch"
```

---

## Task 4: Help window

**Goal:** A "Help" menu item opens a native panel explaining models, punctuation, hotkey, privacy, and crash recovery in plain language for non-technical users.

**Files:**
- Create: `Sources/OpenWisprLib/HelpController.swift`
- Modify: `Sources/OpenWisprLib/StatusBarController.swift`

**Step 1: Create HelpController.swift**

```swift
import AppKit

class HelpController: NSWindowController {
    private static var shared: HelpController?

    static func show() {
        if shared == nil { shared = HelpController() }
        shared?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    override func loadWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "speakfree Help"
        panel.minSize = NSSize(width: 380, height: 400)
        panel.center()
        self.window = panel

        let scrollView = NSScrollView(frame: panel.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textStorage?.setAttributedString(helpContent())

        scrollView.documentView = textView
        panel.contentView!.addSubview(scrollView)

        // Size text view to content
        textView.sizeToFit()
        let height = max(textView.frame.height + 40, 580)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: height)
    }

    private func helpContent() -> NSAttributedString {
        let result = NSMutableAttributedString()

        func heading(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
            ]
            result.append(NSAttributedString(string: "\n\(text)\n", attributes: attrs))
        }

        func body(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
            result.append(NSAttributedString(string: "\(text)\n\n", attributes: attrs))
        }

        func item(_ label: String, _ detail: String) {
            let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            result.append(NSAttributedString(string: "  \(label)", attributes: bold))
            result.append(NSAttributedString(string: " — \(detail)\n", attributes: normal))
        }

        heading("Models")
        body("Larger models are more accurate but take longer to transcribe. Choose in Settings → Model.")
        item("tiny.en",   "75 MB. Fastest. Good for quick notes and short phrases.")
        item("base.en",   "142 MB. Recommended for most people. Fast and accurate.")
        item("small.en",  "466 MB. Better accuracy for technical terms and long dictation.")
        item("medium.en", "1.5 GB. High accuracy. Noticeably slower.")
        item("large",     "3 GB. Best accuracy. Recommended only for M1 Pro or better.")
        result.append(NSAttributedString(string: "\n", attributes: [:]))

        heading("Punctuation")
        body("Choose in Settings → Punctuation.")
        item("Off",            "Whisper adds punctuation automatically based on speech patterns.")
        item("Hybrid",         "Whisper adds punctuation, plus you can say words like \"comma\" or \"period\" to add them explicitly. Recommended.")
        item("Spoken words",   "Whisper's auto-punctuation is off. All punctuation must be spoken explicitly.")
        result.append(NSAttributedString(string: "\n", attributes: [:]))

        heading("Hotkey")
        body("Hold the Globe key (🌐, bottom-left of keyboard), speak, then release. Your words are typed at the cursor.\n\nTo change the key: Settings → Hotkey. Options include Globe, Left/Right Command, Left/Right Option, Left Control.")
        result.append(NSAttributedString(string: "\n", attributes: [:]))

        heading("Privacy")
        body("speakfree runs entirely on your Mac. Your voice never leaves your computer — there are no servers, no accounts, and no internet connection required after the model is downloaded.\n\nAudio is transcribed locally by the Whisper model and then deleted. If you enable Recent Dictations in Settings → Max Recordings, those recordings are stored only on your machine.")

        heading("\"Recover Unsaved Recording\"")
        body("If speakfree quit unexpectedly while recording, it can try to transcribe the recording the next time it launches. Click \"Recover Unsaved Recording\" in the Recent Dictations menu to do this.")

        return result
    }
}
```

**Step 2: Add Help menu item to StatusBarController.buildMenu()**

In `Sources/OpenWisprLib/StatusBarController.swift`, before the Quit item:
```swift
// Before Quit:
menu.addItem(NSMenuItem.separator())

let helpTarget = MenuItemTarget { HelpController.show() }
menuItemTargets.append(helpTarget)
let helpItem = NSMenuItem(title: "Help", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
helpItem.target = helpTarget
menu.addItem(helpItem)

menu.addItem(NSMenuItem.separator())
menu.addItem(NSMenuItem(title: "Quit", ...))
```

**Step 3: Build and test**
```bash
./scripts/build.sh && open speakfree.app
```
Click Help in the menu. Verify window opens with all 5 sections, text is readable, window closes normally.

**Step 4: Commit**
```bash
git add Sources/OpenWisprLib/HelpController.swift Sources/OpenWisprLib/StatusBarController.swift
git commit -m "feat: add Help window with model, punctuation, hotkey, privacy docs"
```

---

## Task 5: Update logo.svg

**Goal:** Replace the current logo with a dissolving waveform — five bars that fade from solid to transparent left-to-right — representing audio that disappears locally.

**Files:**
- Modify: `logo.svg`

**Step 1: Update logo.svg**

Replace the contents of `logo.svg` with this dissolving waveform:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80" width="80" height="80">
  <!-- Dissolving waveform: bars fade right to left, representing ephemeral local audio -->
  <rect x="8"  y="28" width="8" height="24" rx="4" fill="#000" opacity="1.0"/>
  <rect x="22" y="20" width="8" height="40" rx="4" fill="#000" opacity="0.75"/>
  <rect x="36" y="14" width="8" height="52" rx="4" fill="#000" opacity="0.5"/>
  <rect x="50" y="20" width="8" height="40" rx="4" fill="#000" opacity="0.3"/>
  <rect x="64" y="28" width="8" height="24" rx="4" fill="#000" opacity="0.1"/>
</svg>
```

**Step 2: Verify it looks right**

Open `logo.svg` in Safari or Preview. Should show 5 bars fading from black to near-invisible left-to-right.

**Step 3: Commit**
```bash
git add logo.svg
git commit -m "design: update logo to dissolving waveform"
```

---

## Task 6: Update LICENSE

**Files:**
- Modify: `LICENSE`

**Step 1: Add copyright line**

Add your copyright above human37's existing line:
```
MIT License

Copyright (c) 2026 definitelyreal
Copyright (c) 2026 human37

Permission is hereby granted...
```
(The rest of the license text stays identical.)

**Step 2: Commit**
```bash
git add LICENSE
git commit -m "chore: add copyright to LICENSE"
```

---

## Task 7: Rewrite README for non-technical users

**Files:**
- Modify: `README.md`

**Step 1: Replace README.md content**

The new README should:
- Lead with one sentence: what speakfree does
- Show Install section first: download, unzip, drag to Applications, right-click → Open
- No Homebrew, no terminal, no config file editing
- Keep model comparison table (simplified)
- Privacy section
- Settings section pointing to the in-app Settings menu
- Credit to open-wispr and human37 at the bottom

Content outline:
```markdown
# speakfree

Hold a key, speak, release — your words appear wherever your cursor is. All on your Mac, no internet, no account.

## Install

1. Download the latest [speakfree.zip](releases) and unzip it
2. Drag speakfree.app to your Applications folder
3. Open it — right-click → Open on the first launch (macOS security step)
4. Grant Microphone and Accessibility permissions when prompted
5. The first launch downloads the Whisper model (~142 MB)

The 🌐 icon appears in your menu bar when speakfree is running.

## Usage

Hold the **Globe key** (🌐, bottom-left of your keyboard), speak, then release.
Your words are typed at the cursor.

No text field focused? The transcription is copied to your clipboard instead.

## Settings

Click the menu bar icon → Settings to change:
- **Hotkey** — Globe, Command, Option, or Control
- **Model** — larger models are more accurate but slower
- **Punctuation** — Hybrid mode (default) adds punctuation automatically and also lets you say "comma", "period", etc.

For detailed explanations, click **Help** in the menu.

## Privacy

Everything runs on your Mac. No audio or text ever leaves your computer.
No account. No subscription. No internet after the first model download.

## Models

| Model | Size | Speed | Best for |
|---|---|---|---|
| tiny.en | 75 MB | Fastest | Quick notes |
| **base.en** | **142 MB** | **Fast** | **Most people (default)** |
| small.en | 466 MB | Moderate | Technical terms, longer dictation |
| medium.en | 1.5 GB | Slower | High accuracy |
| large | 3 GB | Slowest | Maximum accuracy (M1 Pro+ recommended) |

## Credits

Forked from [open-wispr](https://github.com/human37/open-wispr) by human37. MIT license.

## License

MIT
```

**Step 2: Commit**
```bash
git add README.md
git commit -m "docs: rewrite README for non-technical users"
```

---

## Task 8: Create GitHub repo and push

**Step 1: Initialize remote on GitHub**

Go to github.com/definitelyreal and create a new repo named `speakfree`:
- Public
- No README (we have one)
- No .gitignore (we have one)
- License: MIT (already in repo)

```bash
gh repo create definitelyreal/speakfree --public --source=. --remote=origin --push
```

Or if the remote needs to be set manually:
```bash
git remote set-url origin https://github.com/definitelyreal/speakfree.git
git push -u origin main
```

**Step 2: Create the first release with the app zip**

Build the distributable:
```bash
./scripts/build.sh
cd ..
zip -r speakfree-1.0.0.zip openwisprmod/speakfree.app
```

Create a GitHub release:
```bash
gh release create v1.0.0 speakfree-1.0.0.zip \
  --title "speakfree 1.0.0" \
  --notes "First public release. Local, private voice dictation for macOS. Hold a key, speak, release. No internet. No account. Drag-to-Applications install."
```

**Step 3: Verify**

Open `https://github.com/definitelyreal/speakfree` — confirm README renders correctly, release is visible with the zip attached.

---

## Final Verification Checklist

Before declaring done, verify each of these manually:

- [ ] App launches without errors from `speakfree.app` (not from terminal)
- [ ] Bundle ID is `com.definitelyreal.speakfree` (check in System Settings → Privacy after granting permissions)
- [ ] Config writes to `~/.config/speakfree/config.json` (not `~/.config/open-wispr/`)
- [ ] whisper-cli works from bundle: `speakfree.app/Contents/MacOS/whisper-cli --help`
- [ ] Model picker appears when model file is absent; base.en is pre-selected
- [ ] Model picker downloads a model and the app becomes Ready afterward
- [ ] Help window opens from menu, all 5 sections visible
- [ ] Default new install uses base.en and hybrid punctuation
- [ ] Logo.svg renders correctly in browser
- [ ] GitHub repo is public and README is readable
- [ ] Release zip is attached and downloadable
