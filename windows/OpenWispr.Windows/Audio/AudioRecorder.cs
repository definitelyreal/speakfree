using NAudio.CoreAudioApi;
using NAudio.Wave;
using OpenWispr.Windows.Core;

namespace OpenWispr.Windows.Audio;

public class AudioRecorder : IDisposable
{
    private WasapiCapture? _capture;
    private readonly List<float> _samples = [];
    private bool _recording;

    public bool IsRecording => _recording;

    public void Start()
    {
        if (_recording) return;
        _samples.Clear();

        _capture = new WasapiCapture();
        _capture.WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(16000, 1);
        _capture.DataAvailable += OnDataAvailable;
        _capture.StartRecording();
        _recording = true;
        DiagnosticLogger.Shared.Log("AudioRecorder: started");
    }

    public float[] Stop()
    {
        if (!_recording) return [];
        _capture?.StopRecording();
        _capture?.Dispose();
        _capture = null;
        _recording = false;
        var result = _samples.ToArray();
        _samples.Clear();
        DiagnosticLogger.Shared.Log($"AudioRecorder: stopped, {result.Length} samples");
        return result;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        for (int i = 0; i < e.BytesRecorded; i += 4)
            if (i + 4 <= e.Buffer.Length)
                _samples.Add(BitConverter.ToSingle(e.Buffer, i));
    }

    public void Dispose()
    {
        _capture?.Dispose();
        _capture = null;
    }
}
