# speakfree — project instructions

## Replacing the installed app (MANDATORY)

**Always DELETE the existing `speakfree.app` before copying a new build in. Never copy over / replace it in place.**

Replacing the bundle in place leaves stale files and corrupts TCC (Microphone / Accessibility) permission state, so the rebuilt app can hang, lose its menu-bar icon, or silently fail to record.

Correct sequence when installing a fresh build to `/Applications` (or `~/Applications`):
1. Stop any running instance: `pkill -f "speakfree start"`
2. Delete the old bundle: move it to the Trash (`/usr/bin/trash /Applications/speakfree.app`), do not `cp` over it.
3. Copy the new bundle in: `cp -R speakfree.app /Applications/speakfree.app`

## Build / install for local testing

- Release build: `swift build -c release` (or `xcrun swift build -c release`).
- Bundle: `bash scripts/bundle-app.sh .build/release/speakfree speakfree.app dev` — this is the dev bundle; it links `libwhisper` from Homebrew (`/opt/homebrew/opt/whisper-cpp`), so it only runs on a machine with `whisper-cpp` installed. The signed release `.dmg` (via `scripts/build.sh`) bundles the dylib for distribution.
- The dev bundle is ad-hoc signed (version "dev"): first launch needs **right-click → Open**, and TCC permissions (Mic/Accessibility) may need re-granting after each rebuild.
- To run the CLI build directly: `export DYLD_FALLBACK_LIBRARY_PATH=$PWD/scripts/vendor/dylibs` then `./.build/debug/speakfree <cmd>`.

## Parakeet model download

- Default new-user engine is Parakeet English (`parakeet-tdt-0.6b-v2`); models cache at `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v{2,3}/`.
- The onboarding download modal (`WelcomeController`) is shown from `AppDelegate.setupInner`, which runs off-main. It MUST be presented via the main run loop (`CFRunLoopPerformBlock`), NOT `DispatchQueue.main.sync` — a modal launched from a main-queue dispatch block starves all other main-queue work, freezing the download UI at 0% and hanging the install. See [project_parakeet_download_progress](memory).

---
_Claude · 2026-06-27_
