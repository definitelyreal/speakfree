using OpenWispr.Windows.Core;
using Whisper.net;

namespace OpenWispr.Windows.Transcription;

public class WhisperEngine : IDisposable
{
    private WhisperFactory? _factory;
    private WhisperProcessor? _processor;
    private string? _loadedModelPath;

    public bool IsLoaded => _factory != null;

    public Task LoadModelAsync(string path, CancellationToken ct = default)
    {
        if (_loadedModelPath == path && IsLoaded) return Task.CompletedTask;
        UnloadModel();
        DiagnosticLogger.Shared.Log($"WhisperEngine: loading model from {path}");
        _factory = WhisperFactory.FromPath(path);
        _loadedModelPath = path;
        DiagnosticLogger.Shared.Log("WhisperEngine: model loaded");
        return Task.CompletedTask;
    }

    public void UnloadModel()
    {
        _processor?.Dispose();
        _factory?.Dispose();
        _processor = null;
        _factory = null;
        _loadedModelPath = null;
    }

    public async Task<string> TranscribeAsync(
        float[] samples,
        string language = "en",
        string? prompt = null,
        CancellationToken ct = default)
    {
        if (_factory == null)
            throw new InvalidOperationException("No model loaded. Call LoadModelAsync() first.");

        var trimmed = TrimSilence(samples);

        var builder = _factory.CreateBuilder()
            .WithLanguage(language)
            .WithNoContext();

        if (!string.IsNullOrEmpty(prompt))
            builder = builder.WithPrompt(prompt);

        _processor?.Dispose();
        _processor = builder.Build();

        DiagnosticLogger.Shared.Log(
            $"WhisperEngine: transcribing {trimmed.Length} samples ({trimmed.Length / 16000.0:F1}s)");

        var segments = new List<string>();
        await foreach (var seg in _processor.ProcessAsync(trimmed, ct))
            segments.Add(seg.Text);

        var result = string.Join("", segments).Trim();
        DiagnosticLogger.Shared.Log($"WhisperEngine: result {result.Length} chars");
        return result;
    }

    public float[] TrimSilence(float[] samples, float threshold = 0.01f)
    {
        const int windowSize = 1600; // 100ms at 16kHz
        if (samples.Length <= windowSize * 2) return samples;

        int start = 0;
        for (int i = 0; i < samples.Length - windowSize; i += windowSize / 2)
        {
            var window = samples.AsSpan(i, Math.Min(windowSize, samples.Length - i));
            float sum = 0f;
            foreach (var s in window) sum += s * s;
            var rms = MathF.Sqrt(sum / window.Length);
            if (rms > threshold) { start = Math.Max(0, i - windowSize); break; }
        }

        int end = samples.Length;
        for (int i = samples.Length - windowSize; i >= 0; i -= windowSize / 2)
        {
            var window = samples.AsSpan(i, Math.Min(windowSize, samples.Length - i));
            float sum = 0f;
            foreach (var s in window) sum += s * s;
            var rms = MathF.Sqrt(sum / window.Length);
            if (rms > threshold) { end = Math.Min(samples.Length, i + windowSize * 2); break; }
        }

        if (start >= end) return samples;
        var result = samples[start..end];
        DiagnosticLogger.Shared.Log($"VAD: trimmed {samples.Length} → {result.Length} samples");
        return result;
    }

    public void Dispose() => UnloadModel();
}
