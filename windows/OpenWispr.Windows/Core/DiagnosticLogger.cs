namespace OpenWispr.Windows.Core;

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
        try
        {
            Directory.CreateDirectory(_logDir);
            var line = $"[{DateTime.Now:HH:mm:ss.fff}] {message}{Environment.NewLine}";
            File.AppendAllText(_logFile, line);
        }
        catch { /* never crash the app because of logging */ }
    }
}
