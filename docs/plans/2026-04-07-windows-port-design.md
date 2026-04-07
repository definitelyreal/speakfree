# Windows Port Design

## Summary

A full-featured Windows port of speakfree (OpenWispr): hold a hotkey → record audio → transcribe locally via whisper.cpp → type text at cursor. Full feature parity with the Mac app. Separate codebase — no shared code with the Swift/AppKit implementation.

## Goals

- Full feature parity with Mac app v1.2.7
- 100% local, no internet required for transcription
- Self-contained `.exe` (no .NET runtime required on end-user machines)
- Automated build + test loop via Azure cloud VM

## Non-Goals

- Cross-platform shared codebase (Mac stays Swift/AppKit)
- Auto-update in v1 (can add Velopack later)
- Mac UI parity pixel-for-pixel

---

## Tech Stack

| Layer | Choice | Rationale |
|---|---|---|
| Language | C# / .NET 8 | Native Windows APIs, `whisper.net` NuGet, dotnet cross-compile |
| UI framework | WPF | Modern styling, XAML, good for settings + overlay windows |
| System tray | `Hardcodet.Wpf.TaskbarNotification` | De facto WPF tray library |
| Global hotkey | `RegisterHotKey` Win32 P/Invoke | Low-level, reliable, same approach as all major Windows apps |
| Audio capture | NAudio (WASAPI) | Mature, wraps Windows audio APIs cleanly |
| Transcription | `Whisper.net` NuGet | Wraps whisper.cpp, cross-platform, actively maintained |
| Text insertion | `SendInput` Win32 P/Invoke | Same mechanism as AutoHotkey; clipboard fallback |
| Settings storage | `appsettings.json` via `System.Text.Json` | Simple, portable |
| Launch at login | HKCU registry run key | Standard Windows approach |

---

## Component Map (Mac → Windows)

| Mac (Swift) | Windows (C#) |
|---|---|
| `AppDelegate.swift` | `App.xaml.cs` |
| `StatusBarController.swift` | `TrayController.cs` |
| `HotkeyManager.swift` | `HotkeyManager.cs` |
| `AudioRecorder.swift` | `AudioRecorder.cs` |
| `WhisperEngine.swift` | `WhisperEngine.cs` |
| `ModelDownloader.swift` | `ModelDownloader.cs` |
| `ModelDownloadController.swift` | `ModelDownloadWindow.xaml` |
| `TextInserter.swift` | `TextInserter.cs` |
| `TextPostProcessor.swift` | `TextPostProcessor.cs` |
| `SettingsWindow.swift` | `SettingsWindow.xaml` |
| `RecordingOverlay.swift` | `RecordingOverlay.xaml` |
| `HelpController.swift` | `HelpWindow.xaml` |
| `LaunchAtLogin.swift` | `LaunchAtLogin.cs` |
| `DiagnosticLogger.swift` | `DiagnosticLogger.cs` |
| `WordMemory.swift` | `WordMemory.cs` |
| `UsageStats.swift` | `UsageStats.cs` |
| `Config.swift` | `AppSettings.cs` |

---

## Project Structure

```
windows/
  OpenWispr.Windows.sln
  OpenWispr.Windows/
    OpenWispr.Windows.csproj   (.NET 8, WPF, win-x64)
    App.xaml / App.xaml.cs
    Audio/
      AudioRecorder.cs          NAudio WASAPI capture
    Hotkey/
      HotkeyManager.cs          RegisterHotKey P/Invoke
      KeyCodes.cs               VK code constants
    Transcription/
      WhisperEngine.cs          Whisper.net wrapper
      ModelDownloader.cs        HttpClient + progress
    TextInsertion/
      TextInserter.cs           SendInput P/Invoke, clipboard fallback
    PostProcessing/
      TextPostProcessor.cs      Punctuation, capitalization
    Settings/
      AppSettings.cs            JSON persistence
      SettingsWindow.xaml
    Tray/
      TrayController.cs         NotifyIcon, context menu
    UI/
      RecordingOverlay.xaml     Transparent topmost overlay
      ModelDownloadWindow.xaml
      HelpWindow.xaml
    System/
      LaunchAtLogin.cs          Registry run key
      DiagnosticLogger.cs       File logging
      WordMemory.cs             Learned vocabulary
      UsageStats.cs
  OpenWispr.Windows.Tests/
    OpenWispr.Windows.Tests.csproj   (xUnit)
    AudioRecorderTests.cs
    TextPostProcessorTests.cs
    WhisperEngineTests.cs
    TextInserterTests.cs
    AppSettingsTests.cs
```

---

## Core Data Flow

```
[User holds hotkey]
    HotkeyManager detects WM_HOTKEY
    → RecordingOverlay.Show()
    → AudioRecorder.Start() via WASAPI

[User releases hotkey]
    → AudioRecorder.Stop() → flush PCM → temp .wav
    → RecordingOverlay.Hide()
    → WhisperEngine.Transcribe(wavPath) → raw string
    → TextPostProcessor.Process(raw) → cleaned string
    → TextInserter.Type(text)  [SendInput; clipboard fallback]
    → delete temp .wav

[Error at any stage]
    → DiagnosticLogger.Log(ex)
    → TrayController.ShowNotification("Transcription failed")
    → return to idle — never crash
```

---

## Settings (full parity with Mac)

| Setting | Options |
|---|---|
| Hotkey | Right Ctrl (Globe equivalent), Left/Right Shift, Left/Right Alt, Left/Right Ctrl, custom |
| Model | tiny.en → large |
| Punctuation | Hybrid, Off, Spoken words |
| Key mode | Hold (default), Toggle |
| Max recordings | Off, 10–100 |
| Launch at login | On/Off |
| Language | Auto, English, + all Whisper languages |

---

## Development & Testing Infrastructure

### Azure VM

- **Subscription:** Azure for Students (`cacbeedb-1af1-4bf6-807d-3f636b8bf44b`)
- **VM spec:** `Standard_D2s_v3` (2 vCPU, 8 GB RAM), Windows Server 2022
- **Region:** `westus2`
- **Tools installed:** .NET 8 SDK, Git, OpenSSH

### Dev Loop

```
[Mac] write C# → git push
[VM via SSH] git pull && dotnet build && dotnet test
Results stream back to Mac terminal
```

### Test Strategy

| Layer | Method |
|---|---|
| Logic (audio, transcription, text processing, settings) | xUnit unit tests, run via SSH |
| App startup / tray registration | SSH + PowerShell process inspection |
| UI smoke (overlay, settings window) | RDP screenshot saved to build/ |
| End-to-end (hotkey → type) | Automated SendKeys → Notepad screenshot |

### Cost

~$0.10/hr while running. VM deallocated between sessions.

---

## Out of Scope for v1

- Auto-update (Velopack) — add post-launch
- Code signing / installer (.msi) — manual install for now
- Screen context reading — Mac-only feature
- Correction monitor — can add post-launch

---

_Claude · 2026-04-07 · Windows port design_
