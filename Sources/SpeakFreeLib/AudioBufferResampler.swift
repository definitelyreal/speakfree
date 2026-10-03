// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-suggestion:unverified · session:unknown · 2026-10-02
import AVFoundation

/// One instance per tap. The converter retains filter history between callbacks;
/// each input buffer is supplied exactly once, even when it asks for more input.
final class AudioBufferResampler {
    enum Conversion {
        case pending
        /// Storage is borrowed until the next call, on the same tap queue.
        case output(AVAudioPCMBuffer, start: Double)
        case failure(Failure)
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidInput
        case nonfiniteInput
        case allocationFailed
        case converter(domain: String?, code: Int?)
        case inputNotConsumed
        case unexpectedEnd
        case invalidOutput

        var description: String {
            switch self {
            case .invalidInput: return "invalid input format or timestamp"
            case .nonfiniteInput: return "nonfinite microphone samples"
            case .allocationFailed: return "conversion buffer allocation failed"
            case .converter(let domain, let code):
                return "converter failed (\(domain ?? "no domain"), \(code.map(String.init) ?? "no code"))"
            case .inputNotConsumed: return "converter did not consume the microphone buffer"
            case .unexpectedEnd: return "converter ended a live microphone stream"
            case .invalidOutput: return "invalid converted microphone samples"
            }
        }
    }

    /// Injectable converter boundary: tests exercise status/error handling without a mic.
    typealias ConvertInto = (AVAudioPCMBuffer, @escaping AVAudioConverterInputBlock) -> (AVAudioConverterOutputStatus, NSError?)
    private let convertInto: ConvertInto
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var output: AVAudioPCMBuffer?
    private var nextOutputTime: Double?
    private var terminalFailure: Failure?

    convenience init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.init(inputFormat: inputFormat, outputFormat: outputFormat) { output, input in
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            return (status, error)
        }
    }

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat, convertInto: @escaping ConvertInto) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.convertInto = convertInto
    }

    /// A failure is terminal: a later successful conversion cannot close over missing input
    /// and label it as continuous audio. Ordinary converter buffering remains `.pending`.
    func convert(_ input: AVAudioPCMBuffer, at time: Double) -> Conversion {
        if let terminalFailure { return .failure(terminalFailure) }
        guard time.isFinite, input.format == inputFormat,
              inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              outputFormat.sampleRate.isFinite, outputFormat.sampleRate > 0 else { return fail(.invalidInput) }
        guard input.frameLength > 0 else { return .pending }
        guard Self.hasFiniteSamples(input) else { return fail(.nonfiniteInput) }
        let needed = ceil(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 1
        guard needed.isFinite, needed > 0, needed <= Double(AVAudioFrameCount.max) else { return fail(.allocationFailed) }
        let capacity = AVAudioFrameCount(needed)
        if output == nil || output!.frameCapacity < capacity {
            output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let output else { return fail(.allocationFailed) }
        output.frameLength = 0
        var supplied = false
        let (status, error) = convertInto(output) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            // Default `.normal` priming has no output latency. Buffered first input must
            // keep its timestamp even if the converter emits nothing until a later call.
            if self.nextOutputTime == nil { self.nextOutputTime = time }
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, status != .error else { return fail(.converter(domain: error?.domain, code: error?.code)) }
        guard status != .endOfStream else { return fail(.unexpectedEnd) }
        // A tap buffer expires after this callback. Do not silently discard an input the
        // converter did not request. Max-capacity reuse covers the measured streaming path;
        // an unhandled retained-output state requires recovery, not invented continuity.
        guard supplied else { return fail(.inputNotConsumed) }
        guard output.frameLength > 0 else { return .pending }
        guard Self.hasFiniteSamples(output), let start = nextOutputTime else { return fail(.invalidOutput) }
        nextOutputTime = start + Double(output.frameLength) / outputFormat.sampleRate
        // `.inputRanDry` can still have valid output, per AVAudioConverter's contract.
        return .output(output, start: start)
    }

    private func fail(_ reason: Failure) -> Conversion {
        terminalFailure = reason
        return .failure(reason)
    }

    private static func hasFiniteSamples(_ buffer: AVAudioPCMBuffer) -> Bool {
        let count = Int(buffer.frameLength), stride = buffer.stride
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return false }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<count where !channels[channel][frame * stride].isFinite { return false }
            }
        case .pcmFormatFloat64:
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                let samples = count * Int(audio.mNumberChannels)
                guard let data = audio.mData, samples <= Int(audio.mDataByteSize) / MemoryLayout<Double>.size else { return false }
                let values = data.assumingMemoryBound(to: Double.self)
                for index in 0..<samples where !values[index].isFinite { return false }
            }
        case .pcmFormatInt16, .pcmFormatInt32: break
        default: return false
        }
        return true
    }
}
