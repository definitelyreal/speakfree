using FluentAssertions;
using OpenWispr.Windows.Transcription;
using Xunit;

namespace OpenWispr.Windows.Tests.Transcription;

public class ModelDownloaderTests
{
    [Fact]
    public void ModelUrl_returns_huggingface_url()
    {
        var url = ModelDownloader.ModelUrl("base.en");
        url.Should().StartWith("https://");
        url.Should().Contain("base.en");
    }

    [Fact]
    public void ModelFileName_maps_sizes()
    {
        ModelDownloader.ModelFileName("base.en").Should().Be("ggml-base.en.bin");
        ModelDownloader.ModelFileName("small.en").Should().Be("ggml-small.en.bin");
        ModelDownloader.ModelFileName("large").Should().Be("ggml-large-v3.bin");
    }

    [Fact]
    public void KnownModels_contains_all_sizes()
    {
        ModelDownloader.KnownModels.Should().Contain("tiny.en");
        ModelDownloader.KnownModels.Should().Contain("base.en");
        ModelDownloader.KnownModels.Should().Contain("small.en");
        ModelDownloader.KnownModels.Should().Contain("medium.en");
        ModelDownloader.KnownModels.Should().Contain("large");
    }
}
