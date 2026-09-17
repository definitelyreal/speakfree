// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import AVFoundation

/// One instance per tap. The converter retains filter history between callbacks;
/// each input buffer is supplied exactly once, even when it asks for more input.
final class AudioBufferResampler {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var output: AVAudioPCMBuffer?

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// The returned storage is borrowed until the next call, on the same tap queue.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)) + 1
        if output == nil || output!.frameCapacity < capacity {
            output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let output else { return nil }
        output.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
