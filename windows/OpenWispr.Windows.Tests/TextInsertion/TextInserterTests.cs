using FluentAssertions;
using OpenWispr.Windows.TextInsertion;
using Xunit;

namespace OpenWispr.Windows.Tests.TextInsertion;

public class TextInserterTests
{
    [Fact]
    public void NeedsClipboard_true_for_emoji()
        => TextInserter.NeedsClipboard("hello \U0001F389 world").Should().BeTrue();

    [Fact]
    public void NeedsClipboard_false_for_ascii()
        => TextInserter.NeedsClipboard("hello world!").Should().BeFalse();

    [Fact]
    public void NeedsClipboard_false_for_standard_punctuation()
        => TextInserter.NeedsClipboard("Hello, world. How are you?").Should().BeFalse();
}
