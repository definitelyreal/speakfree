using System.Text.Json;
using FluentAssertions;
using OpenWispr.Windows.Settings;
using Xunit;

namespace OpenWispr.Windows.Tests.Settings;

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
        var opts = new JsonSerializerOptions { Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() } };
        var original = AppSettings.Default with { ModelSize = "small.en", Language = "auto" };
        var json = JsonSerializer.Serialize(original, opts);
        var restored = JsonSerializer.Deserialize<AppSettings>(json, opts)!;
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
