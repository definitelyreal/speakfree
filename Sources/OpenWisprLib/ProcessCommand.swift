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
        let samples = engine.engineID == "parakeet" ? (try? Self.loadSamples(from: wavURL)) : nil

        let raw: String
        do {
            raw = try runBlocking {
                try await transcriber.transcribe(audioURL: wavURL, samples: samples, prompt: nil)
            }
        } catch {
            throw Error.transcriptionFailed(error)
        }
        let punctuationMode = config.spokenPunctuation ?? .hybrid
        let input = TextPipeline.Input(
            raw: raw,
            cursorContextText: nil,
            screenContextText: nil,
            punctuationMode: punctuationMode,
            styleMode: .none,
            glossaryWords: nil
        )
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

    /// Decode a wav file to 16 kHz mono Float32 samples (the engine audio currency).
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else { throw Error.fileNotFound(url.path) }

        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(file.length)
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
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return [] }

        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, statusPtr in
            if fed { statusPtr.pointee = .noDataNow; return nil }
            fed = true
            statusPtr.pointee = .haveData
            return inBuf
        }
        if let convError { throw Error.transcriptionFailed(convError) }
        guard let ch = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
