import Foundation

/// Engine-side quality signals for the just-completed batch transcription.
/// Optional so engines without calibrated confidence/timing support remain unchanged.
public struct TranscriptionDiagnostics: Codable, Sendable, Equatable {
    public let aggregateConfidence: Float?
    public let minimumTokenConfidence: Float?
    public let lowConfidenceTailTokensRemoved: Int
    public let vadTrimmedSeconds: Double
    public let uncertain: Bool

    public init(aggregateConfidence: Float? = nil,
                minimumTokenConfidence: Float? = nil,
                lowConfidenceTailTokensRemoved: Int = 0,
                vadTrimmedSeconds: Double = 0,
                uncertain: Bool = false) {
        self.aggregateConfidence = aggregateConfidence
        self.minimumTokenConfidence = minimumTokenConfidence
        self.lowConfidenceTailTokensRemoved = lowConfidenceTailTokensRemoved
        self.vadTrimmedSeconds = vadTrimmedSeconds
        self.uncertain = uncertain
    }
}

/// Backend-agnostic transcription engine. Conformers: WhisperEngine (whisper.cpp/Metal),
/// ParakeetEngine (FluidAudio/ANE). Audio currency is [Float] @ 16 kHz mono Float32 —
/// the format AudioRecorder already produces.
public protocol TranscriptionEngine: AnyObject {
    var engineID: String { get }            // "whisper" | "parakeet"
    var isLoaded: Bool { get }
    var supportsStreaming: Bool { get }     // whisper: true; parakeet v1: false
    /// Whether `transcribe`'s `prompt` parameter influences recognition at all.
    /// whisper: true (initial-prompt priming); parakeet: false (no prompt equivalent).
    /// Callers must not do expensive prompt-building work (e.g. full-screen OCR) for an
    /// engine that ignores the result.
    var supportsPrompt: Bool { get }
    /// Quality signals from the latest completed batch transcription, if the engine exposes them.
    var lastDiagnostics: TranscriptionDiagnostics? { get }
    var keepModelLoaded: String { get set }  // "auto" | "always" | "off"

    func loadModel(modelID: String) async throws
    func unloadModel() async
    func startMemoryPressureMonitoring()

    func transcribe(samples: [Float],
                    language: String,
                    prompt: String?,
                    suppressRegex: String?) async throws -> String

    func transcribeStreaming(samples: [Float],
                             language: String,
                             prompt: String?,
                             suppressRegex: String?,
                             onPartialResult: @escaping (String) -> Void) async throws -> String
}

public extension TranscriptionEngine {
    var lastDiagnostics: TranscriptionDiagnostics? { nil }
}

public enum TranscriptionEngineError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed
    case streamingUnsupported
    case modelAssetsMissing(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:            return "No model loaded. Call loadModel() first."
        case .modelLoadFailed(let m):    return "Failed to load model \(m)"
        case .transcriptionFailed:       return "Transcription failed"
        case .streamingUnsupported:      return "This engine does not support live preview"
        case .modelAssetsMissing(let m): return "Model assets for \(m) are not downloaded"
        }
    }
}
