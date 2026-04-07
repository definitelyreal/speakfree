# Windows Port Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Build a full-featured Windows port of speakfree (OpenWispr) — hold a hotkey, speak, release, text appears at cursor — using C# / .NET 8 / WPF with automated build + test via Azure cloud VM.

**Architecture:** Separate C# codebase in `windows/` folder. WPF app with system tray icon, no main window on startup. All Windows-specific APIs (hotkey, audio, text insertion) wrapped in testable service classes. Unit tests run on Mac via SSH; Windows-specific integration tests run on the Azure VM.

**Tech Stack:** .NET 8 / WPF, NAudio (WASAPI audio), Whisper.net (whisper.cpp wrapper), Hardcodet.Wpf.TaskbarNotification (system tray), xUnit (tests), Azure Standard_B2s VM (2 vCPU / 4 GB, ~$0.04/hr)

---

## Task 1: Provision Azure Windows VM

**Files:**
- Create: `scripts/provision-vm.sh`

**Step 1: Create resource group and VM**

```bash
az group create --name openwisprmod-win --location westus2

# Generate and save a secure password
VM_PASS="Owm$(openssl rand -base64 12 | tr -d '/+=' | head -c 14)Aa1!"
echo "$VM_PASS" > ~/.openwisprmod-vm-pass
chmod 600 ~/.openwisprmod-vm-pass
echo "Password saved to ~/.openwisprmod-vm-pass"

az vm create \
  --resource-group openwisprmod-win \
  --name owm-build \
  --image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest \
  --size Standard_B2s \
  --admin-username owmadmin \
  --admin-password "$VM_PASS" \
  --public-ip-sku Standard \
  --output json
```

Expected output: JSON with `publicIpAddress` field. Save that IP.

**Step 2: Open SSH port**

```bash
az vm open-port --resource-group openwisprmod-win --name owm-build --port 22
```

**Step 3: Install OpenSSH Server on the VM**

```bash
az vm run-command invoke \
  --resource-group openwisprmod-win \
  --name owm-build \
  --command-id RunPowerShellScript \
  --scripts "
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic
    New-ItemProperty -Path 'HKLM:\\SOFTWARE\\OpenSSH' -Name DefaultShell \
      -Value 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' \
      -PropertyType String -Force
  "
```

**Step 4: Install .NET 8 SDK and Git**

```bash
az vm run-command invoke \
  --resource-group openwisprmod-win \
  --name owm-build \
  --command-id RunPowerShellScript \
  --scripts "
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Install Chocolatey
    Set-ExecutionPolicy Bypass -Scope Process -Force
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    # Install tools
    choco install dotnet-sdk -y --version 8.0.0
    choco install git -y
    refreshenv
  "
```

**Step 5: Test SSH connection**

```bash
VM_IP=$(az vm show -d -g openwisprmod-win -n owm-build --query publicIps -o tsv)
echo "VM IP: $VM_IP"
ssh owmadmin@$VM_IP "dotnet --version && git --version"
```

Expected: `8.0.x` and `git version 2.x`

**Step 6: Save VM IP to scripts**

```bash
echo "VM_IP=$VM_IP" > scripts/vm-env.sh
```

**Step 7: Commit**

```bash
git add scripts/
git commit -m "chore: add Azure VM provisioning scripts"
```

---

## Task 2: Scaffold C# WPF Solution

**Files:**
- Create: `windows/OpenWispr.Windows.sln`
- Create: `windows/OpenWispr.Windows/OpenWispr.Windows.csproj`
- Create: `windows/OpenWispr.Windows.Tests/OpenWispr.Windows.Tests.csproj`
- Create: `windows/.gitignore`

**Step 1: Create solution and projects on the VM**

SSH into the VM, then:

```powershell
cd C:\Users\owmadmin
git clone https://github.com/definitelyreal/speakfree.git openwisprmod
cd openwisprmod

mkdir windows
cd windows

dotnet new sln -n OpenWispr.Windows
dotnet new wpf -n OpenWispr.Windows -f net8.0-windows
dotnet new xunit -n OpenWispr.Windows.Tests -f net8.0-windows
dotnet sln add OpenWispr.Windows/OpenWispr.Windows.csproj
dotnet sln add OpenWispr.Windows.Tests/OpenWispr.Windows.Tests.csproj
```

**Step 2: Add NuGet dependencies**

```powershell
cd OpenWispr.Windows
dotnet add package NAudio --version 2.2.1
dotnet add package Whisper.net --version 1.7.4
dotnet add package Whisper.net.Runtime --version 1.7.4
dotnet add package Hardcodet.Wpf.TaskbarNotification --version 2.0.0
dotnet add package Microsoft.Extensions.DependencyInjection --version 8.0.0

cd ../OpenWispr.Windows.Tests
dotnet add reference ../OpenWispr.Windows/OpenWispr.Windows.csproj
dotnet add package Moq --version 4.20.69
dotnet add package FluentAssertions --version 6.12.0
```

**Step 3: Edit `OpenWispr.Windows.csproj` to set app type**

Replace the default `<OutputType>WinExe</OutputType>` and ensure:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <Nullable>enable</Nullable>
    <UseWPF>true</UseWPF>
    <ApplicationIcon>Resources\app.ico</ApplicationIcon>
    <AssemblyName>OpenWispr</AssemblyName>
    <RootNamespace>OpenWispr.Windows</RootNamespace>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
  </PropertyGroup>
</Project>
```

**Step 4: Create placeholder Resources folder and .gitignore**

```powershell
mkdir OpenWispr.Windows\Resources
echo "# placeholder" > OpenWispr.Windows\Resources\.keep

@"
bin/
obj/
*.user
.vs/
"@ | Out-File -FilePath .gitignore -Encoding utf8
```

**Step 5: Verify build**

```powershell
dotnet build windows/
```

Expected: `Build succeeded. 0 Error(s)`

**Step 6: Push from VM, pull on Mac to verify**

```powershell
# On VM
git add windows/
git commit -m "feat: scaffold C# WPF solution with test project"
git push
```

```bash
# On Mac
git pull
ls windows/
```

**Step 7: Commit** (already done in Step 6)

---

## Task 3: Dev Loop Script

**Files:**
- Create: `scripts/dev-loop.sh`

**Step 1: Write the script**

```bash
#!/bin/bash
# scripts/dev-loop.sh
# Usage: ./scripts/dev-loop.sh [test-filter]
# Push code, SSH to VM, pull and run tests.

set -e
source "$(dirname "$0")/vm-env.sh"

echo "==> Pushing to git..."
git push

echo "==> Building and testing on Windows VM ($VM_IP)..."
ssh owmadmin@$VM_IP "
  cd C:\\Users\\owmadmin\\openwisprmod
  git pull
  dotnet build windows/ --nologo -q
  dotnet test windows/ --nologo ${1:+--filter \"$1\"}
"

echo "==> Done."
```

**Step 2: Make executable**

```bash
chmod +x scripts/dev-loop.sh
```

**Step 3: Smoke-test it**

```bash
./scripts/dev-loop.sh
```

Expected: build succeeds, xUnit reports 0 tests found (no tests yet).

**Step 4: Commit**

```bash
git add scripts/dev-loop.sh
git commit -m "chore: add dev loop script (push → SSH → build → test)"
```

---

## Task 4: AppSettings

Port of `Config.swift`. JSON persistence to `%APPDATA%\OpenWispr\config.json`.

**Files:**
- Create: `windows/OpenWispr.Windows/Settings/AppSettings.cs`
- Create: `windows/OpenWispr.Windows/Settings/PunctuationMode.cs`
- Create: `windows/OpenWispr.Windows/Settings/HotkeyConfig.cs`
- Create: `windows/OpenWispr.Windows.Tests/Settings/AppSettingsTests.cs`

**Step 1: Write the failing tests**

```csharp
// windows/OpenWispr.Windows.Tests/Settings/AppSettingsTests.cs
using System.Text.Json;
using FluentAssertions;
using OpenWispr.Windows.Settings;
using Xunit;

public class AppSettingsTests
{
    [Fact]
    public void Default_settings_have_expected_values()
    {
        var s = AppSettings.Default;
        s.ModelSize.Should().Be("base.en");
        s.Language.Should().Be("en");
        s.Punctuation.Should().Be(PunctuationMode.Hybrid);
        s.ToggleMode.Should().BeFalse();
        s.MaxRecordings.Should().Be(30);
        s.LaunchAtLogin.Should().BeFalse();
    }

    [Fact]
    public void Settings_round_trip_through_json()
    {
        var original = AppSettings.Default with { ModelSize = "small.en", Language = "auto" };
        var json = JsonSerializer.Serialize(original);
        var restored = JsonSerializer.Deserialize<AppSettings>(json)!;
        restored.ModelSize.Should().Be("small.en");
        restored.Language.Should().Be("auto");
    }

    [Fact]
    public void Load_returns_default_when_file_missing()
    {
        var tempPath = Path.GetTempFileName();
        File.Delete(tempPath);
        var s = AppSettings.Load(tempPath);
        s.ModelSize.Should().Be(AppSettings.Default.ModelSize);
    }

    [Fact]
    public void Save_and_load_round_trip()
    {
        var tempPath = Path.GetTempFileName();
        try
        {
            var original = AppSettings.Default with { ModelSize = "tiny.en", MaxRecordings = 50 };
            original.Save(tempPath);
            var loaded = AppSettings.Load(tempPath);
            loaded.ModelSize.Should().Be("tiny.en");
            loaded.MaxRecordings.Should().Be(50);
        }
        finally { File.Delete(tempPath); }
    }
}
```

**Step 2: Run test — expect compile failure**

```bash
./scripts/dev-loop.sh "AppSettingsTests"
```

Expected: Build error — `AppSettings` not found.

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/Settings/PunctuationMode.cs
namespace OpenWispr.Windows.Settings;
public enum PunctuationMode { Off, Spoken, Hybrid }
```

```csharp
// windows/OpenWispr.Windows/Settings/HotkeyConfig.cs
namespace OpenWispr.Windows.Settings;
public record HotkeyConfig(int VirtualKey = 0xA3 /* VK_RCONTROL */, int Modifiers = 0);
```

```csharp
// windows/OpenWispr.Windows/Settings/AppSettings.cs
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenWispr.Windows.Settings;

public record AppSettings
{
    public HotkeyConfig Hotkey { get; init; } = new();
    public string? ModelPath { get; init; }
    public string ModelSize { get; init; } = "base.en";
    public string Language { get; init; } = "en";
    public PunctuationMode Punctuation { get; init; } = PunctuationMode.Hybrid;
    public bool ToggleMode { get; init; } = false;
    public int MaxRecordings { get; init; } = 30;
    public bool LaunchAtLogin { get; init; } = false;
    public bool DiagnosticLogging { get; init; } = false;
    public bool StreamingEnabled { get; init; } = true;

    public static AppSettings Default => new();

    public static string DefaultConfigPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "OpenWispr", "config.json");

    public static string DefaultModelsPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "OpenWispr", "models");

    private static readonly JsonSerializerOptions _json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        PropertyNameCaseInsensitive = true,
    };

    public static AppSettings Load(string? path = null)
    {
        path ??= DefaultConfigPath;
        if (!File.Exists(path)) return Default;
        try
        {
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<AppSettings>(json, _json) ?? Default;
        }
        catch
        {
            // Back up corrupted file
            if (File.Exists(path))
                File.Copy(path, path + ".bak", overwrite: true);
            return Default;
        }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultConfigPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, _json));
    }
}
```

**Step 4: Run tests — expect pass**

```bash
./scripts/dev-loop.sh "AppSettingsTests"
```

Expected: `4 passed`

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): AppSettings with JSON persistence"
```

---

## Task 5: TextPostProcessor

Direct C# port of `Sources/OpenWisprLib/TextPostProcessor.swift`. All logic is pure — no platform dependencies. Tests run on Mac via SSH.

**Files:**
- Create: `windows/OpenWispr.Windows/PostProcessing/TextPostProcessor.cs`
- Create: `windows/OpenWispr.Windows.Tests/PostProcessing/TextPostProcessorTests.cs`

**Step 1: Write failing tests**

```csharp
// windows/OpenWispr.Windows.Tests/PostProcessing/TextPostProcessorTests.cs
using FluentAssertions;
using OpenWispr.Windows.PostProcessing;
using Xunit;

public class TextPostProcessorTests
{
    // --- Unambiguous replacements ---
    [Theory]
    [InlineData("hello question mark", "hello?")]
    [InlineData("hello exclamation mark", "hello!")]
    [InlineData("hello exclamation point", "hello!")]
    [InlineData("hello semicolon world", "hello; world")]
    [InlineData("hello full stop", "hello.")]
    [InlineData("open quote hello close quote", "\"hello\"")]
    [InlineData("open paren hello close paren", "(hello)")]
    [InlineData("hello new line world", "hello\nworld")]
    [InlineData("hello newline world", "hello\nworld")]
    [InlineData("hello new paragraph world", "hello\n\nworld")]
    public void Unambiguous_spoken_words_are_always_replaced(string input, string expected)
        => TextPostProcessor.Process(input).Should().Be(expected);

    // --- Hybrid mode ambiguous replacements ---
    [Fact]
    public void Hybrid_replaces_comma_after_punctuation()
        => TextPostProcessor.Process("hello, comma world", hybrid: true).Should().Be("hello, world");

    [Fact]
    public void Hybrid_does_not_replace_comma_as_regular_word()
        => TextPostProcessor.Process("comma separated values", hybrid: true).Should().Be("comma separated values");

    [Fact]
    public void Spoken_mode_always_replaces_comma()
        => TextPostProcessor.Process("comma separated values", hybrid: false).Should().Be(", separated values");

    // --- Ellipsis stripping ---
    [Fact]
    public void Multi_dot_sequences_are_stripped()
        => TextPostProcessor.Process("hello... world").Should().Be("hello world");

    [Fact]
    public void Unicode_ellipsis_is_stripped()
        => TextPostProcessor.Process("hello\u2026world").Should().Be("helloworld");

    // --- Spacing fixes ---
    [Fact]
    public void Space_before_punctuation_is_removed()
        => TextPostProcessor.Process("hello , world").Should().Be("hello, world");

    [Fact]
    public void Space_is_added_after_punctuation_before_word()
        => TextPostProcessor.Process("hello.world").Should().Be("hello. world");

    // --- Capitalize after sentence end ---
    [Fact]
    public void Capitalizes_after_period()
        => TextPostProcessor.Process("hello. would love").Should().Be("hello. Would love");

    [Fact]
    public void Capitalizes_after_exclamation()
        => TextPostProcessor.Process("hello! would love").Should().Be("hello! Would love");

    // --- Comma before capital → period ---
    [Fact]
    public void Comma_before_sentence_starter_becomes_period()
        => TextPostProcessor.Process("hello, There you go").Should().Be("hello. There you go");

    [Fact]
    public void Comma_before_non_starter_stays()
        => TextPostProcessor.Process("hello, She said").Should().Be("hello, She said");

    // --- Style: texting ---
    [Fact]
    public void Texting_style_strips_trailing_period()
    {
        var result = TextPostProcessor.ApplyStyle("hello world.", TextPostProcessor.StyleMode.Texting);
        result.Should().Be("hello world");
    }

    [Fact]
    public void Texting_style_capitalizes_first_letter()
    {
        var result = TextPostProcessor.ApplyStyle("hello world", TextPostProcessor.StyleMode.Texting);
        result.Should().Be("Hello world");
    }

    [Fact]
    public void None_style_returns_unchanged()
    {
        var result = TextPostProcessor.ApplyStyle("hello world.", TextPostProcessor.StyleMode.None);
        result.Should().Be("hello world.");
    }

    // --- Style detection ---
    [Theory]
    [InlineData("com.apple.MobileSMS", TextPostProcessor.StyleMode.Texting)]
    [InlineData("com.tinyspeck.slackmacgap", TextPostProcessor.StyleMode.Slack)]
    [InlineData("com.google.Chrome", TextPostProcessor.StyleMode.None)]
    public void DetectStyleMode_maps_bundle_ids_correctly(string bundleId, TextPostProcessor.StyleMode expected)
        => TextPostProcessor.DetectStyleMode(bundleId).Should().Be(expected);
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "TextPostProcessorTests"
```

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/PostProcessing/TextPostProcessor.cs
using System.Text.RegularExpressions;

namespace OpenWispr.Windows.PostProcessing;

public static class TextPostProcessor
{
    public enum StyleMode { Texting, Slack, Email, None }

    // Word boundaries — same logic as Swift version
    private const string Ws = @"(?<=[\s.,!?;:]|^)";
    private const string We = @"(?=[\s.,!?;:]|$)";

    private static readonly (Regex re, string replacement)[] AlwaysReplace =
    [
        (R($@"{Ws}question marks?{We}"), "?"),
        (R($@"{Ws}exclamation marks?{We}"), "!"),
        (R($@"{Ws}exclamation points?{We}"), "!"),
        (R($@"{Ws}semicolon{We}"), ";"),
        (R($@"{Ws}semi colon{We}"), ";"),
        (R($@"{Ws}full stop{We}"), "."),
        (R($@"{Ws}open quote{We}"), "\""),
        (R($@"{Ws}close quote{We}"), "\""),
        (R($@"{Ws}open paren{We}"), "("),
        (R($@"{Ws}close paren{We}"), ")"),
        (R($@"{Ws}new line{We}"), "\n"),
        (R($@"{Ws}newline{We}"), "\n"),
        (R($@"{Ws}new paragraph{We}"), "\n\n"),
    ];

    private static readonly (Regex re, string replacement)[] ContextReplace =
    [
        (R($@"(?<=[.,!?;:])\s*(?:[ck]omma|kana|kanna){We}"), ","),
        (R($@"(?<=[.,!?;:])\s*period{We}"), "."),
        (R($@"(?<=[.,!?;:])\s*colon{We}"), ":"),
        (R($@"(?<=[.,!?;:])\s*dash{We}"), " \u2014"),
        (R($@"(?<=[.,!?;:])\s*hyphen{We}"), "-"),
    ];

    private static readonly (Regex re, string replacement)[] SpokenFallback =
    [
        (R($@"{Ws}(?:[ck]omma|kana|kanna){We}"), ","),
        (R($@"{Ws}period{We}"), "."),
        (R($@"{Ws}colon{We}"), ":"),
        (R($@"{Ws}dash{We}"), " \u2014"),
        (R($@"{Ws}hyphen{We}"), "-"),
    ];

    private static Regex R(string pattern) =>
        new(pattern, RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static string Process(string text, bool hybrid = false)
    {
        var result = text;

        foreach (var (re, rep) in AlwaysReplace)
            result = re.Replace(result, rep);

        var ambiguous = hybrid ? ContextReplace : SpokenFallback;
        foreach (var (re, rep) in ambiguous)
            result = re.Replace(result, rep);

        if (hybrid)
            result = ConvertStandaloneAmbiguous(result);

        // Strip ellipsis
        result = Regex.Replace(result, @"\.{2,}", "");
        result = result.Replace("\u2026", "");

        // Collapse duplicate punctuation
        result = Regex.Replace(result, @"([.,!?;:])(?:\s*\1)+", "$1");

        result = FixSpacingAroundPunctuation(result);
        result = CollapseAdjacentPunctuation(result);
        result = EnsureSpaceAfterPunctuation(result);
        result = CommaBeforeCapitalToPeriod(result);
        result = CapitalizeAfterSentenceEnd(result);

        return result;
    }

    public static StyleMode DetectStyleMode(string? appName)
    {
        if (appName is null) return StyleMode.None;
        var id = appName.ToLowerInvariant();
        if (id.Contains("signal") || id.Contains("imessage") || id.Contains("messages")
            || id.Contains("whatsapp") || id.Contains("telegram") || id.Contains("sms"))
            return StyleMode.Texting;
        if (id.Contains("slack") || id.Contains("discord") || id.Contains("teams"))
            return StyleMode.Slack;
        if (id.Contains("gmail") || id.Contains("mail") || id.Contains("outlook")
            || id.Contains("superhuman") || id.Contains("spark"))
            return StyleMode.Email;
        return StyleMode.None;
    }

    public static string ApplyStyle(string text, StyleMode mode)
    {
        if (mode != StyleMode.Texting && mode != StyleMode.Slack) return text;
        var result = text.Trim();
        if (result.Length == 0) return result;

        // Strip trailing period (not abbreviations)
        if (result.EndsWith('.') && !result.EndsWith(".."))
        {
            var beforeDot = result[..^1];
            if (beforeDot.Length > 0)
            {
                var lastWord = beforeDot.Split(' ').Last();
                if (lastWord.Length > 2)
                    result = beforeDot;
            }
        }

        // Capitalize first letter
        if (char.IsLower(result[0]))
            result = char.ToUpper(result[0]) + result[1..];

        return result;
    }

    private static string ConvertStandaloneAmbiguous(string text)
    {
        var replacements = new[]
        {
            ("comma", ",", new HashSet<string> { "separated", "delimited", "splice", "operator" }),
            ("komma", ",", new HashSet<string>()),
            ("period", ".", new HashSet<string> { "of", "piece" }),
            ("colon", ":", new HashSet<string> { "cancer", "surgery", "cleanse", "polyp" }),
            ("dash", " \u2014", new HashSet<string> { "of", "board", "cam" }),
            ("hyphen", "-", new HashSet<string>()),
        };

        var result = text;
        foreach (var (word, rep, skip) in replacements)
        {
            var re = new Regex($@"(?i)(?<=\s|^){word}(?=\s|$|[.,!?;:])", RegexOptions.Compiled);
            result = re.Replace(result, m =>
            {
                var after = result[m.Index + m.Length..].TrimStart();
                var next = Regex.Match(after, @"^\w+").Value.ToLowerInvariant();
                return skip.Contains(next) ? m.Value : rep;
            });
        }
        return result;
    }

    private static string FixSpacingAroundPunctuation(string text)
        => Regex.Replace(text, @"\s+([.,?!:;])", "$1");

    private static string EnsureSpaceAfterPunctuation(string text)
        => Regex.Replace(text, @"([.,?!:;])(\w)", "$1 $2");

    private static string CollapseAdjacentPunctuation(string text)
    {
        text = Regex.Replace(text, @"[,;:]\s*([.!?])", "$1");
        text = Regex.Replace(text, @"\.\s*([!?])", "$1");
        text = Regex.Replace(text, @"([!?])\s*\.", "$1");
        text = Regex.Replace(text, @"([!?])\s*,", "$1");
        text = Regex.Replace(text, @"\.\s*,", ".");
        return text;
    }

    private static string CommaBeforeCapitalToPeriod(string text)
    {
        var starters = new HashSet<string>
        {
            "There", "Then", "This", "That", "They", "The",
            "So", "What", "When", "Where", "Which", "While", "Who", "Why",
            "Also", "After", "Before",
        };

        return Regex.Replace(text, @",\s+([A-Z][a-z]+)", m =>
        {
            var word = m.Groups[1].Value;
            return starters.Contains(word) ? ". " + word : m.Value;
        });
    }

    private static string CapitalizeAfterSentenceEnd(string text)
        => Regex.Replace(text, @"([.!?])\s+(\w)", m =>
            m.Groups[1].Value + " " + m.Groups[2].Value.ToUpperInvariant());
}
```

**Step 4: Run tests — expect pass**

```bash
./scripts/dev-loop.sh "TextPostProcessorTests"
```

Expected: `~20 passed`

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): TextPostProcessor — port of Swift spoken punctuation logic"
```

---

## Task 6: DiagnosticLogger

**Files:**
- Create: `windows/OpenWispr.Windows/System/DiagnosticLogger.cs`
- Create: `windows/OpenWispr.Windows.Tests/System/DiagnosticLoggerTests.cs`

**Step 1: Write failing tests**

```csharp
using FluentAssertions;
using OpenWispr.Windows.System;
using Xunit;

public class DiagnosticLoggerTests
{
    [Fact]
    public void Log_creates_file_and_writes_message()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var logger = new DiagnosticLogger(tempDir, enabled: true);
        logger.Log("hello world");
        var files = Directory.GetFiles(tempDir, "*.log");
        files.Should().HaveCount(1);
        File.ReadAllText(files[0]).Should().Contain("hello world");
    }

    [Fact]
    public void Log_does_nothing_when_disabled()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var logger = new DiagnosticLogger(tempDir, enabled: false);
        logger.Log("hello");
        Directory.Exists(tempDir).Should().BeFalse();
    }
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "DiagnosticLoggerTests"
```

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/System/DiagnosticLogger.cs
namespace OpenWispr.Windows.System;

public class DiagnosticLogger
{
    private readonly string _logDir;
    private readonly bool _enabled;
    private readonly string _logFile;

    public static DiagnosticLogger Shared { get; private set; } = new(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "OpenWispr", "logs"),
        enabled: false);

    public static void Configure(string logDir, bool enabled)
        => Shared = new DiagnosticLogger(logDir, enabled);

    public DiagnosticLogger(string logDir, bool enabled)
    {
        _logDir = logDir;
        _enabled = enabled;
        _logFile = Path.Combine(logDir, $"openwisprmod-{DateTime.Now:yyyy-MM-dd}.log");
    }

    public void Log(string message)
    {
        if (!_enabled) return;
        Directory.CreateDirectory(_logDir);
        var line = $"[{DateTime.Now:HH:mm:ss.fff}] {message}{Environment.NewLine}";
        File.AppendAllText(_logFile, line);
    }
}
```

**Step 4: Run tests — expect pass**

```bash
./scripts/dev-loop.sh "DiagnosticLoggerTests"
```

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): DiagnosticLogger"
```

---

## Task 7: WordMemory (Vocabulary)

Port of `WordMemory.swift` — reads/writes a vocabulary file used to prime Whisper.

**Files:**
- Create: `windows/OpenWispr.Windows/System/WordMemory.cs`
- Create: `windows/OpenWispr.Windows.Tests/System/WordMemoryTests.cs`

**Step 1: Write failing tests**

```csharp
using FluentAssertions;
using OpenWispr.Windows.System;
using Xunit;

public class WordMemoryTests
{
    [Fact]
    public void LoadVocabulary_returns_null_when_file_missing()
    {
        WordMemory.LoadVocabulary("/nonexistent/path.txt").Should().BeNull();
    }

    [Fact]
    public void LoadVocabulary_strips_comments_and_auto_markers()
    {
        var path = Path.GetTempFileName();
        File.WriteAllLines(path, ["hello", "world # auto", "# comment", ""]);
        var result = WordMemory.LoadVocabulary(path);
        result.Should().Be("hello, world");
        File.Delete(path);
    }

    [Fact]
    public void LearnWord_appends_with_auto_marker()
    {
        var path = Path.GetTempFileName();
        File.Delete(path);
        WordMemory.LearnWord("TestWord", path);
        File.ReadAllText(path).Should().Contain("TestWord # auto");
        File.Delete(path);
    }
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "WordMemoryTests"
```

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/System/WordMemory.cs
namespace OpenWispr.Windows.System;

public static class WordMemory
{
    public static string? LoadVocabulary(string path)
    {
        if (!File.Exists(path)) return null;
        var words = File.ReadAllLines(path)
            .Select(line =>
            {
                var l = line.Trim();
                var autoIdx = l.IndexOf(" # auto", StringComparison.OrdinalIgnoreCase);
                if (autoIdx >= 0) l = l[..autoIdx].Trim();
                return l;
            })
            .Where(l => !string.IsNullOrEmpty(l) && !l.StartsWith('#'))
            .ToList();
        return words.Count > 0 ? string.Join(", ", words) : null;
    }

    public static void LearnWord(string word, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.AppendAllText(path, $"{word} # auto{Environment.NewLine}");
    }
}
```

**Step 4: Run tests — expect pass**

```bash
./scripts/dev-loop.sh "WordMemoryTests"
```

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): WordMemory vocabulary file reader/writer"
```

---

## Task 8: ModelDownloader

Downloads Whisper GGML model files from Hugging Face with progress reporting.

**Files:**
- Create: `windows/OpenWispr.Windows/Transcription/ModelDownloader.cs`
- Create: `windows/OpenWispr.Windows.Tests/Transcription/ModelDownloaderTests.cs`

**Step 1: Write failing tests**

```csharp
using FluentAssertions;
using Moq;
using OpenWispr.Windows.Transcription;
using Xunit;

public class ModelDownloaderTests
{
    [Fact]
    public void ModelUrl_returns_huggingface_url_for_known_model()
    {
        var url = ModelDownloader.ModelUrl("base.en");
        url.Should().Contain("base.en");
        url.Should().StartWith("https://");
    }

    [Fact]
    public void ModelFileName_maps_size_to_ggml_filename()
    {
        ModelDownloader.ModelFileName("base.en").Should().Be("ggml-base.en.bin");
        ModelDownloader.ModelFileName("small.en").Should().Be("ggml-small.en.bin");
        ModelDownloader.ModelFileName("large").Should().Be("ggml-large-v3.bin");
    }

    [Fact]
    public void KnownModels_contains_expected_sizes()
    {
        ModelDownloader.KnownModels.Should().Contain("tiny.en");
        ModelDownloader.KnownModels.Should().Contain("base.en");
        ModelDownloader.KnownModels.Should().Contain("small.en");
        ModelDownloader.KnownModels.Should().Contain("medium.en");
        ModelDownloader.KnownModels.Should().Contain("large");
    }
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "ModelDownloaderTests"
```

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/Transcription/ModelDownloader.cs
namespace OpenWispr.Windows.Transcription;

public class ModelDownloader
{
    private const string BaseUrl =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    public static string[] KnownModels => ["tiny.en", "base.en", "small.en", "medium.en", "large"];

    public static string ModelFileName(string size) => size switch
    {
        "large" => "ggml-large-v3.bin",
        _ => $"ggml-{size}.bin",
    };

    public static string ModelUrl(string size) => BaseUrl + ModelFileName(size);

    public static Dictionary<string, long> ModelSizes => new()
    {
        ["tiny.en"]   = 75_000_000,
        ["base.en"]   = 142_000_000,
        ["small.en"]  = 466_000_000,
        ["medium.en"] = 1_500_000_000,
        ["large"]     = 3_000_000_000,
    };

    public async Task DownloadAsync(
        string size,
        string destPath,
        IProgress<double>? progress = null,
        CancellationToken ct = default)
    {
        using var client = new HttpClient();
        client.Timeout = TimeSpan.FromHours(2);

        Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
        var tempPath = destPath + ".tmp";

        using var response = await client.GetAsync(
            ModelUrl(size), HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var total = response.Content.Headers.ContentLength ?? ModelSizes.GetValueOrDefault(size);
        long downloaded = 0;

        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        await using var file = File.Create(tempPath);

        var buffer = new byte[81920];
        int read;
        while ((read = await stream.ReadAsync(buffer, ct)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, read), ct);
            downloaded += read;
            progress?.Report(total > 0 ? (double)downloaded / total : 0);
        }

        file.Close();
        if (File.Exists(destPath)) File.Delete(destPath);
        File.Move(tempPath, destPath);
    }
}
```

**Step 4: Run tests — expect pass**

```bash
./scripts/dev-loop.sh "ModelDownloaderTests"
```

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): ModelDownloader with progress reporting"
```

---

## Task 9: WhisperEngine

Wraps `Whisper.net` (which wraps whisper.cpp). Port of `WhisperEngine.swift`.

> **Note:** Tests in this task require a real model file — run on VM only. Download the tiny.en model first.

**Files:**
- Create: `windows/OpenWispr.Windows/Transcription/WhisperEngine.cs`
- Create: `windows/OpenWispr.Windows.Tests/Transcription/WhisperEngineTests.cs`

**Step 1: Download test model on VM**

SSH to VM:

```powershell
$modelsDir = "$env:APPDATA\OpenWispr\models"
New-Item -ItemType Directory -Force -Path $modelsDir
$url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
Invoke-WebRequest -Uri $url -OutFile "$modelsDir\ggml-tiny.en.bin" -UseBasicParsing
```

**Step 2: Write failing tests**

```csharp
// windows/OpenWispr.Windows.Tests/Transcription/WhisperEngineTests.cs
using FluentAssertions;
using OpenWispr.Windows.Transcription;
using Xunit;

public class WhisperEngineTests
{
    private static string ModelPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "OpenWispr", "models", "ggml-tiny.en.bin");

    [Fact]
    public void IsLoaded_false_before_load()
    {
        var engine = new WhisperEngine();
        engine.IsLoaded.Should().BeFalse();
    }

    [Fact]
    public async Task LoadModel_succeeds_for_valid_path()
    {
        Skip.If(!File.Exists(ModelPath), "Model not downloaded");
        var engine = new WhisperEngine();
        await engine.LoadModelAsync(ModelPath);
        engine.IsLoaded.Should().BeTrue();
        engine.UnloadModel();
    }

    [Fact]
    public async Task Transcribe_returns_text_for_silence()
    {
        Skip.If(!File.Exists(ModelPath), "Model not downloaded");
        var engine = new WhisperEngine();
        await engine.LoadModelAsync(ModelPath);
        // 1 second of silence
        var samples = new float[16000];
        var result = await engine.TranscribeAsync(samples, "en");
        result.Should().NotBeNull(); // may be empty, but should not throw
        engine.UnloadModel();
    }

    [Fact]
    public async Task Transcribe_throws_when_model_not_loaded()
    {
        var engine = new WhisperEngine();
        await Assert.ThrowsAsync<InvalidOperationException>(
            () => engine.TranscribeAsync(new float[16000], "en"));
    }

    [Fact]
    public void TrimSilence_returns_original_for_short_samples()
    {
        var engine = new WhisperEngine();
        var samples = new float[100];
        engine.TrimSilence(samples).Should().BeSameAs(samples);
    }

    [Fact]
    public void TrimSilence_removes_leading_silence()
    {
        var engine = new WhisperEngine();
        // 1 second silence + 0.5 second speech + 1 second silence = 2.5s total
        var samples = new float[40000];
        // Add speech energy in the middle
        for (int i = 16000; i < 24000; i++)
            samples[i] = 0.5f;
        var trimmed = engine.TrimSilence(samples);
        trimmed.Length.Should().BeLessThan(samples.Length);
    }
}
```

**Step 3: Run — expect build failure**

```bash
./scripts/dev-loop.sh "WhisperEngineTests"
```

**Step 4: Implement**

```csharp
// windows/OpenWispr.Windows/Transcription/WhisperEngine.cs
using Whisper.net;
using Whisper.net.Ggml;

namespace OpenWispr.Windows.Transcription;

public class WhisperEngine : IDisposable
{
    private WhisperFactory? _factory;
    private WhisperProcessor? _processor;
    private string? _loadedModelPath;

    public bool IsLoaded => _factory != null;

    public async Task LoadModelAsync(string path, CancellationToken ct = default)
    {
        if (_loadedModelPath == path && IsLoaded) return;
        UnloadModel();

        DiagnosticLogger.Shared.Log($"WhisperEngine: loading model from {path}");
        _factory = WhisperFactory.FromPath(path);
        _loadedModelPath = path;
        DiagnosticLogger.Shared.Log("WhisperEngine: model loaded");
    }

    public void UnloadModel()
    {
        _processor?.Dispose();
        _factory?.Dispose();
        _processor = null;
        _factory = null;
        _loadedModelPath = null;
    }

    public async Task<string> TranscribeAsync(
        float[] samples,
        string language = "en",
        string? prompt = null,
        CancellationToken ct = default)
    {
        if (_factory == null)
            throw new InvalidOperationException("No model loaded. Call LoadModelAsync() first.");

        var trimmed = TrimSilence(samples);

        var builder = _factory.CreateBuilder()
            .WithLanguage(language == "auto" ? "auto" : language)
            .WithNoContext()
            .WithSingleSegment(false);

        if (!string.IsNullOrEmpty(prompt))
            builder = builder.WithPrompt(prompt);

        _processor?.Dispose();
        _processor = builder.Build();

        DiagnosticLogger.Shared.Log(
            $"WhisperEngine: transcribing {trimmed.Length} samples ({trimmed.Length / 16000.0:F1}s)");

        var segments = new List<string>();
        await foreach (var seg in _processor.ProcessAsync(trimmed, ct))
        {
            if (seg.Probability < 0.4f) continue;  // skip low-confidence segments
            segments.Add(seg.Text);
        }

        var result = string.Join("", segments).Trim();
        DiagnosticLogger.Shared.Log($"WhisperEngine: result {result.Length} chars");
        return result;
    }

    public float[] TrimSilence(float[] samples, float threshold = 0.01f)
    {
        const int windowSize = 1600; // 100ms at 16kHz
        if (samples.Length <= windowSize * 2) return samples;

        int start = 0;
        for (int i = 0; i < samples.Length - windowSize; i += windowSize / 2)
        {
            var window = samples.AsSpan(i, Math.Min(windowSize, samples.Length - i));
            var rms = MathF.Sqrt(window.ToArray().Select(s => s * s).Average());
            if (rms > threshold) { start = Math.Max(0, i - windowSize); break; }
        }

        int end = samples.Length;
        for (int i = samples.Length - windowSize; i >= 0; i -= windowSize / 2)
        {
            var window = samples.AsSpan(i, Math.Min(windowSize, samples.Length - i));
            var rms = MathF.Sqrt(window.ToArray().Select(s => s * s).Average());
            if (rms > threshold) { end = Math.Min(samples.Length, i + windowSize * 2); break; }
        }

        if (start >= end) return samples;
        var result = samples[start..end];
        DiagnosticLogger.Shared.Log(
            $"VAD: trimmed {samples.Length} → {result.Length} samples");
        return result;
    }

    public void Dispose() => UnloadModel();
}
```

Also add the `DiagnosticLogger` reference — import `OpenWispr.Windows.System` in the file.

**Step 5: Run tests on VM**

```bash
./scripts/dev-loop.sh "WhisperEngineTests"
```

Expected: Logic tests pass. `LoadModel` and `Transcribe` tests skip if model absent (run after model downloaded on VM).

**Step 6: Commit**

```bash
git add windows/
git commit -m "feat(windows): WhisperEngine wrapping Whisper.net"
```

---

## Task 10: AudioRecorder

NAudio WASAPI capture → PCM float32, 16kHz, mono. Windows-only. Test on VM.

**Files:**
- Create: `windows/OpenWispr.Windows/Audio/AudioRecorder.cs`
- Create: `windows/OpenWispr.Windows.Tests/Audio/AudioRecorderTests.cs`

**Step 1: Write failing tests**

```csharp
using FluentAssertions;
using OpenWispr.Windows.Audio;
using Xunit;

public class AudioRecorderTests
{
    [Fact]
    public void Initial_state_is_not_recording()
    {
        var recorder = new AudioRecorder();
        recorder.IsRecording.Should().BeFalse();
    }

    [Fact]
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    public async Task StartStop_captures_samples()
    {
        var recorder = new AudioRecorder();
        recorder.Start();
        recorder.IsRecording.Should().BeTrue();
        await Task.Delay(500); // capture 500ms
        var samples = recorder.Stop();
        samples.Should().NotBeEmpty();
        // 500ms at 16kHz = ~8000 samples
        samples.Length.Should().BeGreaterThan(4000);
    }
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "AudioRecorderTests"
```

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/Audio/AudioRecorder.cs
using NAudio.Wave;

namespace OpenWispr.Windows.Audio;

public class AudioRecorder : IDisposable
{
    private WasapiCapture? _capture;
    private readonly List<float> _samples = [];
    private bool _recording;

    public bool IsRecording => _recording;

    public void Start()
    {
        if (_recording) return;
        _samples.Clear();

        _capture = new WasapiCapture
        {
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(16000, 1)
        };

        _capture.DataAvailable += OnDataAvailable;
        _capture.StartRecording();
        _recording = true;
        DiagnosticLogger.Shared.Log("AudioRecorder: started");
    }

    public float[] Stop()
    {
        if (!_recording) return [];
        _capture?.StopRecording();
        _capture?.Dispose();
        _capture = null;
        _recording = false;
        var result = _samples.ToArray();
        _samples.Clear();
        DiagnosticLogger.Shared.Log($"AudioRecorder: stopped, {result.Length} samples");
        return result;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        // Convert bytes to float32 samples
        for (int i = 0; i < e.BytesRecorded; i += 4)
            _samples.Add(BitConverter.ToSingle(e.Buffer, i));
    }

    public void Dispose()
    {
        _capture?.Dispose();
        _capture = null;
    }
}
```

**Step 4: Run on VM**

```bash
./scripts/dev-loop.sh "AudioRecorderTests"
```

Expected on VM: `2 passed` (microphone available). On Mac CI: StartStop test may fail — that's OK.

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): AudioRecorder via NAudio WASAPI"
```

---

## Task 11: HotkeyManager

Win32 `RegisterHotKey` / `UnregisterHotKey` with a hidden message window. Fires `HotkeyPressed` and `HotkeyReleased` events. Supports hold mode and toggle mode.

**Files:**
- Create: `windows/OpenWispr.Windows/Hotkey/HotkeyManager.cs`
- Create: `windows/OpenWispr.Windows/Hotkey/KeyCodes.cs`
- Create: `windows/OpenWispr.Windows.Tests/Hotkey/HotkeyManagerTests.cs`

**Step 1: Write failing tests**

```csharp
using FluentAssertions;
using OpenWispr.Windows.Hotkey;
using Xunit;

public class HotkeyManagerTests
{
    [Fact]
    public void Initial_state_is_not_registered()
    {
        var mgr = new HotkeyManager();
        mgr.IsRegistered.Should().BeFalse();
    }

    [Fact]
    public void KeyCodes_contains_right_ctrl()
    {
        KeyCodes.VK_RCONTROL.Should().Be(0xA3);
    }

    [Fact]
    public void KeyCodes_contains_all_standard_modifiers()
    {
        KeyCodes.VK_LSHIFT.Should().Be(0xA0);
        KeyCodes.VK_RSHIFT.Should().Be(0xA1);
        KeyCodes.VK_LMENU.Should().Be(0xA4);
        KeyCodes.VK_RMENU.Should().Be(0xA5);
    }
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "HotkeyManagerTests"
```

**Step 3: Implement KeyCodes**

```csharp
// windows/OpenWispr.Windows/Hotkey/KeyCodes.cs
namespace OpenWispr.Windows.Hotkey;

public static class KeyCodes
{
    public const int VK_LSHIFT   = 0xA0;
    public const int VK_RSHIFT   = 0xA1;
    public const int VK_LCONTROL = 0xA2;
    public const int VK_RCONTROL = 0xA3;
    public const int VK_LMENU    = 0xA4;  // Left Alt
    public const int VK_RMENU    = 0xA5;  // Right Alt
    public const int VK_LWIN     = 0x5B;
    public const int VK_RWIN     = 0x5C;

    public static string DisplayName(int vk) => vk switch
    {
        VK_RCONTROL => "Right Ctrl",
        VK_LCONTROL => "Left Ctrl",
        VK_RSHIFT   => "Right Shift",
        VK_LSHIFT   => "Left Shift",
        VK_RMENU    => "Right Alt",
        VK_LMENU    => "Left Alt",
        VK_LWIN     => "Left Win",
        VK_RWIN     => "Right Win",
        _           => $"Key 0x{vk:X2}",
    };
}
```

**Step 4: Implement HotkeyManager**

```csharp
// windows/OpenWispr.Windows/Hotkey/HotkeyManager.cs
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace OpenWispr.Windows.Hotkey;

public class HotkeyManager : IDisposable
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private const int HotkeyId = 9001;

    public event Action? HotkeyPressed;
    public event Action? HotkeyReleased;

    private HwndSource? _hwndSource;
    private bool _registered;
    private bool _toggleMode;
    private bool _toggleState;
    private int _currentVk;

    public bool IsRegistered => _registered;

    public void Register(int virtualKey, bool toggleMode = false)
    {
        Unregister();
        _toggleMode = toggleMode;
        _currentVk = virtualKey;

        var helper = new System.Windows.Window();
        var handle = new WindowInteropHelper(helper).EnsureHandle();
        _hwndSource = HwndSource.FromHwnd(handle);
        _hwndSource!.AddHook(WndProc);

        // Register as "no modifier" hotkey — we treat the key itself as the trigger
        _registered = RegisterHotKey(handle, HotkeyId, 0, (uint)virtualKey);
        DiagnosticLogger.Shared.Log($"HotkeyManager: registered vk=0x{virtualKey:X2}, toggle={toggleMode}, success={_registered}");
    }

    public void Unregister()
    {
        if (_hwndSource != null)
        {
            UnregisterHotKey(_hwndSource.Handle, HotkeyId);
            _hwndSource.RemoveHook(WndProc);
            _hwndSource.Dispose();
            _hwndSource = null;
        }
        _registered = false;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HotkeyId)
        {
            if (_toggleMode)
            {
                _toggleState = !_toggleState;
                if (_toggleState) HotkeyPressed?.Invoke();
                else HotkeyReleased?.Invoke();
            }
            else
            {
                HotkeyPressed?.Invoke();
                // Hold mode: released handled by keyboard hook (see below)
            }
            handled = true;
        }
        return IntPtr.Zero;
    }

    // For hold mode: detect key-up via low-level keyboard hook
    private IntPtr _hookHandle = IntPtr.Zero;
    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private LowLevelKeyboardProc? _hookProc;

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string? lpModuleName);

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYUP = 0x0105;

    public void InstallKeyUpHook()
    {
        _hookProc = KeyboardHookCallback;
        _hookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, _hookProc,
            GetModuleHandle(null), 0);
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && (wParam == WM_KEYUP || wParam == WM_SYSKEYUP))
        {
            var vk = Marshal.ReadInt32(lParam);
            if (vk == _currentVk)
                HotkeyReleased?.Invoke();
        }
        return CallNextHookEx(_hookHandle, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hookHandle != IntPtr.Zero) UnhookWindowsHookEx(_hookHandle);
        Unregister();
    }
}
```

**Step 5: Run tests**

```bash
./scripts/dev-loop.sh "HotkeyManagerTests"
```

Expected: `3 passed`

**Step 6: Commit**

```bash
git add windows/
git commit -m "feat(windows): HotkeyManager with RegisterHotKey + key-up hook"
```

---

## Task 12: TextInserter

Types text via `SendInput`. Falls back to clipboard paste if text contains special characters.

**Files:**
- Create: `windows/OpenWispr.Windows/TextInsertion/TextInserter.cs`
- Create: `windows/OpenWispr.Windows.Tests/TextInsertion/TextInserterTests.cs`

**Step 1: Write failing tests**

```csharp
using FluentAssertions;
using OpenWispr.Windows.TextInsertion;
using Xunit;

public class TextInserterTests
{
    [Fact]
    public void NeedsClipboard_true_for_complex_unicode()
    {
        TextInserter.NeedsClipboard("hello 🎉 world").Should().BeTrue();
    }

    [Fact]
    public void NeedsClipboard_false_for_ascii()
    {
        TextInserter.NeedsClipboard("hello world!").Should().BeFalse();
    }

    [Fact]
    public void NeedsClipboard_false_for_standard_punctuation()
    {
        TextInserter.NeedsClipboard("Hello, world. How are you?").Should().BeFalse();
    }
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "TextInserterTests"
```

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/TextInsertion/TextInserter.cs
using System.Runtime.InteropServices;
using System.Windows;

namespace OpenWispr.Windows.TextInsertion;

public class TextInserter
{
    [DllImport("user32.dll")] static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] static extern short VkKeyScan(char ch);
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const int VK_CONTROL = 0x11;
    private const int VK_V = 0x56;

    public static bool NeedsClipboard(string text)
        => text.Any(c => c > 127 || VkKeyScan(c) == -1);

    public void Type(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        if (NeedsClipboard(text))
        {
            PasteViaClipboard(text);
        }
        else
        {
            TypeViaSendInput(text);
        }

        DiagnosticLogger.Shared.Log($"TextInserter: typed {text.Length} chars");
    }

    private static void TypeViaSendInput(string text)
    {
        var inputs = new List<INPUT>();
        foreach (var ch in text)
        {
            var vk = VkKeyScan(ch);
            var key = (byte)(vk & 0xFF);
            var shift = (vk >> 8 & 0x01) != 0;

            if (shift)
            {
                inputs.Add(KeyInput(0xA0, 0)); // VK_LSHIFT down
            }
            inputs.Add(KeyInput(key, 0));       // key down
            inputs.Add(KeyInput(key, 2));       // key up (KEYEVENTF_KEYUP)
            if (shift)
            {
                inputs.Add(KeyInput(0xA0, 2)); // VK_LSHIFT up
            }
        }

        SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    private static void PasteViaClipboard(string text)
    {
        var prev = Clipboard.GetText();
        Clipboard.SetText(text);
        // Ctrl+V
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        Thread.Sleep(50);
        // Restore clipboard
        if (!string.IsNullOrEmpty(prev))
            Clipboard.SetText(prev);
        else
            Clipboard.Clear();
    }

    private static INPUT KeyInput(byte vk, uint flags) => new()
    {
        type = 1, // INPUT_KEYBOARD
        u = new InputUnion
        {
            ki = new KEYBDINPUT { wVk = vk, dwFlags = flags }
        }
    };

    // Win32 structs
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public byte wVk; public byte wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
}
```

**Step 4: Run tests**

```bash
./scripts/dev-loop.sh "TextInserterTests"
```

Expected: `3 passed`

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): TextInserter with SendInput + clipboard fallback"
```

---

## Task 13: LaunchAtLogin

Writes/removes an entry in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

**Files:**
- Create: `windows/OpenWispr.Windows/System/LaunchAtLogin.cs`
- Create: `windows/OpenWispr.Windows.Tests/System/LaunchAtLoginTests.cs`

**Step 1: Write failing tests**

```csharp
using FluentAssertions;
using OpenWispr.Windows.System;
using Xunit;

public class LaunchAtLoginTests
{
    [Fact]
    public void IsEnabled_returns_false_when_not_registered()
    {
        // Use a unique app name so we don't conflict with real registration
        LaunchAtLogin.IsEnabled("OpenWispr-Test-DELETEME").Should().BeFalse();
    }
}
```

**Step 2: Run — expect build failure**

```bash
./scripts/dev-loop.sh "LaunchAtLoginTests"
```

**Step 3: Implement**

```csharp
// windows/OpenWispr.Windows/System/LaunchAtLogin.cs
using Microsoft.Win32;

namespace OpenWispr.Windows.System;

public static class LaunchAtLogin
{
    private const string RunKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "OpenWispr";

    public static bool IsEnabled(string? name = null)
    {
        name ??= AppName;
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(name) != null;
    }

    public static void Enable(string exePath)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        key?.SetValue(AppName, $"\"{exePath}\"");
        DiagnosticLogger.Shared.Log($"LaunchAtLogin: enabled → {exePath}");
    }

    public static void Disable()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        key?.DeleteValue(AppName, throwOnMissingValue: false);
        DiagnosticLogger.Shared.Log("LaunchAtLogin: disabled");
    }
}
```

**Step 4: Run tests**

```bash
./scripts/dev-loop.sh "LaunchAtLoginTests"
```

**Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows): LaunchAtLogin via registry run key"
```

---

## Task 14: App Bootstrap

Wire up `App.xaml.cs` — initialize all services, handle startup flow.

**Files:**
- Modify: `windows/OpenWispr.Windows/App.xaml.cs`
- Modify: `windows/OpenWispr.Windows/App.xaml`

**Step 1: Set up App.xaml to suppress auto-startup window**

```xml
<!-- App.xaml -->
<Application x:Class="OpenWispr.Windows.App"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             ShutdownMode="OnExplicitShutdown">
</Application>
```

**Step 2: Implement App.xaml.cs**

```csharp
// App.xaml.cs
using OpenWispr.Windows.Audio;
using OpenWispr.Windows.Hotkey;
using OpenWispr.Windows.Settings;
using OpenWispr.Windows.System;
using OpenWispr.Windows.TextInsertion;
using OpenWispr.Windows.Transcription;
using OpenWispr.Windows.UI;

namespace OpenWispr.Windows;

public partial class App : Application
{
    public AppSettings Settings { get; private set; } = AppSettings.Default;
    public WhisperEngine Engine { get; } = new();
    public AudioRecorder Recorder { get; } = new();
    public HotkeyManager HotkeyMgr { get; } = new();
    public TextInserter Inserter { get; } = new();
    public TrayController? Tray { get; private set; }
    public RecordingOverlay? Overlay { get; private set; }

    private bool _isRecording;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        Settings = AppSettings.Load();
        DiagnosticLogger.Configure(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenWispr", "logs"),
            Settings.DiagnosticLogging);
        DiagnosticLogger.Shared.Log("App: starting");

        Tray = new TrayController(this);
        Overlay = new RecordingOverlay();

        // First run: no model downloaded yet
        if (Settings.ModelPath == null || !File.Exists(Settings.ModelPath))
        {
            var downloader = new ModelDownloadWindow(this);
            downloader.Show();
            return;
        }

        await StartMainLoop();
    }

    public async Task StartMainLoop()
    {
        await Engine.LoadModelAsync(Settings.ModelPath!);
        HotkeyMgr.Register(Settings.Hotkey.VirtualKey, Settings.ToggleMode);
        if (!Settings.ToggleMode) HotkeyMgr.InstallKeyUpHook();

        HotkeyMgr.HotkeyPressed += OnHotkeyPressed;
        HotkeyMgr.HotkeyReleased += OnHotkeyReleased;

        DiagnosticLogger.Shared.Log("App: ready");
    }

    private void OnHotkeyPressed()
    {
        if (_isRecording) return;
        _isRecording = true;
        Overlay?.Show();
        Recorder.Start();
        DiagnosticLogger.Shared.Log("App: recording started");
    }

    private async void OnHotkeyReleased()
    {
        if (!_isRecording) return;
        _isRecording = false;

        var samples = Recorder.Stop();
        Overlay?.Hide();

        if (samples.Length < 3200) // < 200ms, ignore
        {
            DiagnosticLogger.Shared.Log("App: recording too short, ignoring");
            return;
        }

        try
        {
            var vocab = WordMemory.LoadVocabulary(
                Path.Combine(AppSettings.DefaultModelsPath, "..", "vocabulary.txt"));
            var raw = await Engine.TranscribeAsync(samples, Settings.Language, vocab);

            if (string.IsNullOrWhiteSpace(raw))
            {
                DiagnosticLogger.Shared.Log("App: empty transcription");
                return;
            }

            var hybrid = Settings.Punctuation == PostProcessing.PunctuationMode.Hybrid;
            var processed = PostProcessing.TextPostProcessor.Process(raw, hybrid);
            Inserter.Type(processed);
        }
        catch (Exception ex)
        {
            DiagnosticLogger.Shared.Log($"App: transcription error — {ex.Message}");
            Tray?.ShowNotification("OpenWispr", "Transcription failed. Check logs.");
        }
    }

    public void SaveSettings(AppSettings updated)
    {
        Settings = updated;
        Settings.Save();

        // Re-register hotkey if changed
        HotkeyMgr.Unregister();
        HotkeyMgr.Register(Settings.Hotkey.VirtualKey, Settings.ToggleMode);

        // Update launch at login
        if (Settings.LaunchAtLogin)
            LaunchAtLogin.Enable(Environment.ProcessPath ?? "");
        else
            LaunchAtLogin.Disable();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        HotkeyMgr.Dispose();
        Engine.Dispose();
        Tray?.Dispose();
        base.OnExit(e);
    }
}
```

**Step 3: Build**

```bash
./scripts/dev-loop.sh
```

(Build only — no new unit tests for this task.)

**Step 4: Commit**

```bash
git add windows/
git commit -m "feat(windows): App bootstrap — wire all services together"
```

---

## Task 15: TrayController

System tray icon with context menu.

**Files:**
- Create: `windows/OpenWispr.Windows/UI/TrayController.cs`
- Create: `windows/OpenWispr.Windows/Resources/tray-idle.ico`
- Create: `windows/OpenWispr.Windows/Resources/tray-recording.ico`

**Step 1: Create tray icons**

On the VM, use PowerShell to generate simple placeholder icons:

```powershell
# We'll use the built-in Windows icons as placeholders
# Copy from system — replace with real icons later
$shell = New-Object -ComObject Shell.Application
# For now, copy a system icon as placeholder
Copy-Item "$env:SystemRoot\System32\shell32.dll" . -ErrorAction SilentlyContinue
```

For actual icons: extract icon from `AppIcon.iconset/` on Mac side, convert to `.ico` using ImageMagick:

```bash
# On Mac
brew install imagemagick
convert AppIcon.iconset/icon_32x32.png windows/OpenWispr.Windows/Resources/tray-idle.ico
convert AppIcon.iconset/icon_32x32@2x.png windows/OpenWispr.Windows/Resources/tray-recording.ico
```

**Step 2: Implement TrayController**

```csharp
// windows/OpenWispr.Windows/UI/TrayController.cs
using Hardcodet.Wpf.TaskbarNotification;

namespace OpenWispr.Windows.UI;

public class TrayController : IDisposable
{
    private readonly TaskbarIcon _tray;
    private readonly App _app;

    public TrayController(App app)
    {
        _app = app;
        _tray = new TaskbarIcon
        {
            ToolTipText = "OpenWispr — Hold Right Ctrl to speak",
            Icon = LoadIcon("tray-idle.ico"),
        };

        _tray.TrayMouseDoubleClick += (_, _) => OpenSettings();

        var menu = new System.Windows.Controls.ContextMenu();
        AddMenuItem(menu, "Settings", OpenSettings);
        AddMenuItem(menu, "Help", OpenHelp);
        menu.Items.Add(new System.Windows.Controls.Separator());
        AddMenuItem(menu, "Quit", () => app.Shutdown());
        _tray.ContextMenu = menu;
    }

    public void SetRecording(bool recording)
    {
        _tray.Icon = LoadIcon(recording ? "tray-recording.ico" : "tray-idle.ico");
        _tray.ToolTipText = recording ? "OpenWispr — Recording..." : "OpenWispr — Hold Right Ctrl to speak";
    }

    public void ShowNotification(string title, string message)
        => _tray.ShowBalloonTip(title, message, BalloonIcon.Info);

    private void OpenSettings()
    {
        var win = new SettingsWindow(_app);
        win.Show();
    }

    private void OpenHelp()
    {
        var win = new HelpWindow();
        win.Show();
    }

    private static System.Drawing.Icon LoadIcon(string name)
    {
        var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", name);
        return File.Exists(path)
            ? new System.Drawing.Icon(path)
            : System.Drawing.SystemIcons.Application;
    }

    private static void AddMenuItem(System.Windows.Controls.ContextMenu menu, string header, Action action)
    {
        var item = new System.Windows.Controls.MenuItem { Header = header };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    public void Dispose() => _tray.Dispose();
}
```

**Step 3: Build**

```bash
./scripts/dev-loop.sh
```

**Step 4: Commit**

```bash
git add windows/
git commit -m "feat(windows): TrayController with context menu"
```

---

## Task 16: RecordingOverlay

Transparent topmost WPF window showing a pulsing indicator while recording.

**Files:**
- Create: `windows/OpenWispr.Windows/UI/RecordingOverlay.xaml`
- Create: `windows/OpenWispr.Windows/UI/RecordingOverlay.xaml.cs`

**Step 1: Implement**

```xml
<!-- RecordingOverlay.xaml -->
<Window x:Class="OpenWispr.Windows.UI.RecordingOverlay"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True"
        IsHitTestVisible="False"
        ShowInTaskbar="False"
        Width="120" Height="40"
        WindowStartupLocation="Manual">
    <Grid>
        <Border Background="#CC1C1C1E" CornerRadius="8" Padding="12,8">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <Ellipse x:Name="Dot" Width="10" Height="10" Fill="#FF4444"
                         Margin="0,0,8,0" VerticalAlignment="Center">
                    <Ellipse.Triggers>
                        <EventTrigger RoutedEvent="Loaded">
                            <BeginStoryboard>
                                <Storyboard RepeatBehavior="Forever">
                                    <DoubleAnimation Storyboard.TargetName="Dot"
                                                     Storyboard.TargetProperty="Opacity"
                                                     From="1" To="0.2" Duration="0:0:0.6"
                                                     AutoReverse="True"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </EventTrigger>
                    </Ellipse.Triggers>
                </Ellipse>
                <TextBlock Text="Recording..." Foreground="White" FontSize="12"
                           VerticalAlignment="Center"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>
```

```csharp
// RecordingOverlay.xaml.cs
namespace OpenWispr.Windows.UI;

public partial class RecordingOverlay : Window
{
    public RecordingOverlay()
    {
        InitializeComponent();
        PositionBottomRight();
    }

    private void PositionBottomRight()
    {
        var screen = SystemParameters.WorkArea;
        Left = screen.Right - Width - 20;
        Top = screen.Bottom - Height - 20;
    }

    new public void Show()
    {
        PositionBottomRight();
        base.Show();
    }
}
```

**Step 2: Build and verify on VM**

```bash
./scripts/dev-loop.sh
```

Manually test on VM: run the app, hold Right Ctrl — overlay should appear bottom-right.

**Step 3: Commit**

```bash
git add windows/
git commit -m "feat(windows): RecordingOverlay with pulsing indicator"
```

---

## Task 17: ModelDownloadWindow

Progress UI for downloading Whisper models.

**Files:**
- Create: `windows/OpenWispr.Windows/UI/ModelDownloadWindow.xaml`
- Create: `windows/OpenWispr.Windows/UI/ModelDownloadWindow.xaml.cs`

**Step 1: Implement**

```xml
<!-- ModelDownloadWindow.xaml -->
<Window x:Class="OpenWispr.Windows.UI.ModelDownloadWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenWispr — Download Model" Width="420" Height="260"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
    <StackPanel Margin="24">
        <TextBlock Text="Choose a Whisper model" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,8"/>
        <TextBlock Text="The model runs locally on your PC. No internet required after download."
                   TextWrapping="Wrap" Foreground="#666" Margin="0,0,0,16"/>
        <ComboBox x:Name="ModelPicker" Margin="0,0,0,8"/>
        <TextBlock x:Name="SizeLabel" Foreground="#666" Margin="0,0,0,16"/>
        <ProgressBar x:Name="Progress" Height="8" Minimum="0" Maximum="1"
                     Visibility="Collapsed" Margin="0,0,0,8"/>
        <TextBlock x:Name="StatusLabel" Foreground="#666" Margin="0,0,0,16"/>
        <Button x:Name="DownloadBtn" Content="Download" Click="DownloadBtn_Click"
                HorizontalAlignment="Left" Padding="16,8"/>
    </StackPanel>
</Window>
```

```csharp
// ModelDownloadWindow.xaml.cs
using OpenWispr.Windows.Transcription;
using OpenWispr.Windows.Settings;

namespace OpenWispr.Windows.UI;

public partial class ModelDownloadWindow : Window
{
    private readonly App _app;
    private CancellationTokenSource? _cts;

    public ModelDownloadWindow(App app)
    {
        InitializeComponent();
        _app = app;
        ModelPicker.ItemsSource = ModelDownloader.KnownModels;
        ModelPicker.SelectedIndex = 1; // base.en default
        ModelPicker.SelectionChanged += (_, _) => UpdateSizeLabel();
        UpdateSizeLabel();
    }

    private void UpdateSizeLabel()
    {
        var size = ModelPicker.SelectedItem as string;
        if (size != null && ModelDownloader.ModelSizes.TryGetValue(size, out var bytes))
            SizeLabel.Text = $"~{bytes / 1_000_000} MB";
    }

    private async void DownloadBtn_Click(object sender, RoutedEventArgs e)
    {
        var size = ModelPicker.SelectedItem as string;
        if (size == null) return;

        var modelsDir = AppSettings.DefaultModelsPath;
        var destPath = Path.Combine(modelsDir, ModelDownloader.ModelFileName(size));

        DownloadBtn.IsEnabled = false;
        Progress.Visibility = Visibility.Visible;
        StatusLabel.Text = "Downloading...";

        _cts = new CancellationTokenSource();
        var downloader = new ModelDownloader();

        try
        {
            await downloader.DownloadAsync(size, destPath,
                new Progress<double>(p =>
                {
                    Progress.Value = p;
                    StatusLabel.Text = $"{p:P0}";
                }),
                _cts.Token);

            // Save model path and start main loop
            var updated = _app.Settings with { ModelPath = destPath, ModelSize = size };
            _app.SaveSettings(updated);
            await _app.StartMainLoop();
            Close();
        }
        catch (OperationCanceledException)
        {
            StatusLabel.Text = "Cancelled";
            DownloadBtn.IsEnabled = true;
        }
        catch (Exception ex)
        {
            StatusLabel.Text = $"Error: {ex.Message}";
            DownloadBtn.IsEnabled = true;
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        _cts?.Cancel();
        base.OnClosed(e);
    }
}
```

**Step 2: Build**

```bash
./scripts/dev-loop.sh
```

**Step 3: Test on VM** — Run the app fresh (no model). ModelDownloadWindow should appear. Select tiny.en, download.

**Step 4: Commit**

```bash
git add windows/
git commit -m "feat(windows): ModelDownloadWindow with progress bar"
```

---

## Task 18: SettingsWindow

Full settings UI with all options from the Mac app.

**Files:**
- Create: `windows/OpenWispr.Windows/UI/SettingsWindow.xaml`
- Create: `windows/OpenWispr.Windows/UI/SettingsWindow.xaml.cs`

**Step 1: Implement XAML**

```xml
<!-- SettingsWindow.xaml -->
<Window x:Class="OpenWispr.Windows.UI.SettingsWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenWispr Settings" Width="440" Height="480"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
    <StackPanel Margin="24">
        <TextBlock Text="Settings" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,20"/>

        <!-- Hotkey -->
        <TextBlock Text="Hotkey" FontWeight="Medium" Margin="0,0,0,4"/>
        <ComboBox x:Name="HotkeyPicker" Margin="0,0,0,16"/>

        <!-- Model -->
        <TextBlock Text="Model" FontWeight="Medium" Margin="0,0,0,4"/>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,16">
            <ComboBox x:Name="ModelPicker" Width="200"/>
            <Button Content="Change Model" Click="ChangeModel_Click" Margin="8,0,0,0" Padding="12,4"/>
        </StackPanel>

        <!-- Punctuation -->
        <TextBlock Text="Punctuation" FontWeight="Medium" Margin="0,0,0,4"/>
        <ComboBox x:Name="PunctuationPicker" Margin="0,0,0,16"/>

        <!-- Key Mode -->
        <TextBlock Text="Key Mode" FontWeight="Medium" Margin="0,0,0,4"/>
        <ComboBox x:Name="KeyModePicker" Margin="0,0,0,16"/>

        <!-- Language -->
        <TextBlock Text="Language" FontWeight="Medium" Margin="0,0,0,4"/>
        <ComboBox x:Name="LanguagePicker" Margin="0,0,0,16"/>

        <!-- Max Recordings -->
        <TextBlock Text="Max Saved Recordings" FontWeight="Medium" Margin="0,0,0,4"/>
        <ComboBox x:Name="MaxRecordingsPicker" Margin="0,0,0,16"/>

        <!-- Launch at login -->
        <CheckBox x:Name="LaunchAtLoginCheck" Content="Launch at login" Margin="0,0,0,16"/>

        <!-- Diagnostic logging -->
        <CheckBox x:Name="DiagnosticCheck" Content="Enable diagnostic logging" Margin="0,0,0,24"/>

        <Button Content="Save" Click="Save_Click" HorizontalAlignment="Left" Padding="24,8"/>
    </StackPanel>
</Window>
```

**Step 2: Implement code-behind**

```csharp
// SettingsWindow.xaml.cs
using OpenWispr.Windows.Hotkey;
using OpenWispr.Windows.PostProcessing;
using OpenWispr.Windows.Settings;
using OpenWispr.Windows.Transcription;

namespace OpenWispr.Windows.UI;

public partial class SettingsWindow : Window
{
    private readonly App _app;

    private static readonly (string Label, int VK)[] Hotkeys =
    [
        ("Right Ctrl (recommended)", KeyCodes.VK_RCONTROL),
        ("Left Ctrl", KeyCodes.VK_LCONTROL),
        ("Right Shift", KeyCodes.VK_RSHIFT),
        ("Left Shift", KeyCodes.VK_LSHIFT),
        ("Right Alt", KeyCodes.VK_RMENU),
        ("Left Alt", KeyCodes.VK_LMENU),
    ];

    public SettingsWindow(App app)
    {
        InitializeComponent();
        _app = app;
        Populate();
    }

    private void Populate()
    {
        var s = _app.Settings;

        HotkeyPicker.ItemsSource = Hotkeys.Select(h => h.Label).ToList();
        HotkeyPicker.SelectedIndex = Array.FindIndex(Hotkeys, h => h.VK == s.Hotkey.VirtualKey);
        if (HotkeyPicker.SelectedIndex < 0) HotkeyPicker.SelectedIndex = 0;

        ModelPicker.ItemsSource = ModelDownloader.KnownModels;
        ModelPicker.SelectedItem = s.ModelSize;

        PunctuationPicker.ItemsSource = new[] { "Hybrid (default)", "Off", "Spoken words" };
        PunctuationPicker.SelectedIndex = s.Punctuation switch
        {
            PunctuationMode.Hybrid => 0,
            PunctuationMode.Off    => 1,
            PunctuationMode.Spoken => 2,
            _ => 0
        };

        KeyModePicker.ItemsSource = new[] { "Hold (default)", "Toggle" };
        KeyModePicker.SelectedIndex = s.ToggleMode ? 1 : 0;

        LanguagePicker.ItemsSource = new[] { "en (English)", "auto (detect)", "fr (French)", "de (German)", "es (Spanish)", "zh (Chinese)", "ja (Japanese)" };
        LanguagePicker.SelectedIndex = 0;

        MaxRecordingsPicker.ItemsSource = new[] { "Off", "10", "30", "50", "100" };
        MaxRecordingsPicker.SelectedItem = s.MaxRecordings == 0 ? "Off" : s.MaxRecordings.ToString();

        LaunchAtLoginCheck.IsChecked = s.LaunchAtLogin;
        DiagnosticCheck.IsChecked = s.DiagnosticLogging;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var selectedHk = Hotkeys[HotkeyPicker.SelectedIndex];
        var punct = PunctuationPicker.SelectedIndex switch
        {
            1 => PunctuationMode.Off,
            2 => PunctuationMode.Spoken,
            _ => PunctuationMode.Hybrid,
        };
        var maxRec = MaxRecordingsPicker.SelectedItem as string == "Off" ? 0
            : int.TryParse(MaxRecordingsPicker.SelectedItem as string, out var n) ? n : 30;
        var lang = (LanguagePicker.SelectedItem as string ?? "en").Split(' ')[0];

        var updated = _app.Settings with
        {
            Hotkey = new HotkeyConfig(selectedHk.VK),
            ModelSize = ModelPicker.SelectedItem as string ?? "base.en",
            Punctuation = punct,
            ToggleMode = KeyModePicker.SelectedIndex == 1,
            MaxRecordings = maxRec,
            LaunchAtLogin = LaunchAtLoginCheck.IsChecked ?? false,
            DiagnosticLogging = DiagnosticCheck.IsChecked ?? false,
            Language = lang,
        };

        _app.SaveSettings(updated);
        Close();
    }

    private void ChangeModel_Click(object sender, RoutedEventArgs e)
    {
        var win = new ModelDownloadWindow(_app);
        win.Show();
    }
}
```

**Step 3: Build and test on VM**

```bash
./scripts/dev-loop.sh
```

Manually: tray → Settings → verify all controls load and Save works.

**Step 4: Commit**

```bash
git add windows/
git commit -m "feat(windows): SettingsWindow with all settings controls"
```

---

## Task 19: HelpWindow

Static help text explaining usage.

**Files:**
- Create: `windows/OpenWispr.Windows/UI/HelpWindow.xaml`
- Create: `windows/OpenWispr.Windows/UI/HelpWindow.xaml.cs`

**Step 1: Implement**

```xml
<!-- HelpWindow.xaml -->
<Window x:Class="OpenWispr.Windows.UI.HelpWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenWispr Help" Width="480" Height="520"
        WindowStartupLocation="CenterScreen">
    <ScrollViewer Padding="24">
        <StackPanel>
            <TextBlock Text="How to use OpenWispr" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,16"/>

            <TextBlock Text="Basic usage" FontWeight="Medium" Margin="0,0,0,4"/>
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,16">
                Hold your hotkey (default: Right Ctrl), speak, then release.
                Your words appear wherever your cursor is.
                If no text field is focused, the text is copied to your clipboard.
            </TextBlock>

            <TextBlock Text="Hotkey" FontWeight="Medium" Margin="0,0,0,4"/>
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,16">
                Choose any modifier key in Settings. Right Ctrl is recommended
                because it's rarely used for other shortcuts.
            </TextBlock>

            <TextBlock Text="Punctuation modes" FontWeight="Medium" Margin="0,0,0,4"/>
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,4">
                Hybrid (default): Say "question mark" or "exclamation mark" — always converted.
                Ambiguous words like "comma" and "period" are only converted when Whisper
                detected a pause (punctuation) before them.
            </TextBlock>
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,4">
                Spoken words: Always converts spoken punctuation words.
            </TextBlock>
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,16">
                Off: No spoken punctuation conversion.
            </TextBlock>

            <TextBlock Text="Models" FontWeight="Medium" Margin="0,0,0,4"/>
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,16">
                Larger models are more accurate but slower. base.en is recommended for most people.
                All models run 100% locally — no internet required after download.
            </TextBlock>

            <TextBlock Text="Key mode" FontWeight="Medium" Margin="0,0,0,4"/>
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,16">
                Hold (default): press and hold while speaking, release to transcribe.
                Toggle: press once to start, press again to stop and transcribe.
            </TextBlock>
        </StackPanel>
    </ScrollViewer>
</Window>
```

```csharp
// HelpWindow.xaml.cs
namespace OpenWispr.Windows.UI;
public partial class HelpWindow : Window
{
    public HelpWindow() => InitializeComponent();
}
```

**Step 2: Build**

```bash
./scripts/dev-loop.sh
```

**Step 3: Commit**

```bash
git add windows/
git commit -m "feat(windows): HelpWindow"
```

---

## Task 20: End-to-End Integration Test on VM

Smoke test the full hotkey → record → transcribe → type flow.

**Files:**
- Create: `scripts/integration-test.ps1`

**Step 1: Write the integration test script**

```powershell
# scripts/integration-test.ps1
# Runs on the Windows VM via SSH.
# 1. Starts the app
# 2. Waits for tray icon to appear
# 3. Opens Notepad
# 4. Simulates hotkey press, plays a short beep (silence = empty transcription)
# 5. Verifies app is still running (no crash)

Write-Host "==> Starting OpenWispr..."
$appPath = "C:\Users\owmadmin\openwisprmod\windows\OpenWispr.Windows\bin\Release\net8.0-windows\win-x64\publish\OpenWispr.exe"
$proc = Start-Process $appPath -PassThru
Start-Sleep 3

Write-Host "==> Checking process is alive..."
if ($proc.HasExited) {
    Write-Error "App crashed on startup! Exit code: $($proc.ExitCode)"
    exit 1
}

Write-Host "==> Verifying tray icon (process running = icon registered)..."
$running = Get-Process -Name "OpenWispr" -ErrorAction SilentlyContinue
if (-not $running) {
    Write-Error "OpenWispr process not found"
    exit 1
}

Write-Host "==> Sending hotkey (Right Ctrl)..."
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SendKeys]::SendWait("{CTRL}")
Start-Sleep 1
[System.Windows.Forms.SendKeys]::SendWait("{CTRL}")
Start-Sleep 2

Write-Host "==> Verifying app still running after hotkey cycle..."
if ($proc.HasExited) {
    Write-Error "App crashed after hotkey! Exit code: $($proc.ExitCode)"
    exit 1
}

Write-Host "==> Stopping app..."
$proc | Stop-Process

Write-Host "PASS: Integration smoke test passed."
```

**Step 2: Run integration test on VM**

First, build the release:

```bash
ssh owmadmin@$VM_IP "
  cd C:\\Users\\owmadmin\\openwisprmod
  dotnet publish windows/OpenWispr.Windows -c Release -r win-x64 --self-contained -o windows/publish
"
```

Then run the smoke test:

```bash
ssh owmadmin@$VM_IP "powershell -File C:\\Users\\owmadmin\\openwisprmod\\scripts\\integration-test.ps1"
```

Expected: `PASS: Integration smoke test passed.`

**Step 3: Commit**

```bash
git add scripts/integration-test.ps1
git commit -m "test(windows): integration smoke test — startup, tray, hotkey cycle"
```

---

## Task 21: Release Build

Self-contained single-exe publish.

**Files:**
- Modify: `windows/OpenWispr.Windows/OpenWispr.Windows.csproj` (add PublishSingleFile)

**Step 1: Update csproj for single-file publish**

Add to `<PropertyGroup>`:

```xml
<PublishSingleFile>true</PublishSingleFile>
<SelfContained>true</SelfContained>
<RuntimeIdentifier>win-x64</RuntimeIdentifier>
<PublishReadyToRun>true</PublishReadyToRun>
<IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>
```

**Step 2: Build release on VM**

```bash
ssh owmadmin@$VM_IP "
  cd C:\\Users\\owmadmin\\openwisprmod\\windows
  dotnet publish OpenWispr.Windows -c Release -r win-x64 --self-contained \
    -p:PublishSingleFile=true -o ../dist
"
```

Expected: `OpenWispr.exe` in `windows/../dist/`. File size ~80-150 MB (includes .NET runtime + whisper.cpp).

**Step 3: Verify the published exe runs**

```bash
ssh owmadmin@$VM_IP "
  Start-Process 'C:\\Users\\owmadmin\\openwisprmod\\dist\\OpenWispr.exe'
  Start-Sleep 3
  Get-Process OpenWispr
  Stop-Process -Name OpenWispr
"
```

**Step 4: Commit**

```bash
git add windows/
git commit -m "chore(windows): configure single-file self-contained release build"
```

---

## Task 22: Deallocate VM

Stop billing when testing is done.

**Step 1: Deallocate**

```bash
az vm deallocate --resource-group openwisprmod-win --name owm-build
```

Expected: VM status → `Stopped (deallocated)`. Billing stops. Disk and IP preserved.

**Step 2: To restart for future sessions**

```bash
az vm start --resource-group openwisprmod-win --name owm-build
```

---

## Task 23: Send Release to Evan

> **Wait until Task 21 is verified passing before starting this task.**

**Step 1: Show email content for approval**

Draft to show Michael before sending:

```
To: evan.budaj@gmail.com
Subject: OpenWispr for Windows — early build

Hey Evan,

Sharing an early Windows build of OpenWispr (the "hold a key, speak, release — 
text appears at cursor" app from the Mac).

To install:
1. Download OpenWispr.exe (attached)
2. Run it — Windows may show a security warning on first launch, click "More info" → "Run anyway"
3. On first launch, choose a Whisper model to download (~142 MB for base.en, 
   runs 100% locally after that)
4. The OpenWispr icon appears in your system tray
5. Hold Right Ctrl, speak, release — your words appear wherever your cursor is

Note: this is an early build. Let me know what breaks.

— Michael
```

**Step 2: Get Michael's approval before sending**

Show the above draft and wait for explicit "yes, send it."

**Step 3: Send via action queue**

```bash
curl -X POST http://localhost:8300/actions \
  -H "Content-Type: application/json" \
  -d '{
    "actions": [{
      "target_label": "Email Evan with OpenWispr Windows build",
      "operations": [{
        "action_type": "gmail_draft",
        "payload": {
          "to": "evan.budaj@gmail.com",
          "subject": "OpenWispr for Windows — early build",
          "body": "..."
        },
        "confidence": 0.95
      }]
    }],
    "source": "openwisprmod"
  }'
```

---

_Claude · 2026-04-07 · Windows port implementation plan_
