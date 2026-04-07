using FluentAssertions;
using OpenWispr.Windows.Core;
using Xunit;

namespace OpenWispr.Windows.Tests.Core;

public class DiagnosticLoggerTests
{
    [Fact]
    public void Log_creates_file_and_writes_message()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var logger = new DiagnosticLogger(tempDir, enabled: true);
            logger.Log("hello world");
            var files = Directory.GetFiles(tempDir, "*.log");
            files.Should().HaveCount(1);
            File.ReadAllText(files[0]).Should().Contain("hello world");
        }
        finally { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true); }
    }

    [Fact]
    public void Log_does_nothing_when_disabled()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var logger = new DiagnosticLogger(tempDir, enabled: false);
        logger.Log("hello");
        Directory.Exists(tempDir).Should().BeFalse();
    }
}
