import Foundation

/// Engine-side quality signals for the just-completed batch transcription.
/// Optional so engines without calibrated confidence/timing support remain unchanged.
public struct TranscriptionDiagnostics: Codable, Sendable, Equatable {
    public let aggregateConfidence: Float?
    public let minimumTokenConfidence: Float?
    public let lowConfidenceTailTokensRemoved: Int
    public let vadTrimmedSeconds: Double
    public let uncertain: Bool
    /// Words the engine was unsure of, in spoken order, with the engine's own score (0...1):
    /// Whisper token probability, Parakeet token confidence (the minimum over the word's
    /// tokens). Only words below the engine's threshold are kept. nil for engines or paths
    /// that do not expose per-token scores (the whisper CLI fallback) and for older sidecars.
    /// Feeds the dictation trace and `speakfree match`.
    public let lowConfidenceWords: [DictationTrace.WordScore]?

    /// Which model instance produced the take: "ane" (Neural Engine) or "cpu-standin" (CPU
    /// copy used while the Neural Engine model is still being prepared). Nil for engines
    /// without that distinction and for sidecars written before 2026-09-24.
    public let inferencePath: String?

    public init(aggregateConfidence: Float? = nil,
                minimumTokenConfidence: Float? = nil,
                lowConfidenceTailTokensRemoved: Int = 0,
                vadTrimmedSeconds: Double = 0,
                uncertain: Bool = false,
                lowConfidenceWords: [DictationTrace.WordScore]? = nil,
                inferencePath: String? = nil) {
        self.aggregateConfidence = aggregateConfidence
        self.minimumTokenConfidence = minimumTokenConfidence
        self.lowConfidenceTailTokensRemoved = lowConfidenceTailTokensRemoved
        self.vadTrimmedSeconds = vadTrimmedSeconds
        self.uncertain = uncertain
        self.lowConfidenceWords = lowConfidenceWords
        self.inferencePath = inferencePath
    }
}

public extension TranscriptionDiagnostics {
    /// The same signals without the per-word scores (used when another engine's text replaced
    /// this engine's, so the words no longer describe the saved raw text).
    func withoutWords() -> TranscriptionDiagnostics {
        TranscriptionDiagnostics(aggregateConfidence: aggregateConfidence,
                                 minimumTokenConfidence: minimumTokenConfidence,
                                 lowConfidenceTailTokensRemoved: lowConfidenceTailTokensRemoved,
                                 vadTrimmedSeconds: vadTrimmedSeconds, uncertain: uncertain,
                                 inferencePath: inferencePath)
    }
}

/// Per-take record of what produced a transcription, carried in a task-local so concurrent
/// transcriptions (a new dictation finishing while an older one, or a crash recovery, is still
/// running) can never read each other's diagnostics from shared engine state.
///
/// Usage: `TakeRecorder.$current.withValue(recorder) { try await transcriber.transcribe(...) }`.
/// Engines write `engineDiagnostics` from inside the call (Whisper atomically on its queue,
/// Parakeet from its diagnostics callback); Transcriber records which engine's text it returned.
public final class TakeRecorder: @unchecked Sendable {
    @TaskLocal public static var current: TakeRecorder?

    private let lock = NSLock()
    private var _diagnostics: TranscriptionDiagnostics?
    private var _engine: String?
    private var _engineTextKept = false

    public init() {}

    /// Diagnostics from the engine pass whose text this take is built on (nil if none).
    public var engineDiagnostics: TranscriptionDiagnostics? {
        get { lock.lock(); defer { lock.unlock() }; return _diagnostics }
        set { lock.lock(); _diagnostics = newValue; lock.unlock() }
    }
    /// Engine that produced the returned text ("whisper" or "parakeet"); nil if never set.
    public var engine: String? {
        get { lock.lock(); defer { lock.unlock() }; return _engine }
        set { lock.lock(); _engine = newValue; lock.unlock() }
    }
    /// Model that produced the returned text when it differs from the transcriber's own
    /// (a whisper rescue of a Parakeet take); nil otherwise.
    public var model: String? {
        get { lock.lock(); defer { lock.unlock() }; return _model }
        set { lock.lock(); _model = newValue; lock.unlock() }
    }
    private var _model: String?
    /// Model instance that ran the engine pass ("ane", "cpu-standin", or the engine ID).
    public var inferencePath: String? {
        get { lock.lock(); defer { lock.unlock() }; return _inferencePath }
        set { lock.lock(); _inferencePath = newValue; lock.unlock() }
    }
    private var _inferencePath: String?
    /// Seconds the engine pass waited for a model load (summed over empty-result retries).
    public var modelWaitSeconds: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _modelWaitSeconds }
        set { lock.lock(); _modelWaitSeconds = newValue; lock.unlock() }
    }
    private var _modelWaitSeconds: Double?
    /// True when the returned text is the in-process engine's own output, so its per-word
    /// scores describe it. False after a CLI fallback or a rescue that replaced the text.
    public var engineTextKept: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _engineTextKept }
        set { lock.lock(); _engineTextKept = newValue; lock.unlock() }
    }

    /// Unsure words that describe the returned text, or none.
    public var unsureWords: [DictationTrace.WordScore] {
        engineTextKept ? (engineDiagnostics?.lowConfidenceWords ?? []) : []
    }
    /// Diagnostics for the meta sidecar: word scores only when they describe the saved text.
    public var diagnosticsForMeta: TranscriptionDiagnostics? {
        engineTextKept ? engineDiagnostics : engineDiagnostics?.withoutWords()
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
