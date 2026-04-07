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

    public static string DefaultVocabularyPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "OpenWispr", "vocabulary.txt");

    private static readonly JsonSerializerOptions JsonOptions = new()
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
            return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? Default;
        }
        catch
        {
            if (File.Exists(path))
                File.Copy(path, path + ".bak", overwrite: true);
            return Default;
        }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultConfigPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, JsonOptions));
    }
}
