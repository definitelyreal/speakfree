# speakfree v2 — Improvement Design

## Original Intent

Michael saw a tweet about Insanely Fast Whisper (GPU-accelerated Python transcription) and asked
if it could be integrated. After analysis, that specific tool isn't compatible (Python/CUDA vs
native Swift/Metal), but it sparked a broader conversation: what would make speakfree better
across speed, accuracy, and features?

Goals: make transcription faster, more accurate, support multiple languages, and clean up the
UI as the feature set grows. Memory efficiency matters — the app should work well on 16GB Macs,
not just 64GB machines.

## Benchmark Results (M3 Max, 64GB)

Tested on a 10-second speech clip. Each model was run 3 times (cold, warm, warm).

| Model | Disk | Peak RAM | Inference | Notes |
|-------|------|----------|-----------|-------|
| tiny.en | 74 MB | 232 MB | 0.58s | Too low quality for real use |
| base.en | 141 MB | 331 MB | 0.59s | Current default |
| small.en | 465 MB | 807 MB | 0.59s | Same speed as base, better accuracy |
| medium.en | 1.4 GB | 2.1 GB | ~1.3s | 2x slower, much more RAM |
| large-v3 | 2.9 GB | 3.9 GB | ~2.1s | Best accuracy, heavy |

Key finding: small.en matches base.en's speed at 800MB RAM. Sweet spot for quality/resource balance.

## Architecture Overview

### Current (CLI subprocess)
```
[Hotkey] → [Record audio] → [Save WAV] → [Spawn whisper-cli process] → [Parse stdout] → [Insert text]
                                              ↑ loads model every time
```

### Proposed (library integration)
```
[Hotkey] → [Record audio] → [Feed PCM buffer] → [whisper.cpp C library] → [Insert text]
                                                     ↑ model stays resident
                                                     ↑ unloads after idle timeout
```

## Design

### Tier 1: Quick Wins (current architecture)

#### 1.1 Default to small.en
Change default model from base.en to small.en. Same inference speed, better accuracy,
800MB is reasonable. Show memory cost per model in settings so users can make informed choices.

#### 1.2 Settings Window (SwiftUI)
Replace nested menu bar submenus with a proper settings window. SwiftUI hosted in NSWindow.
Single-page sectioned layout.

**Sections:**

```
GENERAL
  Hotkey             [🌐 Globe / fn      ▾]
  Key Mode           ( Hold ) (• Toggle )
  Launch at Login    [toggle]

TRANSCRIPTION
  Model              [small.en ▾]  800 MB, ~0.6s
  Language           [🔍 English          ×]
                     Auto-detect when empty
  Punctuation        [Hybrid ▾]

PERFORMANCE
  Keep model loaded  [toggle]
  Unload after       [5 min ▾]
  Status: Model loaded (807 MB)

VOCABULARY
  Auto-learn corrections [toggle]
  [word list with delete buttons]
  [Edit File...] [Reset All]

PRIVACY & STORAGE
  Screen Context     [toggle]
  Max Recordings     [30 ▾]
```

**Menu bar simplifies to:**
- speakfree v{version}
- Status (Ready / Recording / Transcribing)
- Recent Dictations submenu
- Settings... (⌘,)
- Check for Updates...
- Help
- Quit (⌘Q)

#### 1.3 Language Support
- Add language picker: autocomplete text field searching 99 Whisper-supported languages
- Static array of (displayName, whisperCode) tuples
- Empty/cleared field = auto-detect (passes `-l auto` to whisper)
- When auto-detect or non-English language is selected, automatically switch to multilingual
  model variant (e.g. small.en → small)
- Show note: "Auto-detect requires multilingual model" with one-click switch

#### 1.4 Pass Optimization Flags
Pass `-t <thread_count>` to whisper-cli based on available CPU cores.
Consider passing `--no-prints` to reduce stderr noise.

#### 1.5 Launch at Login
Add SMAppService-based launch-at-login toggle (macOS 13+).

### Tier 2: Architectural Refactor

#### 2.1 whisper.cpp Library Integration
Replace CLI subprocess with direct C library calls. This is the single biggest improvement.

**What changes:**
- Add whisper.cpp as a Swift Package dependency (C library, not CLI)
- New `WhisperEngine` class manages model lifecycle:
  - `loadModel(path:)` — loads GGML model into memory
  - `transcribe(samples:prompt:language:) -> String` — runs inference on PCM float array
  - `unloadModel()` — frees model memory
- `Transcriber` becomes a thin wrapper around `WhisperEngine`
- Audio pipeline feeds PCM samples directly instead of writing to WAV file

**Benefits:**
- Eliminates ~0.5-1s model reload per transcription
- Eliminates process spawn overhead
- Eliminates WAV file I/O (can feed PCM buffer directly)
- Enables streaming transcription (Tier 3)
- Enables accurate memory reporting via whisper API

#### 2.2 Smart Model Loading
- Load model on first transcription (not app launch — no memory cost when idle)
- Keep model resident in memory between transcriptions
- Configurable idle timeout (default: 5 minutes). Unload model after timeout.
- Respect macOS memory pressure notifications (NSProcessInfo). If system is under pressure,
  unload proactively even before timeout.
- Show current state in settings: "Model loaded (807 MB)" / "Model unloaded"
- On 16GB Macs, default to shorter timeout (2 min). On 32GB+, longer (10 min).

**Memory pressure handling:**
```swift
ProcessInfo.processInfo.beginActivity(options: .background, reason: "Whisper model loaded")
// Register for NSProcessInfo memory warnings
// On warning: unload model, reload on next transcription
```

#### 2.3 Auto-Recommend Model Based on RAM
On first launch (or when no model is downloaded), recommend a model:
- 8GB Mac: base.en (331 MB resident)
- 16GB Mac: small.en (807 MB resident)
- 32GB+ Mac: small.en default, medium.en suggested
- Show recommendation in model picker: "small.en — Recommended for your Mac"

#### 2.4 VAD (Voice Activity Detection)
Trim silence from start/end of recording before sending to Whisper.
whisper.cpp has built-in VAD support, or we can use a simple energy-based detector.
Reduces inference time on clips with long pauses at start/end.

### Tier 3: New Capabilities

#### 3.1 Streaming Transcription
Text appears as you speak, not after you stop. whisper.cpp supports this via
`whisper_full_parallel()` or chunked processing.

**UX:** Text streams into a floating overlay near the cursor. When you release the hotkey,
final text is inserted. Corrections from the final pass replace any streaming artifacts.

This is the most complex feature and depends on Tier 2 (library integration) being complete.

#### 3.2 Audio Input Selection
Let user pick which microphone to use (built-in, AirPods, external USB mic).
Currently defaults to system default input. Add picker in settings showing available
audio input devices by name.

#### 3.3 Multi-Language Auto-Detect
When language is set to auto-detect:
- Use multilingual model
- Pass `-l auto` to whisper
- For very short clips (<3s), fall back to configured preferred language
  since auto-detection is unreliable on minimal audio
- Show detected language briefly in menu bar status: "Transcribed (Spanish)"

## Memory Budget

Target: speakfree should never use more than ~5% of total system RAM when idle (model unloaded),
and no more than ~10% when model is loaded on the smallest supported machine (16GB).

| Machine | Idle | Model loaded (small.en) | During inference |
|---------|------|------------------------|-----------------|
| 16GB | ~30 MB | ~837 MB (5.2%) | ~1.0 GB (6.3%) |
| 32GB | ~30 MB | ~837 MB (2.6%) | ~1.0 GB (3.1%) |
| 64GB | ~30 MB | ~837 MB (1.3%) | ~1.0 GB (1.6%) |

## Testing Strategy

### Memory Leak Testing
- Use Instruments (Leaks + Allocations) on the app during repeated transcription cycles
- Automated test: transcribe 100 times in a loop, assert RSS stays within bounds
- Specifically test model load/unload cycles — load, transcribe, unload, repeat 50 times
- Test memory pressure response: simulate pressure, verify model unloads

### Performance Testing
- Benchmark script (already built) for model comparison
- Automated regression test: transcribe reference audio, assert time < threshold
- Test cold start vs warm start latency

## Out of Scope
- LLM post-processing (grammar/formatting via local LLM)
- Command mode ("delete last sentence", "select all", etc.)
- Cloud/API-based transcription
- iOS/iPadOS port
