# Vendored whisper.cpp + ggml binaries

These dylibs are pinned at a known-good combination:

- `libwhisper.1.8.3.dylib` — whisper.cpp 1.8.3
- `libggml*.0.9.5.dylib` — ggml 0.9.5 (matches what whisper 1.8.3 was built against)
- `whisper-cli` — companion CLI built against the same pair

## Why pin instead of building from brew?

Building against `/opt/homebrew/lib` ties the build to whatever versions brew
has installed at the moment. As of late April 2026, brew shipped:

- `whisper-cpp` 1.8.4 (was built against `ggml` 0.9.8)
- `ggml` 0.10.0 (ABI break from 0.9.x)

That pair installs together cleanly but ggml-aborts at model load. A speakfree
build that links against brew silently produces a binary that crashes on the
first dictation.

Pinning means the build no longer cares what brew is doing, and we keep a
provably-working set of binaries until a newer compatible pair lands.

## How these were captured

Extracted from the GitHub release v1.2.10 DMG (April 22, 2026) — at that point
brew had `whisper-cpp` 1.8.3 + `ggml` 0.9.5 and the build worked. After brew
updated to 1.8.4 + 0.10.0, dictation broke. Restoring the v1.2.10 bundle and
extracting these dylibs gives us the original working set.

## Bumping the pinned version

When a future brew `whisper-cpp` + `ggml` pair is mutually compatible:

1. Verify by building speakfree against brew, dictating, confirming no crash
2. Copy the post-build `*.dylib` files from `Speakfree.app/Contents/Frameworks/`
   and `whisper-cli` from `Speakfree.app/Contents/MacOS/` into this directory
3. Update this README with the new versions
4. Commit
