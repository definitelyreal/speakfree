using OpenWispr.Windows.Audio;
using OpenWispr.Windows.Core;
using OpenWispr.Windows.Hotkey;
using OpenWispr.Windows.PostProcessing;
using OpenWispr.Windows.Settings;
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
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "OpenWispr", "logs"),
            Settings.DiagnosticLogging);
        DiagnosticLogger.Shared.Log("App: starting");

        Tray = new TrayController(this);
        Overlay = new RecordingOverlay();

        if (Settings.ModelPath == null || !File.Exists(Settings.ModelPath))
        {
            new ModelDownloadWindow(this).Show();
            return;
        }

        await StartMainLoop();
    }

    public async Task StartMainLoop()
    {
        await Engine.LoadModelAsync(Settings.ModelPath!);

        HotkeyMgr.Register(Settings.Hotkey.VirtualKey, Settings.ToggleMode);
        if (!Settings.ToggleMode)
            HotkeyMgr.InstallKeyUpHook();

        HotkeyMgr.HotkeyPressed += OnHotkeyPressed;
        HotkeyMgr.HotkeyReleased += OnHotkeyReleased;

        DiagnosticLogger.Shared.Log("App: ready");
    }

    private void OnHotkeyPressed()
    {
        if (_isRecording) return;
        _isRecording = true;
        Dispatcher.Invoke(() => Overlay?.Show());
        Tray?.SetRecording(true);
        Recorder.Start();
        DiagnosticLogger.Shared.Log("App: recording started");
    }

    private async void OnHotkeyReleased()
    {
        if (!_isRecording) return;
        _isRecording = false;

        var samples = Recorder.Stop();
        Dispatcher.Invoke(() =>
        {
            Overlay?.Hide();
            Tray?.SetRecording(false);
        });

        if (samples.Length < 3200) // < 200ms
        {
            DiagnosticLogger.Shared.Log("App: recording too short, ignoring");
            return;
        }

        try
        {
            var vocab = WordMemory.LoadVocabulary(AppSettings.DefaultVocabularyPath);
            var raw = await Engine.TranscribeAsync(samples, Settings.Language, vocab);

            if (string.IsNullOrWhiteSpace(raw))
            {
                DiagnosticLogger.Shared.Log("App: empty transcription");
                return;
            }

            var hybrid = Settings.Punctuation == PunctuationMode.Hybrid;
            var processed = TextPostProcessor.Process(raw, hybrid);
            Dispatcher.Invoke(() => Inserter.Type(processed));
        }
        catch (Exception ex)
        {
            DiagnosticLogger.Shared.Log($"App: error — {ex.Message}");
            Dispatcher.Invoke(() =>
                Tray?.ShowNotification("OpenWispr", "Transcription failed. Check logs."));
        }
    }

    public void SaveSettings(AppSettings updated)
    {
        Settings = updated;
        Settings.Save();

        HotkeyMgr.Unregister();
        HotkeyMgr.Register(Settings.Hotkey.VirtualKey, Settings.ToggleMode);

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
