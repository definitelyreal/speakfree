<p align="center">
  <img src="logo.png" width="100" alt="speakfree logo">
</p>

<h1 align="center">speakfree</h1>

<p align="center">
  Hold a key, speak, release — your words appear at the cursor.<br>
  100% local. No internet. No account. Free forever.
</p>

<p align="center">
  <a href="https://github.com/definitelyreal/speakfree/releases/latest"><img src="https://img.shields.io/github/v/release/definitelyreal/speakfree?label=download&style=flat-square" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT">
</p>

---

## Install

1. Download **[speakfree.zip](https://github.com/definitelyreal/speakfree/releases/latest)** and unzip it
2. Drag **speakfree.app** to your Applications folder
3. Open it — **right-click → Open** on the first launch (macOS security step, required once)
4. Grant **Microphone** and **Accessibility** permissions when prompted
5. On first launch, a window appears to choose and download a Whisper model (~142 MB for the default)

The speakfree icon appears in your menu bar when it's running.

## Usage

**Hold** the Globe key (🌐, bottom-left of keyboard), **speak**, then **release**.

Your words are typed wherever your cursor is. If no text field is focused, the transcription is copied to your clipboard instead.

## Settings

Click the menu bar icon → **Settings** to change everything in-app:

| Setting | Options |
|---|---|
| **Hotkey** | Globe 🌐, Left/Right Command ⌘, Left/Right Option ⌥, Left Control ⌃ |
| **Model** | tiny.en → large (see table below) |
| **Punctuation** | Hybrid (default), Off, Spoken words |
| **Key Mode** | Hold (default), Toggle |
| **Max Recordings** | Off (default), 10–100 |

Click **Help** in the menu for plain-English explanations of every setting.

## Models

Larger models are more accurate but take longer to transcribe.

| Model | Size | Speed | Best for |
|---|---|---|---|
| tiny.en | 75 MB | Fastest | Quick notes, short phrases |
| **base.en** | **142 MB** | **Fast** | **Most people (default)** |
| small.en | 466 MB | Moderate | Technical terms, longer dictation |
| medium.en | 1.5 GB | Slower | High accuracy |
| large | 3 GB | Slowest | Best accuracy (M1 Pro+ recommended) |

Switching models downloads automatically if needed.

## Privacy

speakfree runs entirely on your Mac.

- No audio or text ever leaves your computer
- No servers, no accounts, no subscriptions
- Internet is only needed once — to download the Whisper model on first launch
- Audio is transcribed locally and deleted immediately

## Build from source

```bash
git clone https://github.com/definitelyreal/speakfree.git
cd speakfree
brew install whisper-cpp
swift build -c release
open speakfree.app
```

## Credits

Forked from [open-wispr](https://github.com/human37/open-wispr) by [human37](https://github.com/human37). Powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

## License

MIT — see [LICENSE](LICENSE)
