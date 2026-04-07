using OpenWispr.Windows.Core;
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
        var hkIdx = Array.FindIndex(Hotkeys, h => h.VK == s.Hotkey.VirtualKey);
        HotkeyPicker.SelectedIndex = hkIdx >= 0 ? hkIdx : 0;

        ModelPicker.ItemsSource = ModelDownloader.KnownModels;
        ModelPicker.SelectedItem = s.ModelSize;

        PunctuationPicker.ItemsSource = new[] { "Hybrid (default)", "Off", "Spoken words" };
        PunctuationPicker.SelectedIndex = s.Punctuation switch
        {
            PunctuationMode.Hybrid  => 0,
            PunctuationMode.Off     => 1,
            PunctuationMode.Spoken  => 2,
            _ => 0
        };

        KeyModePicker.ItemsSource = new[] { "Hold (default)", "Toggle" };
        KeyModePicker.SelectedIndex = s.ToggleMode ? 1 : 0;

        LanguagePicker.ItemsSource = new[] { "en", "auto", "fr", "de", "es", "zh", "ja", "ko", "pt", "ru" };
        LanguagePicker.SelectedItem = s.Language;
        if (LanguagePicker.SelectedIndex < 0) LanguagePicker.SelectedIndex = 0;

        MaxRecordingsPicker.ItemsSource = new[] { "Off", "10", "30", "50", "100" };
        MaxRecordingsPicker.SelectedItem = s.MaxRecordings == 0 ? "Off" : s.MaxRecordings.ToString();

        LaunchAtLoginCheck.IsChecked = s.LaunchAtLogin;
        DiagnosticCheck.IsChecked = s.DiagnosticLogging;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var selectedHk = Hotkeys[Math.Max(0, HotkeyPicker.SelectedIndex)];
        var punct = PunctuationPicker.SelectedIndex switch
        {
            1 => PunctuationMode.Off,
            2 => PunctuationMode.Spoken,
            _ => PunctuationMode.Hybrid,
        };
        var maxRecStr = MaxRecordingsPicker.SelectedItem as string;
        var maxRec = maxRecStr == "Off" ? 0 : int.TryParse(maxRecStr, out var n) ? n : 30;
        var lang = LanguagePicker.SelectedItem as string ?? "en";

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
        => new ModelDownloadWindow(_app).Show();
}
