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

    // MARK: - Audio constraints

    /// FluidAudio audio constraints (mirror `ASRConstants`). 3 s of trailing silence is appended
    /// so the TDT decoder can flush its final tokens — the old 1 s pad silently truncated the
    /// tail clause (see transcribe()). 240k samples = the 15 s single-chunk encoder cap.
    /// Internal, not private, so tests assert against these exact production values instead of
    /// mirroring them (the mirrors drifted once already).
    static let trailingSilenceSamples = 48_000
    static let maxSingleChunkSamples = 240_000

    /// Target length after the trailing-silence pad: pad up to `trailingSilenceSamples`, but
    /// never past the single-chunk cap — longer clips keep as much pad as fits.
    static func paddedSampleCount(_ count: Int) -> Int {
        count + min(trailingSilenceSamples, max(0, maxSingleChunkSamples - count))
    }

    // MARK: - Core (owns all mutable model state)

    /// Serializes all model lifecycle and transcription against a single owner. Every mutable
    /// field lives here; nothing outside the actor touches the manager.
    private actor Core {

        /// FluidAudio's loaded ASR manager (actor). `nil` until `load` succeeds.
        private var manager: AsrManager?

        /// The model identifier currently loaded, e.g. "parakeet-tdt-0.6b-v3". `nil` when unloaded.
        private var loadedModelID: String?

        /// Count of transcriptions currently in flight. `unload` (and a model-replacing `load`)
        /// drains this to 0 before tearing the manager down so an in-flight `transcribe` never sees
        /// a cleaned-up manager. Note: incrementing `active` does NOT by itself protect the manager
        /// across the `await mgr.transcribe` suspension — the actor is released at every await, so a
        /// teardown could interleave. Protection comes from the `tearingDown` gate (no new transcribe
        /// starts once teardown begins) plus the drain (teardown waits for `active == 0`).
        private var active = 0

        /// Set true at the START of any teardown (unload, or a model-replacing load) and cleared
        /// once teardown completes. While set, no new `transcribe` may begin, which lets the drain
        /// loop reach `active == 0` and guarantees no transcribe holds a reference to a manager that
        /// is about to be `cleanup()`'d.
        private var tearingDown = false

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
            // state isn't leaked. Same discipline as `unload`: an in-flight `transcribe` captured the
            // old manager via `let mgr = manager` and keeps using it across the `await mgr.transcribe`
            // suspension, so we must (1) gate new transcribes, (2) publish the mirror false, (3) drain
            // active to 0, (4) cleanup the OLD manager — all BEFORE assigning the new one.
            if let old = manager {
                tearingDown = true
                onLoadedChange(false)
                while active > 0 { await Task.yield() }
                manager = nil
                loadedModelID = nil
                await old.cleanup()
                tearingDown = false
            }

            manager = mgr
            loadedModelID = modelID

            let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
            DiagnosticLogger.shared.log("ParakeetEngine: model loaded in \(String(format: "%.2f", loadTime))s")
            onLoadedChange(true)
        }

        // MARK: Transcribe

        func transcribe(samples: [Float], language: String) async throws -> String {
            // Gate on `tearingDown` BEFORE bumping `active` so no transcribe begins once a teardown
            // (unload or model-replacing load) has started. This is what lets the drain loop finish.
            guard let mgr = manager, let modelID = loadedModelID, !tearingDown else {
                throw TranscriptionEngineError.modelNotLoaded
            }
            active += 1
            defer { active -= 1 }

            // Trailing-silence pad. Parakeet's TDT decoder needs trailing audio to "flush"
            // its final tokens — with too little, it stops early and SILENTLY DROPS the last
            // clause (verified 2026-06-12: a 7.8s clip lost "and happy to send a screener"
            // with the old 1s pad; ~3s recovers it). The pad is near-free: it's silence and
            // the ANE encoder cost is ~flat regardless of length (measured ~110ms at both
            // 7.8s and 10.8s). Pad up to `trailingSilenceSamples`, but never past the
            // single-chunk cap so longer clips keep as much pad as fits (FluidAudio
            // auto-chunks anything beyond the cap).
            var audio = samples
            let pad = ParakeetEngine.paddedSampleCount(audio.count) - audio.count
            if pad > 0 {
                audio += [Float](repeating: 0, count: pad)
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
            // Gate new transcribes first, then publish the mirror false SYNCHRONOUSLY before niling
            // the manager — this closes the stale-mirror window where isLoaded == true but the
            // manager is already gone. Only then drain in-flight transcriptions and cleanup, so none
            // observe a cleaned-up manager.
            tearingDown = true
            onLoadedChange(false)
            while active > 0 { await Task.yield() }
            let m = manager
            manager = nil
            loadedModelID = nil
            await m?.cleanup()
            tearingDown = false
            DiagnosticLogger.shared.log("ParakeetEngine: model unloaded")
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

    /// Parakeet has no prompt/initial-text knob — `transcribe`'s `prompt` is ignored, so
    /// prompt-building work (screen-context OCR) must be skipped for this engine.
    public var supportsPrompt: Bool { false }

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
    /// Internal so tests exercise the real rule instead of a mirror.
    static func languageHint(for language: String, isV3: Bool) -> Language? {
        guard isV3 else { return nil }
        let code = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty, code != "auto" else { return nil }
        let primary = stripRegionSubtag(code)
        return Language(rawValue: primary)
    }

    /// Strip an IETF region subtag: "en-US"/"en_US" → "en".
    static func stripRegionSubtag(_ code: String) -> String {
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
