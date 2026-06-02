import Foundation

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
        let transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        let raw: String
        do {
            raw = try transcriber.transcribe(audioURL: wavURL)
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
}
