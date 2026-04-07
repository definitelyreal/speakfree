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
            Icon = LoadIcon(),
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
        _tray.ToolTipText = recording
            ? "OpenWispr — Recording..."
            : "OpenWispr — Hold Right Ctrl to speak";
    }

    public void ShowNotification(string title, string message)
        => _tray.ShowBalloonTip(title, message, BalloonIcon.Info);

    private void OpenSettings() => new SettingsWindow(_app).Show();
    private void OpenHelp() => new HelpWindow().Show();

    private static System.Drawing.Icon LoadIcon()
    {
        var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "tray.ico");
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
