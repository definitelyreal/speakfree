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

### SPM Integration

Use the official whisper.spm package or vendor whisper.cpp source directly.

Option A: Add `https://github.com/ggerganov/whisper.spm` as SPM dependency.
- Pro: maintained upstream, Metal support included
- Con: build from source every time, large dependency

Option B: Vendor a prebuilt XCFramework.
- Pro: fast builds, controlled version
- Con: manual updates

Option C: Keep bundling the whisper-cli binary but also link the library.
- Pro: gradual migration, fallback
- Con: two code paths

**Recommendation: Option A** with whisper.spm. Clean integration, Metal is automatic,
matches the existing SPM build system. If build times are bad, switch to XCFramework later.

### Audio Pipeline Change

Currently AudioRecorder writes to a WAV file, then Transcriber reads it back.
With the library, we can feed PCM samples directly:

```swift
// AudioRecorder accumulates Float32 samples in a buffer
// On stop, return the buffer instead of a file URL
func stopRecording() -> (url: URL, samples: [Float])?
```

Keep writing the WAV file too (for recordings history) but pass the samples buffer
directly to WhisperEngine. Eliminates the WAV→read→decode round trip.

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

### Option-Delete Intermittent

This is likely caused by the accessibility trust being in a transitional state after
tccutil resets. The fix from the `didUpgrade()` path correction should prevent
most occurrences. If it persists, it's an ad-hoc signing limitation — Developer ID
signing would resolve it permanently.

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
