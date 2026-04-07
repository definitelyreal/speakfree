using System.Windows.Forms;
using OpenWispr.Windows.Core;

namespace OpenWispr.Windows.UI;

public class TrayController : IDisposable
{
    private readonly NotifyIcon _tray;
    private readonly App _app;

    public TrayController(App app)
    {
        _app = app;
        _tray = new NotifyIcon
        {
            Text = "OpenWispr — Hold Right Ctrl to speak",
            Icon = LoadIcon(),
            Visible = true,
        };

        _tray.DoubleClick += (_, _) => OpenSettings();

        var menu = new ContextMenuStrip();
        menu.Items.Add("Settings", null, (_, _) => OpenSettings());
        menu.Items.Add("Help", null, (_, _) => OpenHelp());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => app.Shutdown());
        _tray.ContextMenuStrip = menu;

        DiagnosticLogger.Shared.Log("TrayController: initialized");
    }

    public void SetRecording(bool recording)
    {
        _tray.Text = recording
            ? "OpenWispr — Recording..."
            : "OpenWispr — Hold Right Ctrl to speak";
    }

    public void ShowNotification(string title, string message)
        => _tray.ShowBalloonTip(3000, title, message, ToolTipIcon.Info);

    private void OpenSettings()
    {
        System.Windows.Application.Current.Dispatcher.Invoke(
            () => new SettingsWindow(_app).Show());
    }

    private void OpenHelp()
    {
        System.Windows.Application.Current.Dispatcher.Invoke(
            () => new HelpWindow().Show());
    }

    private static System.Drawing.Icon LoadIcon()
    {
        var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "tray.ico");
        return File.Exists(path)
            ? new System.Drawing.Icon(path)
            : System.Drawing.SystemIcons.Application;
    }

    public void Dispose()
    {
        _tray.Visible = false;
        _tray.Dispose();
    }
}
