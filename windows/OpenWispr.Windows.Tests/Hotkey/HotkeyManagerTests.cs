using FluentAssertions;
using OpenWispr.Windows.Hotkey;
using Xunit;

namespace OpenWispr.Windows.Tests.Hotkey;

public class HotkeyManagerTests
{
    [Fact]
    public void Initial_state_is_not_registered()
    {
        var mgr = new HotkeyManager();
        mgr.IsRegistered.Should().BeFalse();
    }

    [Fact]
    public void VK_RCONTROL_has_expected_value()
        => KeyCodes.VK_RCONTROL.Should().Be(0xA3);

    [Fact]
    public void KeyCodes_display_names_are_non_empty()
    {
        KeyCodes.DisplayName(KeyCodes.VK_RCONTROL).Should().Be("Right Ctrl");
        KeyCodes.DisplayName(KeyCodes.VK_LSHIFT).Should().Be("Left Shift");
        KeyCodes.DisplayName(0xFF).Should().StartWith("Key");
    }
}
