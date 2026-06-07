import Foundation
import FluidAudio

/// Wraps FluidAudio's Parakeet TDT ASR for in-process transcription on the Apple Neural Engine.
///
/// Conforms to `TranscriptionEngine`. FluidAudio is `async/await` end-to-end (its `AsrManager`
/// is an `actor`), so the protocol's async surface maps directly — no serial-queue shim is needed,
/// unlike `WhisperEngine`. Audio currency is `[Float]` @ 16 kHz mono Float32, exactly what
/// `AudioRecorder` already produces, so the Parakeet path needs zero conversion glue.
///
/// Batch-only for v1: `supportsStreaming = false`. Live preview is unsupported.
public final class ParakeetEngine: TranscriptionEngine {

    /// FluidAudio's loaded ASR manager (actor). `nil` until `loadModel` succeeds.
    private var manager: AsrManager?

    /// The FluidAudio model version currently loaded, used to gate the v3-only language hint.
    private var version: AsrModelVersion = .v3

    /// The model identifier currently loaded, e.g. "parakeet-tdt-0.6b-v3".
    private var loadedModelID: String?

    /// FluidAudio audio constraints (mirror `ASRConstants`): 1 s of trailing silence (16k samples)
    /// is appended to capture final-word punctuation, but only when staying under the 15 s
    /// single-chunk encoder cap (240k samples).
    private let trailingSilenceSamples = 16_000
    private let maxSingleChunkSamples = 240_000

    public init() {}

    // MARK: - TranscriptionEngine identity

    public var engineID: String { "parakeet" }

    public var supportsStreaming: Bool { false }

    public var isLoaded: Bool { manager != nil }

    /// How the model should be managed: "auto", "always", "off". Stored for parity with
    /// `WhisperEngine`; FluidAudio caches the compiled CoreML models on disk, so reload is cheap.
    public var keepModelLoaded: String = "auto"

    // MARK: - Model Lifecycle

    /// Ensure the FluidAudio models for `modelID` are downloaded + loaded, then construct and load
    /// an `AsrManager`. Idempotent: a no-op if the same model is already loaded.
    ///
    /// - Parameter modelID: "parakeet-tdt-0.6b-v2" or "parakeet-tdt-0.6b-v3".
    public func loadModel(modelID: String) async throws {
        // Idempotent: skip if the requested model is already loaded.
        if manager != nil, loadedModelID == modelID { return }

        // Map the model identifier to a FluidAudio version (defaults to v3 for unknown ids).
        let resolvedVersion = ParakeetEngine.version(for: modelID)

        DiagnosticLogger.shared.log("ParakeetEngine: loading model \(modelID)")
        let loadStart = CFAbsoluteTimeGetCurrent()

        let models: AsrModels
        do {
            // Unit 5 owns download + cache + load; returns a loaded `AsrModels`.
            models = try await ParakeetModelManager.shared.loadedModels(modelID)
        } catch let error as ASRError {
            throw ParakeetEngine.map(error, modelID: modelID)
        } catch {
            throw TranscriptionEngineError.modelLoadFailed(modelID)
        }

        let mgr = AsrManager(config: .default)
        do {
            try await mgr.loadModels(models)
        } catch let error as ASRError {
            throw ParakeetEngine.map(error, modelID: modelID)
        } catch {
            throw TranscriptionEngineError.modelLoadFailed(modelID)
        }

        let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
        DiagnosticLogger.shared.log("ParakeetEngine: model loaded in \(String(format: "%.2f", loadTime))s")

        self.manager = mgr
        self.version = resolvedVersion
        self.loadedModelID = modelID
    }

    /// Release the FluidAudio models and drop the manager.
    public func unloadModel() async {
        guard let mgr = manager else { return }
        // `cleanup()` is non-async but actor-isolated → must hop the actor.
        await mgr.cleanup()
        manager = nil
        loadedModelID = nil
        DiagnosticLogger.shared.log("ParakeetEngine: model unloaded")
    }

    /// No-op. FluidAudio runs on the Apple Neural Engine via CoreML and manages its own memory;
    /// it does not contend with whisper.cpp's Metal/GPU path and exposes no memory-pressure hook
    /// analogous to `WhisperEngine`'s context teardown. Unloading is driven explicitly via
    /// `unloadModel()` and the keep-loaded policy at the `Transcriber` layer.
    public func startMemoryPressureMonitoring() {}

    // MARK: - Transcription

    /// Transcribe `[Float]` 16 kHz mono samples. `prompt` and `suppressRegex` are ignored —
    /// Parakeet has no equivalent of whisper's initial prompt / token-suppression knobs.
    ///
    /// - Parameter language: short language code ("en", "fr", …) or "auto". The hint is only
    ///   forwarded to FluidAudio for v3 (multilingual); v2 is English-only and ignores it.
    public func transcribe(samples: [Float],
                           language: String,
                           prompt: String?,
                           suppressRegex: String?) async throws -> String {
        guard let mgr = manager else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        // Trailing-silence pad so the final word's punctuation lands, but only under the
        // single-chunk encoder cap (FluidAudio auto-chunks anything longer internally).
        var audio = samples
        if audio.count + trailingSilenceSamples <= maxSingleChunkSamples {
            audio += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        // Language hint: v3 only; nil for "auto"/"en"/v2; else strip region subtag (en-US → en).
        let hint = languageHint(for: language)

        // Build a fresh decoder state sized to the loaded model's LSTM layer count.
        var decoderState = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)

        let result: ASRResult
        do {
            result = try await mgr.transcribe(audio, decoderState: &decoderState, language: hint)
        } catch let error as ASRError {
            throw ParakeetEngine.map(error, modelID: loadedModelID ?? engineID)
        } catch {
            throw TranscriptionEngineError.transcriptionFailed
        }

        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parakeet (batch `AsrManager`) does not support live preview. Streaming would require
    /// FluidAudio's separate `StreamingAsrManager` / `SlidingWindowAsrManager`.
    public func transcribeStreaming(samples: [Float],
                                    language: String,
                                    prompt: String?,
                                    suppressRegex: String?,
                                    onPartialResult: @escaping (String) -> Void) async throws -> String {
        throw TranscriptionEngineError.streamingUnsupported
    }

    // MARK: - Helpers

    /// Map a speakfree model identifier to a FluidAudio `AsrModelVersion`. Unknown ids default to v3.
    private static func version(for modelID: String) -> AsrModelVersion {
        if modelID.hasSuffix("v2") { return .v2 }
        return .v3
    }

    /// Compute the FluidAudio `Language?` hint. Returns nil (auto-detect) for v2, "auto", or
    /// an empty/whitespace code; otherwise `Language(rawValue:)` on the region-stripped code.
    private func languageHint(for language: String) -> Language? {
        guard version == .v3 else { return nil }
        let code = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty, code != "auto" else { return nil }
        let primary = ParakeetEngine.stripRegionSubtag(code)
        return Language(rawValue: primary)
    }

    /// Strip an IETF region subtag: "en-US"/"en_US" → "en".
    private static func stripRegionSubtag(_ code: String) -> String {
        if let primary = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            return String(primary)
        }
        return code
    }

    /// Map FluidAudio `ASRError` into speakfree's engine-agnostic `TranscriptionEngineError`.
    private static func map(_ error: ASRError, modelID: String) -> TranscriptionEngineError {
        switch error {
        case .notInitialized:
            return .modelNotLoaded
        case .modelLoadFailed, .modelCompilationFailed:
            return .modelLoadFailed(modelID)
        case .invalidAudioData,
             .processingFailed,
             .unsupportedPlatform,
             .streamingConversionFailed,
             .fileAccessFailed:
            return .transcriptionFailed
        }
    }
}
