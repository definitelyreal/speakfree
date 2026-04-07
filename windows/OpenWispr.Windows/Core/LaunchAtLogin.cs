using Microsoft.Win32;

namespace OpenWispr.Windows.Core;

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
