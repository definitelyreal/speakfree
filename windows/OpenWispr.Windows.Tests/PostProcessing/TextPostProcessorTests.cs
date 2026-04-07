using FluentAssertions;
using OpenWispr.Windows.PostProcessing;
using Xunit;

namespace OpenWispr.Windows.Tests.PostProcessing;

public class TextPostProcessorTests
{
    [Theory]
    [InlineData("hello question mark", "hello?")]
    [InlineData("hello exclamation mark", "hello!")]
    [InlineData("hello exclamation point", "hello!")]
    [InlineData("hello semicolon world", "hello; world")]
    [InlineData("hello full stop", "hello.")]
    [InlineData("open quote hello close quote", "\"hello\"")]
    [InlineData("open paren hello close paren", "(hello)")]
    [InlineData("hello new line world", "hello\nworld")]
    [InlineData("hello newline world", "hello\nworld")]
    public void Unambiguous_spoken_words_are_always_replaced(string input, string expected)
        => TextPostProcessor.Process(input).Should().Be(expected);

    [Fact]
    public void Hybrid_replaces_comma_after_punctuation()
        => TextPostProcessor.Process("hello, comma world", hybrid: true).Should().Be("hello, world");

    [Fact]
    public void Hybrid_does_not_replace_comma_separated()
        => TextPostProcessor.Process("comma separated values", hybrid: true).Should().Be("comma separated values");

    [Fact]
    public void Spoken_mode_always_replaces_comma()
        => TextPostProcessor.Process("comma separated values", hybrid: false).Should().Be(", separated values");

    [Fact]
    public void Multi_dot_sequences_are_stripped()
        => TextPostProcessor.Process("hello... world").Should().Be("hello world");

    [Fact]
    public void Unicode_ellipsis_is_stripped()
        => TextPostProcessor.Process("hello\u2026world").Should().Be("helloworld");

    [Fact]
    public void Space_before_punctuation_is_removed()
        => TextPostProcessor.Process("hello , world").Should().Be("hello, world");

    [Fact]
    public void Space_is_added_after_punctuation_before_word()
        => TextPostProcessor.Process("hello.world").Should().Be("hello. world");

    [Fact]
    public void Capitalizes_after_period()
        => TextPostProcessor.Process("hello. would love").Should().Be("hello. Would love");

    [Fact]
    public void Comma_before_sentence_starter_becomes_period()
        => TextPostProcessor.Process("hello, There you go").Should().Be("hello. There you go");

    [Fact]
    public void Texting_style_strips_trailing_period()
        => TextPostProcessor.ApplyStyle("hello world.", TextPostProcessor.StyleMode.Texting)
            .Should().Be("hello world");

    [Fact]
    public void Texting_style_capitalizes_first_letter()
        => TextPostProcessor.ApplyStyle("hello world", TextPostProcessor.StyleMode.Texting)
            .Should().Be("Hello world");

    [Fact]
    public void None_style_returns_unchanged()
        => TextPostProcessor.ApplyStyle("hello world.", TextPostProcessor.StyleMode.None)
            .Should().Be("hello world.");

    [Theory]
    [InlineData("com.apple.MobileSMS", TextPostProcessor.StyleMode.Texting)]
    [InlineData("com.tinyspeck.slackmacgap", TextPostProcessor.StyleMode.Slack)]
    [InlineData("com.google.Chrome", TextPostProcessor.StyleMode.None)]
    public void DetectStyleMode_maps_correctly(string bundleId, TextPostProcessor.StyleMode expected)
        => TextPostProcessor.DetectStyleMode(bundleId).Should().Be(expected);
}
