# Contributing

Thanks for your interest in contributing to open-wispr.

## Getting started

1. Fork the repo and clone it
2. Run the dev script:
   ```bash
   bash scripts/dev.sh
   ```

The dev script handles everything you need to build and run from source:

1. **Configure** -- prompts you to pick a Whisper model size (tiny through medium, English-only or multilingual), language, spoken punctuation, and hotkey. Press enter on any prompt to keep the current value from `~/.config/open-wispr/config.json`.
2. **Clean up** -- stops any running open-wispr instances and removes the Homebrew-installed version (if present) so it doesn't conflict with your local build. Installs `whisper-cpp` via Homebrew if needed.
3. **Build** -- runs `swift build -c release` from source.
4. **Bundle** -- packages the binary into a macOS app bundle (`OpenWispr.app`) and copies it to `~/Applications/` so macOS properly recognizes it for accessibility and microphone permissions.
5. **Start** -- launches the app directly so you can test immediately.

## Project structure

```
Sources/OpenWisprLib/
├── AppDelegate.swift       # App lifecycle, hotkey listener, menu bar
├── AudioRecorder.swift     # Microphone recording
├── Config.swift            # Config loading/saving (~/.config/open-wispr/config.json)
├── HotkeyManager.swift     # Global hotkey detection via CGEvent taps
├── KeyCodes.swift          # Key name/code mapping and parsing
├── ModelDownloader.swift   # Whisper model download from HuggingFace
├── Permissions.swift       # Microphone and accessibility permission checks
├── RecordingStore.swift    # Recording history and pruning
├── StatusBarController.swift # Menu bar UI
├── TextInserter.swift      # Pastes transcribed text at cursor
├── TextPostProcessor.swift # Spoken punctuation replacement
├── Transcriber.swift       # Whisper CLI wrapper
└── Version.swift           # Version constant
Sources/OpenWispr/
└── main.swift              # CLI entry point
scripts/
├── dev.sh                  # Build & run from source
├── install.sh              # Guided installer
├── uninstall.sh            # Clean removal
├── deploy.sh               # Release automation
├── bundle-app.sh           # Create macOS .app bundle
├── test-install.sh         # Install smoke tests
└── test-transcription.sh   # Transcription integration tests
```

## Tests

All changes should include applicable tests. The test suite has two layers:

### Unit tests

Location: `Tests/OpenWisprTests/`

Pure logic tests with no external dependencies. Run with:

```bash
swift test
```

| File | What it covers |
|---|---|
| `ConfigTests.swift` | Config decoding, `effectiveMaxRecordings` clamping, `FlexBool` parsing, `HotkeyConfig` modifier flags |
| `RecordingStoreTests.swift` | Recording file creation, listing, sorting, pruning, deletion |
| `TextPostProcessorTests.swift` | Spoken punctuation replacement, spacing fixes, edge cases |
| `KeyCodesTests.swift` | Key name/code mapping, `parse()`, `describe()`, round-trip consistency |

When adding new logic to `OpenWisprLib`, add unit tests here. Good candidates for unit tests are pure functions, data transformations, parsing, and anything that doesn't require hardware (microphone, display, accessibility).

### Integration tests

Location: `scripts/test-install.sh` and `scripts/test-transcription.sh`

These test the built binary and external dependencies. They run in CI but you can also run them locally:

```bash
# Install smoke test -- builds from source, tests CLI commands, bundles app, runs shellcheck
bash scripts/test-install.sh

# Transcription test -- requires whisper-cpp and downloads the tiny.en model (~75 MB)
bash scripts/test-transcription.sh
```

**Install smoke test** (`test-install.sh`):
- Builds from source and verifies the binary
- Tests all CLI commands (`--help`, `status`, `get-hotkey`, `set-hotkey`, `set-model`)
- Validates error handling for invalid inputs
- Bundles the app and checks the `.app` structure
- Runs shellcheck on all shell scripts

**Transcription test** (`test-transcription.sh`):
- Generates test audio using macOS `say` + `afconvert`
- Runs whisper-cpp on the generated audio
- Verifies transcription output contains expected words
- Tests the binary's whisper-cpp detection

### CI

CI runs automatically on pull requests via GitHub Actions (`.github/workflows/ci.yml`). Four jobs run in parallel:

1. **build** -- `swift build -c release` (skipped if no Swift files changed)
2. **unit-tests** -- `swift test` (skipped if no Swift files changed)
3. **install-test** -- builds binary, tests CLI, bundles app, shellcheck
4. **transcription-test** -- installs whisper-cpp, builds, runs transcription tests

### Adding tests

- **New pure logic** (parsing, transformations, config handling) -- add a unit test in `Tests/OpenWisprTests/`
- **New CLI commands** -- add assertions to `scripts/test-install.sh`
- **Changes to transcription pipeline** -- add cases to `scripts/test-transcription.sh`
- **New shell scripts** -- add the script path to the shellcheck list in `test-install.sh`

## Making changes

1. Create a branch off `main`
2. Make your changes
3. Run the tests:
   ```bash
   swift test
   bash scripts/test-install.sh
   ```
4. Test locally with `bash scripts/dev.sh`
5. Open a pull request against `main`

## What to work on

Check the [open issues](https://github.com/human37/open-wispr/issues) for bugs and feature requests. If you want to work on something not listed, open an issue first to discuss it.

## Guidelines

- Keep it simple. open-wispr is intentionally minimal.
- No cloud dependencies. Everything must run on-device.
- Test on Apple Silicon. Intel Macs are not supported.
- Match the existing code style.
- Include tests for any new or changed logic.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
