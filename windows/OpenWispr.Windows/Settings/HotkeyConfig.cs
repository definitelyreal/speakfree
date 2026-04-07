namespace OpenWispr.Windows.Settings;

public record HotkeyConfig(int VirtualKey = 0xA3 /* VK_RCONTROL */, int Modifiers = 0);
