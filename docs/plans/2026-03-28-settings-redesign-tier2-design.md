# Settings Redesign + Tier 2 (Library Integration) Design

## Original Intent

Michael tested the v2 beta and found the settings panel feels non-native with too much space,
the language/model interaction is buggy (auto-detect silently fails when multilingual model
isn't downloaded), and wants the full Tier 2 experience: whisper.cpp as an in-process library
with smart model loading/unloading, plus a polished settings UI.

## Settings Panel Redesign

### Layout

Native macOS feel: compact, checkbox-oriented, descriptions as secondary text below controls.
No 120px label column — labels are part of the row, not aligned in a separate column.

```
┌─ speakfree Settings ─────────────────────────────────────┐
│                                                           │
│  GENERAL                                                  │
│  ☑ Launch at Login                                        │
│  Hotkey  [🌐 Globe / fn ▾] [Other…]  ( Hold ● | Toggle ) │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│  TRANSCRIPTION                                            │
│  Language   [English ▾]                                   │
│  Choose from 99 languages or Auto-detect (less            │
│  reliable for short dictation).                           │
│                                                           │
│  Model      [small.en ▾]  ~800 MB, ~0.6s on your Mac    │
│  Larger models are more accurate but use more memory.     │
│  Model downloads automatically when selected.             │
│                                                           │
│  Punctuation  ( Automatic ● | Spoken | Both )             │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│  CORRECTIONS & CONTEXT                                    │
│  ☑ Learn From My Corrections                   [Reset]   │
│  When you fix a transcribed word, speakfree remembers     │
│  it and primes the model next time.                       │
│                                                           │
│  ☑ Use Screen Context                                     │
│  Reads text on your screen via local OCR to help the      │
│  model match names and technical terms.                   │
│                                                           │
│  [Edit Vocabulary File…]                                  │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│  PERFORMANCE                                              │
│  Keep model loaded   ( Always | 2 min | 5 min ● | 10 min)│
│  Memory: ~800 MB when loaded                              │
│  Status: Loaded / Unloaded (loads on first dictation)     │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│  STORAGE                                                  │
│  Past Recordings   [30 ▾]                                 │
│  Recent dictations appear in the menu bar.                │
│  Set to Off to delete recordings after transcription.     │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Key Recorder

"Other..." button opens a small sheet overlaid on the settings window:

```
┌──────────────────────────────────────┐
│  Press a key or combination...       │
│                                      │
│  Waiting for input...                │
│                                      │
│           [Cancel]                   │
└──────────────────────────────────────┘
```

Captures the next keypress (with any held modifiers). Displays it as e.g. "⌥ F5" or "⌃⇧ K".
Escape cancels. Uses NSEvent.addLocalMonitorForEvents(matching: .keyDown).

### Language Dropdown

Standard NSPopUpButton-style picker (SwiftUI Picker with .menu style). Not a text field with
popover — those break easily (command-a, selection, focus issues).

- Shows "English" by default
- "Auto-detect" at the top of the list, separated by a divider
- All 99 languages listed alphabetically below
- When language changes to non-English or Auto-detect:
  - Check if the multilingual model variant exists on disk
  - If yes: switch silently
  - If no: show the model download dialog, then switch
  - If download fails: fall back to English, show error

### Model Picker

- Options filter based on language:
  - Language = English → show only .en models
  - Language = anything else or Auto-detect → show only multilingual models
- Show "Recommended" tag next to the model recommended for this Mac's RAM
- Show memory + speed next to each option
- When selecting a model not yet downloaded: show the download dialog

### Model Download Dialog

Modal, not closeable (no close button). Shows on startup if model missing, and when user
selects a new model in settings.

```
┌─ Downloading Model ──────────────────────────────┐
│                                                    │
│  Downloading small.en (466 MB)...                  │
│                                                    │
│  ████████████░░░░░░░░░░░░░  47%                   │
│                                                    │
│  This model will be used for transcription.        │
│  Larger models are more accurate but slower.       │
│                                                    │
└────────────────────────────────────────────────────┘
```

Uses NSPanel with no close button in styleMask. Progress bar driven by curl's output
or URLSession download task with progress delegate.

### Model Fallback Logic

When the effective model (after language→multilingual conversion) is not on disk:

1. Check if ANY model is on disk → use it as temporary fallback
2. Start downloading the required model in background
3. Show the download dialog
4. When download completes, switch to the correct model
5. If no model exists at all, block on the download dialog (current behavior)

### RAM-Based Recommendations

On first launch (and in settings), detect RAM and show recommendations:

```swift
let ram = ProcessInfo.processInfo.physicalMemory
// 8GB = base, 16GB = small, 32GB+ = small (suggest medium)
```

Show "Recommended for your Mac" in the model picker dropdown, e.g.:
```
  tiny.en       ~230 MB, ~0.6s
  base.en       ~330 MB, ~0.6s
▸ small.en      ~800 MB, ~0.6s  — Recommended
  medium.en     ~2.1 GB, ~1.3s
  large-v3      ~3.9 GB, ~2.1s
```

Speed/memory values from the benchmark results file if it exists, otherwise use estimates
based on model size ratios.

### Punctuation Rename

- "Off" → "Automatic" (Whisper adds punctuation based on speech patterns)
- "Spoken words" → "Spoken" (you say "comma" to get a comma)
- "Hybrid" → "Both" (automatic + you can say punctuation words)

---

## Tier 2: whisper.cpp Library Integration

### Architecture

Replace CLI subprocess with in-process whisper.cpp C library calls.

```
BEFORE:
  [Record WAV] → [spawn whisper-cli process] → [parse stdout] → [insert text]
                   ↑ loads model from disk every time (~0.5s overhead)

AFTER:
  [Record PCM buffer] → [WhisperEngine.transcribe(samples)] → [insert text]
                          ↑ model stays resident in memory
                          ↑ no process spawn, no file I/O
```

### WhisperEngine

New class wrapping the whisper.cpp C API:

```swift
class WhisperEngine {
    private var context: OpaquePointer?   // whisper_context*
    private var modelPath: String?
    private var idleTimer: Timer?
    private var idleTimeout: TimeInterval = 300  // 5 min default

    // State
    var isLoaded: Bool { context != nil }
    var loadedModelPath: String? { isLoaded ? modelPath : nil }

    // Lifecycle
    func loadModel(path: String) throws
    func unloadModel()

    // Transcription — takes PCM Float32 samples at 16kHz mono
    func transcribe(
        samples: [Float],
        language: String,
        prompt: String?,
        suppressRegex: String?,
        onProgress: ((Float) -> Void)?
    ) throws -> String

    // Smart loading
    func resetIdleTimer()
    func handleMemoryPressure()
}
```

### SPM Integration (Implemented)

**Chose Option C:** CWhisper system module linking against Homebrew-installed dylibs.

Neither whisper.spm nor SwiftWhisper include Metal GPU acceleration in their SPM builds
(Metal is commented out). The Homebrew whisper-cpp installation includes Metal via
libggml-metal.dylib, which is already bundled in the app.

Implementation:
- `Sources/CWhisper/include/` contains whisper.h + ggml headers copied from Homebrew
- `Sources/CWhisper/include/module.modulemap` exposes the C API as `import CWhisper`
- Package.swift links against `/opt/homebrew/lib/libwhisper` with rpath to `@executable_path/../Frameworks`
- App bundle includes all dylibs in `Contents/Frameworks/` (libwhisper, libggml-*, including Metal)
- CLI fallback via whisper-cli subprocess remains as a degradation path

### Audio Pipeline: Single-Engine with Pre-Roll Buffer

A single AVAudioEngine runs continuously from app launch with one tap that operates
in two modes:

**Pre-roll mode (idle):** The tap fills a 500ms circular buffer (8000 samples at 16kHz).
This captures audio from before fn is pressed, so the first word is never lost.

**Recording mode:** When fn is pressed, `startRecording()` drains the pre-roll buffer,
prepends it to the PCM samples and WAV file, then flips `isRecording = true`. The same
tap starts writing to the file and accumulating samples. No engine restart, no gap.

When recording stops, the flag flips back and the tap resumes filling the pre-roll buffer.

```
[Engine always running]
    ↓
[Pre-roll mode: circular buffer of last 500ms]
    ↓ fn pressed
[Drain pre-roll → prepend to recording]
    ↓
[Recording mode: write to file + accumulate PCM]
    ↓ fn released
[Back to pre-roll mode]
```

This design means:
- **Zero-gap recording** — no engine creation delay between fn press and first captured sample
- **Pre-captured speech** — the 500ms before fn was pressed is included
- **Single tap** — no risk of two taps on the same input node
- **WAV file still written** — for recordings history and CLI fallback
- **PCM samples available** — passed directly to WhisperEngine (no file round-trip)

The microphone indicator (orange dot) is always on while the app runs, which is expected
for a dictation app.

### Smart Model Loading

- **Load on first transcription** (not app launch) — zero memory cost when idle
- **Keep loaded** between transcriptions for fast subsequent use
- **Idle timeout** (configurable: Always, 2min, 5min, 10min):
  - Start timer after each transcription completes
  - On timer fire: unload model
  - On next transcription: reload (pay the one-time cost)
  - "Always" = no timer, model stays loaded until app quits
- **Memory pressure**: Register for `ProcessInfo` memory warnings.
  On pressure: unload regardless of timer.
- **Default timeout by RAM**:
  - ≤16GB: 2 min
  - 32GB: 5 min
  - 64GB+: 10 min
- **Status display in settings**: "Loaded (807 MB)" / "Unloaded"

### Transcriber Refactor

`Transcriber` becomes a facade that delegates to either WhisperEngine (preferred)
or falls back to CLI subprocess:

```swift
class Transcriber {
    private let engine: WhisperEngine
    private let modelSize: String
    private let language: String

    func transcribe(audioURL: URL, samples: [Float]?, prompt: String?) throws -> String {
        // If engine can be used (model loaded or loadable):
        //   Feed samples directly to engine
        // Else:
        //   Fall back to CLI subprocess (existing code)
    }
}
```

This allows gradual migration and graceful degradation.

---

## System Accessibility Architecture

speakfree requires two macOS permissions: **Microphone** and **Accessibility**.

### Why Accessibility Is Needed

- **CGEventTap** (HotkeyManager) — intercepts fn key globally to start/stop recording.
  Requires accessibility to create a `.cgSessionEventTap` with `.defaultTap` option.
- **AXUIElement** (TextInserter) — inserts transcribed text at the cursor via
  `kAXSelectedTextAttribute`. Falls back to clipboard paste if AX isn't available.
- **AXUIElement** (AppDelegate) — reads text before cursor for context prompt,
  captures focused element for refocusing after transcription.
- **AXUIElement** (CorrectionMonitor) — monitors text field for word corrections.
- **AXUIElement** (ScreenContext) — captures active window for OCR.

### Permission Flow (AppDelegate.setupInner)

```
1. Config.load()
2. VocabularyMigration.runIfNeeded()  — one-time cleanup dialog
3. Permissions.ensureMicrophone()     — AVCaptureDevice.requestAccess
4. Permissions.didUpgrade()           — checks .last-version file
   → If upgrade detected: resetAccessibility() via tccutil reset
     (clears stale TCC entry so macOS re-prompts with correct binary)
5. AXIsProcessTrusted()               — check if already granted
   → If not: set statusBar.state = .waitingForPermission
     → Show lock icon in menu bar with clickable "Grant Permission" item
     → Permissions.promptAccessibility() — triggers macOS prompt
     → Poll AXIsProcessTrusted() every 0.5s until granted
   → If yes: proceed to startListening()
```

### Upgrade Detection (Permissions.didUpgrade)

When the app binary changes (new version), macOS invalidates the TCC accessibility
trust because the code signature changed. The old entry is stale — still visible in
System Settings but non-functional. `tccutil reset` removes it so macOS prompts fresh.

```swift
// Read previous version from ~/.config/speakfree/.last-version
// Write current version
// If previous != current → upgrade detected → return true
// If no previous file → first launch → return false
// Beta builds (.beta bundle ID) → always return false (skip entirely)
```

### Config Directory Isolation

Production and beta use separate config directories to prevent interference:

- Production: `~/.config/speakfree/` (bundle ID: `com.definitelyreal.speakfree`)
- Beta: `~/.config/speakfree-beta/` (bundle ID: `com.definitelyreal.speakfree.beta`)

This prevents:
- Beta's `tccutil reset` from revoking production's accessibility
- Shared `.last-version` causing false upgrade detection
- Shared vocabulary/dictionary corruption between versions

### Known Gotchas

- **Ad-hoc signing:** Each rebuild changes the code identity. macOS creates a new TCC
  entry for each identity. Old entries become stale and can't be removed via UI.
  Solution: skip `tccutil reset` for beta builds.
- **tccutil reset scope:** Resets ALL entries for a bundle ID, not just the current one.
  Multiple stale entries can accumulate.
- **Two apps, one hotkey:** Running production and beta simultaneously causes hotkey
  conflicts — both intercept fn. Only run one at a time.
- **Accessibility polling:** The `while !AXIsProcessTrusted()` loop in setupInner blocks
  the background thread. The UI thread remains responsive (statusBar updates via
  DispatchQueue.main.async).

---

## Bug Fixes Included

### Language→Model Download Bug

When language is set to auto-detect or non-English, and the multilingual model isn't
downloaded, the app silently fails. Fix:

1. In AppDelegate, after computing effectiveModelSize, check if model exists
2. If not, check if the .en variant exists → use as fallback while downloading
3. Show the model download dialog for the multilingual variant
4. Switch to multilingual model when download completes

### Edit Vocabulary File Bug

The "Edit Vocabulary File..." button calls `NSWorkspace.shared.open(url)` but the file
may not exist in the beta config dir. Fix: create the file with template content before
opening, and ensure the directory exists.

### Option-Delete Broken System-Wide

Root cause: The CGEventTap callback returned `nil` when macOS disabled the tap
(tapDisabledByTimeout / tapDisabledByUserInput), which **dropped the event entirely**.
If an Option key flagsChanged event was dropped, the system lost track of the Option
modifier state, making Option-Delete act as plain Delete.

Fix: Return the event (`Unmanaged.passUnretained(event)`) instead of `nil` during
tap re-enable. One-line change in HotkeyManager.swift.

### Text Insertion Without Clipboard

Root cause: The original `TextInserter` saved the clipboard, wrote transcription text
to it, simulated ⌘V, then restored the clipboard after 1.5s. This overwrote clipboard
contents and was fragile.

Fix: Use the Accessibility API (`kAXSelectedTextAttribute`) to insert text directly
at the cursor without touching the clipboard. Falls back to the clipboard method if
the AX attribute isn't settable (some Electron apps, custom controls).

### Beta Accessibility Reset Loop

Root cause: `didUpgrade()` used a hardcoded config path and ran `tccutil reset` which
created stale TCC entries. Each rebuild of the ad-hoc signed beta changed the code
identity, causing a new TCC entry per launch while old ones couldn't be removed.

Fix: Skip upgrade detection entirely for `.beta` bundle IDs. Use `Config.configDir`
(not hardcoded path) for the version file. Use `Bundle.main.bundleIdentifier` for
tccutil reset calls.

### Auto-Learn Vocabulary Corruption

Root cause: `CorrectionMonitor` compared the full text field word-by-word at positional
index. Any typing after paste shifted positions and created false corrections like
`"a" → "about"`, `"the" → "a"`. These were injected into Whisper's prompt via
vocabulary.txt, confusing the model.

Fix: Added minimum word length (≥4 chars) and Levenshtein edit distance filter (<40%
of longer word) to `CorrectionMonitor.findSingleCorrection()`. Added one-time migration
(`VocabularyMigration`) that shows a dialog letting users review and clean garbage entries.

---

## Implementation Order

1. **WhisperEngine** — C library wrapper with load/transcribe/unload
2. **SPM integration** — Add whisper.spm dependency, verify Metal works
3. **AudioRecorder** — Return PCM buffer alongside WAV file
4. **Transcriber refactor** — Use WhisperEngine, fall back to CLI
5. **Smart loading** — Idle timer, memory pressure, config integration
6. **Model download dialog** — Modal, progress bar, blocks until done
7. **Model fallback logic** — Download missing models, use .en as fallback
8. **Settings redesign** — Rewrite SettingsView with new layout
9. **Key recorder** — "Other..." hotkey capture sheet
10. **RAM recommendation** — Detect RAM, show recommendation in model picker
11. **Language dropdown** — Proper picker, auto-download multilingual model
12. **Punctuation rename** — Automatic/Spoken/Both
13. **Fix Edit Vocabulary** — Create file before opening
14. **Performance section** — Idle timeout picker, status display

---

## Out of Scope

- Streaming transcription (Tier 3)
- CoreML model support (optimization, not required)
- VAD/silence trimming (Tier 3)
- Audio input device selection (Tier 3)
