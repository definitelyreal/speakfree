namespace OpenWispr.Windows.Transcription;

public class ModelDownloader
{
    private const string BaseUrl =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    public static readonly string[] KnownModels = ["tiny.en", "base.en", "small.en", "medium.en", "large"];

    public static string ModelFileName(string size) => size switch
    {
        "large" => "ggml-large-v3.bin",
        _ => $"ggml-{size}.bin",
    };

    public static string ModelUrl(string size) => BaseUrl + ModelFileName(size);

    public static readonly Dictionary<string, long> ModelSizes = new()
    {
        ["tiny.en"]   = 75_000_000L,
        ["base.en"]   = 142_000_000L,
        ["small.en"]  = 466_000_000L,
        ["medium.en"] = 1_500_000_000L,
        ["large"]     = 3_000_000_000L,
    };

    public async Task DownloadAsync(
        string size,
        string destPath,
        IProgress<double>? progress = null,
        CancellationToken ct = default)
    {
        using var client = new HttpClient();
        client.Timeout = TimeSpan.FromHours(2);

        Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
        var tempPath = destPath + ".tmp";

        using var response = await client.GetAsync(
            ModelUrl(size), HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var total = response.Content.Headers.ContentLength
            ?? (ModelSizes.TryGetValue(size, out var s) ? s : 0L);
        long downloaded = 0;

        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        await using var file = File.Create(tempPath);

        var buffer = new byte[81920];
        int read;
        while ((read = await stream.ReadAsync(buffer, ct)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, read), ct);
            downloaded += read;
            progress?.Report(total > 0 ? (double)downloaded / total : 0);
        }

        file.Close();
        if (File.Exists(destPath)) File.Delete(destPath);
        File.Move(tempPath, destPath);
    }
}
