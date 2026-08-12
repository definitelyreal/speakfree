import Foundation
import AVFoundation

/// Result of running the full pipeline on a wav file. JSON-encodable for
/// headless testing and corpus-tuning scripts.
public struct ProcessResult: Encodable {
    public let raw: String
    public let processed: String
    public let styled: String

    public init(raw: String, processed: String, styled: String) {
        self.raw = raw
        self.processed = processed
        self.styled = styled
    }
}

/// Headless pipeline runner — same code path as the app's `finalizeRecording`.
/// Entry point for `speakfree process <wav>` and for end-to-end audio tests.
public enum ProcessCommand {

    public enum Error: Swift.Error, LocalizedError {
        case fileNotFound(String)
        case transcriptionFailed(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .transcriptionFailed(let e): return "Transcription failed: \(e.localizedDescription)"
            }
        }
    }

    /// Run the full pipeline (transcribe → TextPipeline) on a wav file.
    /// Uses Config.load() for model size, language, and punctuation mode.
    public static func run(wavURL: URL) throws -> ProcessResult {
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw Error.fileNotFound(wavURL.path)
        }
        let config = Config.load()
        let engine = EngineFactory.make(config: config)
        let modelID = engine.engineID == "parakeet"
            ? (config.parakeetModel ?? "parakeet-tdt-0.6b-v3")
            : config.modelSize
        let transcriber = Transcriber(engine: engine, modelID: modelID, language: config.language)

        // Parakeet has no on-disk CLI fallback — it needs in-memory [Float]@16k samples.
        // Whisper keeps its file/CLI path here (samples=nil) so the headless `process` command
        // and golden tests don't spin up the in-process ggml/Metal backend, which aborts in a
        // device-less test process. The GUI app still uses in-process whisper via finalizeRecording.
        // Parakeet needs decoded samples. Propagate decode failures as
        // Error.transcriptionFailed rather than swallowing them into a generic failure.
        let samples: [Float]?
        if engine.engineID == "parakeet" {
            let decoded: [Float]
            do {
                decoded = try Self.loadSamples(from: wavURL)
            } catch {
                throw Error.transcriptionFailed(error)
            }
            guard !decoded.isEmpty else {
                throw Error.transcriptionFailed(NSError(
                    domain: "ProcessCommand", code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "Decoded audio is empty"]
                ))
            }
            samples = decoded
        } else {
            samples = nil
        }

        let raw: String
        do {
            raw = try runBlocking {
                try await transcriber.transcribe(audioURL: wavURL, samples: samples, prompt: nil)
            }
        } catch {
            throw Error.transcriptionFailed(error)
        }
        // Aligned to the app (Michael 2026-08-12): this was the last `?? .hybrid` outlier,
        // so `speakfree process` punctuated keyless legacy configs differently than
        // dictation did. Behavior change is confined to configs with no spokenPunctuation
        // key: they now run Automatic Only here too, matching the app and the UI label.
        let punctuationMode = config.effectivePunctuationMode
        // Pass the real duration when we decoded samples so the seam-dedup gate can tell
        // single-window recordings from chunkable ones (nil = dedup stays enabled).
        let duration = samples.map { Double($0.count) / 16000.0 }
        let input = TextPipeline.Input(raw: raw, punctuationMode: punctuationMode,
                                       audioDurationSeconds: duration)
        let result = TextPipeline.run(input)
        return ProcessResult(raw: raw, processed: result.processedText, styled: result.finalText)
    }

    /// Run an async throwing closure from a synchronous context, blocking until it returns.
    /// Used because `run` is sync (CLI + XCTest) but the engine API is async-only.
    private static func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Swift.Error>!
        Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    /// Maximum decodable input duration (seconds). Rejects oversized WAVs before
    /// allocating buffers, bounding memory use and guarding the UInt32 frame casts.
    /// 60 min (was 30): the 30-min ceiling silently killed the wav-rescue arbiter and
    /// recovery of long sessions (2026-07-25 audit A2/H7). Not higher: the decode path
    /// briefly holds TWO copies of the float samples (inBuf + Array), so 60 min peaks
    /// ~440 MB (codex review #5); 90 would flirt with memory pressure under a loaded
    /// model. Empirical: 29 min transcribes in 4.1s at 368 MB peak. Beyond 60 min use
    /// Transcriber.transcribeFile (chunked, uncapped).
    private static let maxInputDurationSeconds: Double = 60 * 60

    /// Maximum bytes for any single Float32 PCM allocation (input buffer or
    /// resampled output). The duration cap alone is insufficient: a within-cap WAV at
    /// a high sample rate with many channels still over-allocates. ~512 MB.
    private static let maxDecodedBytes: Double = 512 * 1024 * 1024

    /// Decode a wav file to 16 kHz mono Float32 samples (the engine audio currency).
    /// Public so the perf-regression harness (T2.0) can decode the audio golden fixtures
    /// through the exact same production decode path the app uses.
    public static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else { throw Error.fileNotFound(url.path) }

        // Security: reject oversized inputs before allocating, and guard the
        // AVAudioFrameCount (UInt32) casts below against overflow.
        let frameLength = file.length
        guard srcFormat.sampleRate > 0 else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid sample rate"]
            ))
        }
        let durationSeconds = Double(frameLength) / srcFormat.sampleRate
        guard durationSeconds <= maxInputDurationSeconds else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Audio too long: \(Int(durationSeconds))s exceeds limit of \(Int(maxInputDurationSeconds))s"]
            ))
        }
        guard frameLength >= 0, frameLength <= Int64(AVAudioFrameCount.max) else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Audio frame count out of range"]
            ))
        }

        // Memory budget: the duration cap doesn't bound a short-but-dense WAV
        // (high sample rate × many channels). Reject if the input buffer's
        // Float32 footprint (frames × channels × 4 bytes) exceeds the budget.
        let channelCount = Double(srcFormat.channelCount)
        let inputBytes = Double(frameLength) * channelCount * 4.0
        guard inputBytes <= maxDecodedBytes else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -7,
                userInfo: [NSLocalizedDescriptionKey:
                    "Audio too large: input buffer (\(Int(inputBytes / (1024 * 1024))) MB) exceeds budget"]
            ))
        }

        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(frameLength)
        ) else { return [] }
        try file.read(into: inBuf)

        // Fast path: already 16k mono float — copy straight out.
        if srcFormat.sampleRate == 16_000, srcFormat.channelCount == 1,
           let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }

        // Otherwise resample/downmix via AVAudioConverter.
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return [] }
        let ratio = 16_000.0 / srcFormat.sampleRate
        // Guard the UInt32 cast: clamp the computed output capacity to AVAudioFrameCount.max.
        let outCapacityDouble = Double(inBuf.frameLength) * ratio + 1024
        guard outCapacityDouble <= Double(AVAudioFrameCount.max) else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Resampled frame count out of range"]
            ))
        }
        // Memory budget: target is mono Float32, so estimated output bytes are
        // frames × 4. Reject before allocating the output buffer.
        let outputBytes = outCapacityDouble * 4.0
        guard outputBytes <= maxDecodedBytes else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -8,
                userInfo: [NSLocalizedDescriptionKey:
                    "Audio too large: resampled output (\(Int(outputBytes / (1024 * 1024))) MB) exceeds budget"]
            ))
        }
        let outCapacity = AVAudioFrameCount(outCapacityDouble)

        // Drain loop: a single converter.convert can truncate the resampled tail.
        // Feed the input buffer once then signal .endOfStream; call convert into
        // fresh output buffers repeatedly, appending each pass, until the converter
        // reports .endOfStream. Mirrors FluidAudio's AudioConverter drain loop.
        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, statusPtr in
            if fed { statusPtr.pointee = .endOfStream; return nil }
            fed = true
            statusPtr.pointee = .haveData
            return inBuf
        }

        func makeOutputBuffer(_ capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw Error.transcriptionFailed(NSError(
                    domain: "ProcessCommand", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to allocate conversion buffer"]
                ))
            }
            return buf
        }

        func append(_ buffer: AVAudioPCMBuffer, into samples: inout [Float]) {
            guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }

        var resampled: [Float] = []
        resampled.reserveCapacity(Int(outCapacityDouble))

        // First pass: convert the main data using the estimated capacity.
        var convError: NSError?
        let firstOut = try makeOutputBuffer(outCapacity)
        let firstStatus = converter.convert(to: firstOut, error: &convError, withInputFrom: inputBlock)
        if let convError { throw Error.transcriptionFailed(convError) }
        guard firstStatus != .error else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: Int(firstStatus.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed (status \(firstStatus.rawValue))"]
            ))
        }
        append(firstOut, into: &resampled)

        // Drain remaining frames into fresh buffers until end-of-stream.
        if firstStatus != .endOfStream {
            while true {
                let out = try makeOutputBuffer(4096)
                let status = converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
                if let convError { throw Error.transcriptionFailed(convError) }
                guard status != .error else {
                    throw Error.transcriptionFailed(NSError(
                        domain: "ProcessCommand", code: Int(status.rawValue),
                        userInfo: [NSLocalizedDescriptionKey:
                            "Audio conversion failed (status \(status.rawValue))"]
                    ))
                }
                append(out, into: &resampled)
                if status == .endOfStream { break }
            }
        }

        guard !resampled.isEmpty else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion produced no samples"]
            ))
        }
        return resampled
    }

    /// Decode a sub-range of an open audio file to 16 kHz mono Float32 samples.
    /// No duration cap — designed for the file-transcription chunk loop.
    /// The caller is responsible for opening and closing the AVAudioFile handle.
    /// - Parameters:
    ///   - file: Open AVAudioFile positioned anywhere; this method seeks it to `startFrame`.
    ///   - startFrame: First frame to read (in the file's native sample rate).
    ///   - frameCount: Number of frames to read (clamped to the file's remaining frames).
    static func loadSamplesChunk(from file: AVAudioFile,
                                 startFrame: AVAudioFramePosition,
                                 frameCount: AVAudioFrameCount) throws -> [Float] {
        let srcFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw Error.transcriptionFailed(NSError(
                domain: "ProcessCommand", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create target audio format"]))
        }

        // Clamp to available frames.
        let available = max(0, file.length - startFrame)
        let clampedCount = min(AVAudioFramePosition(frameCount), available)
        guard clampedCount > 0 else { return [] }

        file.framePosition = startFrame

        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(clampedCount)
        ) else { return [] }
        try file.read(into: inBuf, frameCount: AVAudioFrameCount(clampedCount))

        // Fast path: already 16k mono float.
        if srcFormat.sampleRate == 16_000, srcFormat.channelCount == 1,
           let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }

        // Resample/downmix via AVAudioConverter (same drain-loop pattern as loadSamples).
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return [] }
        let ratio = 16_000.0 / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1024)

        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, statusPtr in
            if fed { statusPtr.pointee = .endOfStream; return nil }
            fed = true; statusPtr.pointee = .haveData; return inBuf
        }

        func makeBuf(_ cap: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            guard let b = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else {
                throw Error.transcriptionFailed(NSError(domain: "ProcessCommand", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to allocate conversion buffer"]))
            }
            return b
        }

        var resampled: [Float] = []
        var convError: NSError?
        let firstOut = try makeBuf(outCapacity)
        let firstStatus = converter.convert(to: firstOut, error: &convError, withInputFrom: inputBlock)
        if let e = convError { throw Error.transcriptionFailed(e) }
        if let ch = firstOut.floatChannelData, firstOut.frameLength > 0 {
            resampled.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(firstOut.frameLength)))
        }
        if firstStatus != .endOfStream {
            while true {
                let out = try makeBuf(4096)
                let status = converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
                if let e = convError { throw Error.transcriptionFailed(e) }
                if let ch = out.floatChannelData, out.frameLength > 0 {
                    resampled.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
                }
                if status == .endOfStream { break }
            }
        }
        return resampled
    }
}
