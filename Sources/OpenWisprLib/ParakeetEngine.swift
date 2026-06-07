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
///
/// ## Concurrency model
/// All mutable model state (the `AsrManager`, the loaded model id, and the in-flight transcription
/// counter) is owned by a private `actor Core`. The actor serializes lifecycle so a `transcribe`
/// can never run against a manager that `unload` is tearing down, and two concurrent `load`s can
/// never both build a manager (load is single-flight via a stored in-progress `Task`). The outer
/// class is a thin facade that delegates to `Core` and maintains an NSLock-guarded `isLoaded`
/// mirror for the synchronous protocol getter.
public final class ParakeetEngine: TranscriptionEngine {

    // MARK: - Core (owns all mutable model state)

    /// Serializes all model lifecycle and transcription against a single owner. Every mutable
    /// field lives here; nothing outside the actor touches the manager.
    private actor Core {

        /// FluidAudio audio constraints (mirror `ASRConstants`): 1 s of trailing silence (16k
        /// samples) is appended to capture final-word punctuation, but only when staying under the
        /// 15 s single-chunk encoder cap (240k samples).
        private static let trailingSilenceSamples = 16_000
        private static let maxSingleChunkSamples = 240_000

        /// FluidAudio's loaded ASR manager (actor). `nil` until `load` succeeds.
        private var manager: AsrManager?

        /// The model identifier currently loaded, e.g. "parakeet-tdt-0.6b-v3". `nil` when unloaded.
        private var loadedModelID: String?

        /// Count of transcriptions currently in flight. `unload` drains this to 0 before tearing
        /// the manager down so an in-flight `transcribe` never sees a `nil` / cleaned-up manager.
        private var active = 0

        /// In-progress load, if any. Concurrent `load` callers await this single Task instead of
        /// each building their own manager (single-flight). `Task` is a value type, so the paired
        /// `loadToken` (a monotonically increasing id) lets the owning call detect whether it is
        /// still the in-flight load before clearing the slot.
        private var loadInFlight: Task<Void, Error>?
        private var loadToken = 0

        /// Notifies the outer facade so it can update its NSLock-guarded `isLoaded` mirror.
        private let onLoadedChange: @Sendable (Bool) -> Void

        init(onLoadedChange: @escaping @Sendable (Bool) -> Void) {
            self.onLoadedChange = onLoadedChange
        }

        var isLoaded: Bool { manager != nil }

        // MARK: Load (single-flight)

        func load(modelID: String) async throws {
            // Idempotent: requested model already loaded.
            if loadedModelID == modelID, manager != nil { return }

            // Coalesce concurrent loads onto one Task. If a load is already running, await it; if it
            // landed on the model we want, we're done — otherwise fall through and load ours.
            if let existing = loadInFlight {
                _ = try? await existing.value
                if loadedModelID == modelID, manager != nil { return }
            }

            loadToken += 1
            let myToken = loadToken
            let task = Task { try await self.performLoad(modelID: modelID) }
            loadInFlight = task
            defer { if loadToken == myToken { loadInFlight = nil } }
            try await task.value
        }

        private func performLoad(modelID: String) async throws {
            // Re-check inside the (now serialized) load: a prior single-flight load may have already
            // satisfied this request while we were queued.
            if loadedModelID == modelID, manager != nil { return }

            // Preflight: never trigger a 600MB download inside the transcribe path. Acquisition
            // happens via the Settings download UI; if assets aren't present, surface the error.
            guard ParakeetModelManager.shared.isModelDownloaded(modelID) else {
                throw TranscriptionEngineError.modelAssetsMissing(modelID)
            }

            DiagnosticLogger.shared.log("ParakeetEngine: loading model \(modelID)")
            let loadStart = CFAbsoluteTimeGetCurrent()

            // Unit 5 owns download + cache + load. Prefer the load-only entry point (Unit B); fall
            // back to `loadedModels` until that method lands.
            let models: AsrModels
            do {
                models = try await ParakeetModelManager.shared.loadedModels(modelID)
            } catch let error as ASRError {
                throw ParakeetEngine.map(error, modelID: modelID)
            } catch let error as TranscriptionEngineError {
                throw error
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

            // Tear down a previously-loaded (different) manager before replacing it, so its CoreML
            // state isn't leaked. No in-flight transcriptions can target it: `transcribe` holds the
            // actor while incrementing `active`, and we're on the actor now.
            if let old = manager {
                manager = nil
                loadedModelID = nil
                await old.cleanup()
            }

            manager = mgr
            loadedModelID = modelID

            let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
            DiagnosticLogger.shared.log("ParakeetEngine: model loaded in \(String(format: "%.2f", loadTime))s")
            onLoadedChange(true)
        }

        // MARK: Transcribe

        func transcribe(samples: [Float], language: String) async throws -> String {
            guard let mgr = manager, let modelID = loadedModelID else {
                throw TranscriptionEngineError.modelNotLoaded
            }
            active += 1
            defer { active -= 1 }

            // Trailing-silence pad so the final word's punctuation lands, but only under the
            // single-chunk encoder cap (FluidAudio auto-chunks anything longer internally).
            var audio = samples
            if audio.count + Core.trailingSilenceSamples <= Core.maxSingleChunkSamples {
                audio += [Float](repeating: 0, count: Core.trailingSilenceSamples)
            }

            // Language hint: v3 forwards an explicit Language for concrete codes (including "en");
            // nil only for auto/empty codes or v2 (English-only, ignores the hint).
            let isV3 = EngineCatalog.versionString(forParakeetModelID: modelID) != "v2"
            let hint = ParakeetEngine.languageHint(for: language, isV3: isV3)

            // Build a fresh decoder state sized to the loaded model's LSTM layer count.
            var decoderState = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)

            let result: ASRResult
            do {
                result = try await mgr.transcribe(audio, decoderState: &decoderState, language: hint)
            } catch let error as ASRError {
                throw ParakeetEngine.map(error, modelID: modelID)
            } catch {
                throw TranscriptionEngineError.transcriptionFailed
            }

            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: Unload

        func unload() async {
            // Drain in-flight transcriptions before teardown so none observe a cleaned-up manager.
            while active > 0 { await Task.yield() }
            guard let m = manager else { return }
            manager = nil
            loadedModelID = nil
            await m.cleanup()
            DiagnosticLogger.shared.log("ParakeetEngine: model unloaded")
            onLoadedChange(false)
        }
    }

    // MARK: - Facade state

    /// The serialized owner of all model state. Lazily wired so it can capture `self`'s mirror
    /// updater without an initializer ordering problem.
    private var core: Core!

    /// Guards `keepModelLoaded` and the `isLoadedMirror` — the only fields the synchronous protocol
    /// surface touches. The actor owns everything else.
    private let stateLock = NSLock()

    /// Synchronous mirror of `Core.isLoaded`, updated under `stateLock` after a load/unload
    /// completes. The protocol's sync `isLoaded` getter reads this; it can lag a load/unload that is
    /// still in flight, which is the intended "has a model finished loading" semantics.
    private var isLoadedMirror = false

    /// How the model should be managed: "auto", "always", "off". Stored for parity with
    /// `WhisperEngine`; FluidAudio caches the compiled CoreML models on disk, so reload is cheap.
    private var keepModelLoadedStorage = "auto"

    public init() {
        self.core = Core(onLoadedChange: { [weak self] loaded in
            guard let self else { return }
            self.stateLock.lock()
            self.isLoadedMirror = loaded
            self.stateLock.unlock()
        })
    }

    // MARK: - TranscriptionEngine identity

    public var engineID: String { "parakeet" }

    public var supportsStreaming: Bool { false }

    public var isLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isLoadedMirror
    }

    public var keepModelLoaded: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return keepModelLoadedStorage
        }
        set {
            stateLock.lock()
            keepModelLoadedStorage = newValue
            stateLock.unlock()
        }
    }

    // MARK: - Model Lifecycle

    /// Ensure the FluidAudio models for `modelID` are downloaded + loaded, then construct and load
    /// an `AsrManager`. Idempotent and single-flight: concurrent calls coalesce, and a no-op if the
    /// same model is already loaded.
    ///
    /// - Parameter modelID: "parakeet-tdt-0.6b-v2" or "parakeet-tdt-0.6b-v3".
    public func loadModel(modelID: String) async throws {
        try await core.load(modelID: modelID)
    }

    /// Release the FluidAudio models and drop the manager. Waits for in-flight transcriptions to
    /// drain before teardown.
    public func unloadModel() async {
        await core.unload()
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
        try await core.transcribe(samples: samples, language: language)
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

    /// Compute the FluidAudio `Language?` hint. For v3, returns an explicit `Language(rawValue:)` on
    /// the region-stripped code for any concrete code (including "en"); returns nil only for
    /// auto/empty codes. Always nil for v2 (English-only, ignores it).
    private static func languageHint(for language: String, isV3: Bool) -> Language? {
        guard isV3 else { return nil }
        let code = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty, code != "auto" else { return nil }
        let primary = stripRegionSubtag(code)
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
