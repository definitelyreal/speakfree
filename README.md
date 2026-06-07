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
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14+">
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

> **Requires macOS 14 or later.** Older releases ran on macOS 13, but this version moves the minimum up to 14. If you're on macOS 13, the last release that supports you is the previous one — you won't receive updates past it.

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

## Transcription engines

speakfree can transcribe with one of two local engines. Both run entirely on your Mac — no audio or text ever leaves your computer.

| Engine | Whisper (default) | Parakeet |
|---|---|---|
| Maker | OpenAI (via whisper.cpp) | NVIDIA |
| Runs on | CPU / Metal GPU | Apple Neural Engine |
| Speed & accuracy | Good | Higher |
| Live preview | Yes — words appear as you speak | No — text appears when you release |
| Download | 75 MB – 3 GB (see Models) | ~600 MB, one-time |
| Requires | macOS 14+ | macOS 14+ |

**Whisper** is the default and works for most people. It shows a live preview of your words as you speak, and offers a range of model sizes (see [Models](#models)).

**Parakeet** is NVIDIA's speech model, running on the Apple Neural Engine. It's faster and more accurate than Whisper, at the cost of a one-time ~600 MB download. It does **not** show a live preview — your text appears all at once when you release the key.

Switch engines in **Settings**. The Parakeet model downloads automatically the first time you select it.

## Models

These are the **Whisper** model sizes. Larger models are more accurate but take longer to transcribe. (Parakeet uses a single ~600 MB model — see [Transcription engines](#transcription-engines).)

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
- Internet is only needed once — to download a model on first launch (a Whisper model, or Parakeet if you switch engines)
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

Parakeet speech recognition powered by [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0) via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).

## License

MIT — see [LICENSE](LICENSE)

The Parakeet engine pulls in third-party components under their own licenses: the FluidAudio SDK (Apache-2.0) and the NVIDIA Parakeet model weights (CC-BY-4.0). Attribution for both is in [Credits](#credits).
