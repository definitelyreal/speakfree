namespace OpenWispr.Windows.Hotkey;

public static class KeyCodes
{
    public const int VK_LSHIFT   = 0xA0;
    public const int VK_RSHIFT   = 0xA1;
    public const int VK_LCONTROL = 0xA2;
    public const int VK_RCONTROL = 0xA3;
    public const int VK_LMENU    = 0xA4;  // Left Alt
    public const int VK_RMENU    = 0xA5;  // Right Alt
    public const int VK_LWIN     = 0x5B;
    public const int VK_RWIN     = 0x5C;

    public static string DisplayName(int vk) => vk switch
    {
        VK_RCONTROL => "Right Ctrl",
        VK_LCONTROL => "Left Ctrl",
        VK_RSHIFT   => "Right Shift",
        VK_LSHIFT   => "Left Shift",
        VK_RMENU    => "Right Alt",
        VK_LMENU    => "Left Alt",
        VK_LWIN     => "Left Win",
        VK_RWIN     => "Right Win",
        _           => $"Key 0x{vk:X2}",
    };
}
