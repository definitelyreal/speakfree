# speakfree — Release Design

**Date:** 2026-03-19
**Status:** Approved

## What We're Building

A public release of speakfree (forked from open-wispr) on the `definitelyreal` GitHub account. Target audience is non-technical Mac users — drag-to-Applications, zero terminal required.

## Name & Identity

- App name: **speakfree** (lowercase everywhere)
- Bundle ID: `com.definitelyreal.speakfree`
- Binary: `speakfree`
- GitHub: `definitelyreal/speakfree`
- Original credit: MIT license preserved with human37's copyright, new copyright added

## Distribution

Self-contained `.app` bundle — no Homebrew, no terminal required.

- `whisper-cpp` binary bundled inside `Contents/MacOS/` alongside the app binary
- `Transcriber` updated to look for bundled binary first, then fall back to system PATH
- Model downloaded on first launch (existing behavior, progress bar already works)
- Distributed as a zip on GitHub Releases

**Gatekeeper:** Users will need to right-click → Open on first launch (no Developer ID). Documented clearly in README.

## Defaults

- Model: `base.en` (better accuracy than tiny.en, fast on Apple Silicon)
- Punctuation: `hybrid` (whisper auto-punct + spoken word conversion)
- Hotkey: Globe key (🌐), hold to record
- Max recordings: 30

## Help Window

A native `NSPanel` opened from a "Help" menu item. Single scrollable view covering:

1. **Models** — tiny/base/small/medium/large with speed/accuracy tradeoff explained in plain English
2. **Punctuation modes** — Off / Hybrid / Spoken Words — what each does
3. **Hotkey** — how to change it, what the modifier symbols mean
4. **Privacy** — audio never leaves your machine, no accounts, no internet after model download
5. **Crash recovery** — what the "Recover recording" prompt means

Implemented as a simple `NSTextView` with attributed string or a minimal SwiftUI view. No web views.

## Logo

Dissolving waveform — a sound wave that starts solid on the left and gradually fades/dissolves to nothing on the right. Communicates that audio is ephemeral and stays private. Monochrome for menu bar, can add color for app icon.

Update `logo.svg` and the menu bar icon asset.

## README

Rewritten for non-technical audience:
- Lead with what it does in one sentence
- Drag-to-Applications install instructions with right-click → Open note
- No Homebrew, no config file editing, no terminal
- Screenshots of the menu bar and Settings submenu
- Model comparison table (plain English, no jargon)
- Privacy section
- Link back to original open-wispr

## Tasks

1. Rename — bundle ID, binary name, all string references
2. Bundle whisper-cpp — copy binary, update Transcriber lookup
3. Set defaults — base.en, hybrid
4. Help window — NSPanel with 5 sections
5. Logo — update logo.svg and menu bar icon
6. LICENSE — add copyright line
7. README — rewrite for non-technical audience
8. GitHub — create repo, push, create first release
