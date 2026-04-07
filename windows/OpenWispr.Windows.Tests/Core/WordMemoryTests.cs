using FluentAssertions;
using OpenWispr.Windows.Core;
using Xunit;

namespace OpenWispr.Windows.Tests.Core;

public class WordMemoryTests
{
    [Fact]
    public void LoadVocabulary_returns_null_when_file_missing()
        => WordMemory.LoadVocabulary("/nonexistent/path/vocab.txt").Should().BeNull();

    [Fact]
    public void LoadVocabulary_strips_comments_and_auto_markers()
    {
        var path = Path.GetTempFileName();
        File.WriteAllLines(path, ["hello", "world # auto", "# comment", ""]);
        var result = WordMemory.LoadVocabulary(path);
        result.Should().Be("hello, world");
        File.Delete(path);
    }

    [Fact]
    public void LearnWord_appends_with_auto_marker()
    {
        var path = Path.GetTempFileName();
        File.Delete(path);
        try
        {
            WordMemory.LearnWord("TestWord", path);
            File.ReadAllText(path).Should().Contain("TestWord # auto");
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }
}
