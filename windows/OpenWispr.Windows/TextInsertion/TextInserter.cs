using System.Runtime.InteropServices;
using System.Windows;
using OpenWispr.Windows.Core;

namespace OpenWispr.Windows.TextInsertion;

public class TextInserter
{
    [DllImport("user32.dll")] static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] static extern short VkKeyScan(char ch);
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const byte VK_CONTROL = 0x11;
    private const byte VK_V = 0x56;

    public static bool NeedsClipboard(string text)
        => text.Any(c => c > 127 || VkKeyScan(c) == -1);

    public void Type(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        if (NeedsClipboard(text))
            PasteViaClipboard(text);
        else
            TypeViaSendInput(text);

        DiagnosticLogger.Shared.Log($"TextInserter: typed {text.Length} chars");
    }

    private static void TypeViaSendInput(string text)
    {
        var inputs = new List<INPUT>();
        foreach (var ch in text)
        {
            var vkFull = VkKeyScan(ch);
            var key = (byte)(vkFull & 0xFF);
            var shift = (vkFull >> 8 & 0x01) != 0;

            if (shift) inputs.Add(KeyInput(0xA0, 0));
            inputs.Add(KeyInput(key, 0));
            inputs.Add(KeyInput(key, KEYEVENTF_KEYUP));
            if (shift) inputs.Add(KeyInput(0xA0, KEYEVENTF_KEYUP));
        }
        SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    private static void PasteViaClipboard(string text)
    {
        var prev = Clipboard.ContainsText() ? Clipboard.GetText() : null;
        Clipboard.SetText(text);
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        Thread.Sleep(50);
        if (prev != null) Clipboard.SetText(prev);
        else Clipboard.Clear();
    }

    private static INPUT KeyInput(byte vk, uint flags) => new()
    {
        type = 1,
        u = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = flags } }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public byte wVk; public byte wScan;
        public uint dwFlags; public uint time;
        public UIntPtr dwExtraInfo;
    }
}
