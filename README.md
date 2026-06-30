<p align="center">
  <img src="logo.png" width="100" alt="speakfree logo">
</p>

<h1 align="center">speakfree</h1>

<p align="center">
  Hold a key, speak, release — your words appear at the cursor.<br>
  100% local. No internet. No account. Free forever.
</p>

<p align="center">
  <strong>🌐 Website &amp; downloads: <a href="https://definitelyreal.github.io/speakfree/">definitelyreal.github.io/speakfree</a></strong>
</p>

<p align="center">
  <a href="https://github.com/definitelyreal/speakfree/releases/latest"><img src="https://img.shields.io/github/v/release/definitelyreal/speakfree?label=download&style=flat-square" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT">
</p>

---

## Install

1. Download **[speakfree.dmg](https://github.com/definitelyreal/speakfree/releases/latest)** and open it
2. Drag **speakfree.app** to your Applications folder
3. Open it — **right-click → Open** on the first launch (macOS security step, required once)
4. Grant **Microphone** and **Accessibility** permissions when prompted
5. On first launch, a window appears to download the speech model — **NVIDIA Parakeet (English)** by default, ~600 MB one-time

The speakfree icon appears in your menu bar when it's running.

> **Requires macOS 14 or later.** Older releases ran on macOS 13, but this version moves the minimum up to 14. If you're on macOS 13, the last release that supports you is the previous one — you won't receive updates past it.

## Usage

**Hold** the Globe key (🌐, bottom-left of keyboard), **speak**, then **release**.

Your words are typed wherever your cursor is. If no text field is focused, the transcription is copied to your clipboard instead.

## Settings

Click the menu bar icon → **Settings** to change everything in-app:

| Setting | Options |
|---|---|
| **Hotkey** | Globe 🌐, Left/Right Command ⌘, Left/Right Option ⌥, Left Control ⌃ |
| **Engine & model** | Parakeet English (default), or any Whisper size (see below) |
| **Punctuation** | Hybrid (default), Off, Spoken words |
| **Key Mode** | Hold (default), Toggle |
| **Past Recordings** | Keep everything (default), or cap at the last 10–100 |

Click **Help** in the menu for plain-English explanations of every setting.

## Transcription engines

speakfree can transcribe with one of two local engines. Both run entirely on your Mac — no audio or text ever leaves your computer.

| Engine | Parakeet (default) | Whisper |
|---|---|---|
| Maker | NVIDIA | OpenAI (via whisper.cpp) |
| Runs on | Apple Neural Engine | CPU / Metal GPU |
| Speed & accuracy | Higher | Good |
| Live preview | No — text appears when you release | Yes — words appear as you speak |
| Download | ~600 MB, one-time | 75 MB – 3 GB (see Models) |
| Requires | macOS 14+ | macOS 14+ |

**Parakeet** is the default: NVIDIA's speech model running on the Apple Neural Engine — faster and more accurate than Whisper for English. The default model is the English-only variant (`parakeet-tdt-0.6b-v2`); choosing a non-English language switches to the multilingual variant (v3). Parakeet does **not** show a live preview — your text appears all at once when you release the key.

**Whisper** is the alternative if you want a live preview of your words as you speak, or a smaller download — it offers a range of model sizes (see [Models](#models)).

Switch engines in **Settings**. Models download automatically the first time you select them.

## Models

These are the **Whisper** model sizes, for when you switch off the default Parakeet engine. Larger models are more accurate but take longer to transcribe. (Parakeet uses a single ~600 MB model — see [Transcription engines](#transcription-engines).)

| Model | Size | Speed | Best for |
|---|---|---|---|
| tiny.en | 75 MB | Fastest | Quick notes, short phrases |
| base.en | 142 MB | Fast | Small download, decent accuracy |
| small.en | 466 MB | Moderate | Technical terms, longer dictation |
| medium.en | 1.5 GB | Slower | High accuracy |
| **large-v3-turbo** | **1.5 GB** | **Fast** | **Whisper default — best accuracy/speed balance** |
| large | 3 GB | Slowest | Best accuracy (M1 Pro+ recommended) |

Switching models downloads automatically if needed.

## Privacy

speakfree runs entirely on your Mac.

- No audio or text ever leaves your computer
- No servers, no accounts, no subscriptions
- Internet is only needed once — to download a model on first launch (Parakeet by default, or a Whisper model if you switch engines)
- Audio is transcribed locally. Recordings are kept on your Mac (`~/.config/speakfree/recordings`) so you can review past dictations — cap or delete them anytime in Settings

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

Parakeet speech recognition powered by [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0) via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).

## License

MIT — see [LICENSE](LICENSE)

The Parakeet engine pulls in third-party components under their own licenses: the FluidAudio SDK (Apache-2.0) and the NVIDIA Parakeet model weights (CC-BY-4.0). Attribution for both is in [Credits](#credits).
