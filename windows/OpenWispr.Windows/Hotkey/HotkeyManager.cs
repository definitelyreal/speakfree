using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using OpenWispr.Windows.Core;

namespace OpenWispr.Windows.Hotkey;

public class HotkeyManager : IDisposable
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string? lpModuleName);

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    private const int WM_HOTKEY = 0x0312;
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYUP = 0x0105;
    private const int HotkeyId = 9001;

    public event Action? HotkeyPressed;
    public event Action? HotkeyReleased;

    private HwndSource? _hwndSource;
    private IntPtr _hookHandle = IntPtr.Zero;
    private LowLevelKeyboardProc? _hookProc;
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

        var helperWindow = new Window { Width = 0, Height = 0, WindowStyle = WindowStyle.None, ShowInTaskbar = false };
        helperWindow.Show();
        var handle = new WindowInteropHelper(helperWindow).Handle;
        helperWindow.Hide();

        _hwndSource = HwndSource.FromHwnd(handle);
        _hwndSource?.AddHook(WndProc);

        _registered = RegisterHotKey(handle, HotkeyId, 0, (uint)virtualKey);
        DiagnosticLogger.Shared.Log($"HotkeyManager: registered vk=0x{virtualKey:X2}, toggle={toggleMode}, success={_registered}");
    }

    public void InstallKeyUpHook()
    {
        _hookProc = KeyboardHookCallback;
        _hookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, _hookProc, GetModuleHandle(null), 0);
    }

    public void Unregister()
    {
        if (_hookHandle != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookHandle);
            _hookHandle = IntPtr.Zero;
        }
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
            }
            handled = true;
        }
        return IntPtr.Zero;
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
        Unregister();
    }
}
