import Foundation
import CWhisper

/// Wraps the whisper.cpp C library for in-process transcription.
/// Keeps the model loaded in memory between transcriptions for speed.
///
/// Conforms to `TranscriptionEngine`. The protocol surface is `async`, but whisper.cpp
/// is synchronous and runs under a serial `engineQueue`. The async members below are thin
/// shims that hop the existing serial-queue + `*Locked` machinery; the UAF/Metal-assert
/// safety (single owner of `context`, deinit drains the queue) is unchanged.
class WhisperEngine: TranscriptionEngine {
    private var context: OpaquePointer?  // whisper_context*
    private var loadedModelPath: String?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastTranscriptionTime: Date?
    private var languageMismatchCount = 0
    private let languageMismatchThreshold = 3

    /// Serializes all load/transcribe/unload operations. Public methods dispatch onto this
    /// queue; private *Locked methods run only from within the queue to prevent re-entrancy.
    private let engineQueue = DispatchQueue(label: "com.speakfree.engine", qos: .userInitiated)

    /// How the model should be managed: "auto", "always", "off"
    var keepModelLoaded: String = "auto"

    // MARK: - TranscriptionEngine identity

    var engineID: String { "whisper" }
    var supportsStreaming: Bool { true }
    var supportsPrompt: Bool { true }

    var isLoaded: Bool {
        var result = false
        engineQueue.sync { result = self.context != nil }
        return result
    }

    deinit {
        engineQueue.sync { unloadModelLocked() }
    }

    // MARK: - Model Lifecycle

    /// Protocol entry point: load a whisper model identified by a size string
    /// (e.g. "large-v3-turbo"). Resolves the on-disk GGML path via `Transcriber.findModel`
    /// and delegates to the existing synchronous `loadModel(path:)`.
    func loadModel(modelID: String) async throws {
        guard let modelPath = Transcriber.findModel(modelSize: modelID) else {
            throw TranscriptionEngineError.modelLoadFailed(modelID)
        }
        // Dispatch the serial-queue body via `async` + continuation so we don't block a
        // Swift-concurrency cooperative thread for the full model load (pool starvation).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async {
                do {
                    try self.loadModelLocked(path: modelPath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Load a GGML model from disk. Metal GPU is used automatically.
    func loadModel(path: String) throws {
        var thrownError: Error?
        engineQueue.sync {
            do { try loadModelLocked(path: path) } catch { thrownError = error }
        }
        if let e = thrownError { throw e }
    }

    /// ggml ≥ 0.10 (Homebrew, dev builds) ships its compute backends (CPU/Metal/BLAS) as
    /// runtime-loaded plugins in libexec/*.so; unless `ggml_backend_load_all()` runs first,
    /// the backend registry is EMPTY and `whisper_init_*` hard-aborts inside
    /// `GGML_ASSERT(device)` — the 2026-08-19 crash loop (two SIGABRTs at model load).
    /// Resolved via dlsym so builds against the vendored ggml 0.9.x release dylibs (which
    /// register their backends statically and may lack the symbol) need no link-time change.
    /// Returns false only when the registry is introspectable AND provably empty.
    static func computeBackendsAvailable() -> Bool {
        struct Once {
            static let result: Bool = {
                let main = dlopen(nil, RTLD_NOW)
                if let sym = dlsym(main, "ggml_backend_load_all") {
                    unsafeBitCast(sym, to: (@convention(c) () -> Void).self)()
                }
                if let sym = dlsym(main, "ggml_backend_dev_count") {
                    return unsafeBitCast(sym, to: (@convention(c) () -> Int).self)() > 0
                }
                return true  // registry not introspectable — static-backend build
            }()
        }
        return Once.result
    }

    private func loadModelLocked(path: String) throws {
        // Don't reload if same model is already loaded
        if let loaded = loadedModelPath, loaded == path, context != nil { return }

        // A guarded throw here surfaces as a failed dictation; letting whisper_init see an
        // empty backend registry is a process abort (and a crash loop while the engine
        // setting stays "whisper").
        guard Self.computeBackendsAvailable() else {
            DiagnosticLogger.shared.log(
                "WhisperEngine: no ggml compute backends available — refusing to init (would abort)")
            throw WhisperEngineError.noComputeBackends
        }

        // Unload any existing model first
        if context != nil { unloadModelLocked() }

        DiagnosticLogger.shared.log("WhisperEngine: loading model from \(path)")
        let loadStart = CFAbsoluteTimeGetCurrent()

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(path, cparams) else {
            throw WhisperEngineError.modelLoadFailed(path)
        }

        let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
        DiagnosticLogger.shared.log("WhisperEngine: model loaded in \(String(format: "%.2f", loadTime))s")

        self.context = ctx
        self.loadedModelPath = path
        DispatchQueue.main.async { [weak self] in self?.startMemoryPressureMonitoring() }
    }

    /// Free the model from memory. Async shim over the serial-queue body so it satisfies
    /// the `TranscriptionEngine` protocol; the actual teardown still runs on `engineQueue`.
    func unloadModel() async {
        // Dispatch the serial-queue body via `async` + continuation so we don't block a
        // Swift-concurrency cooperative thread during teardown.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engineQueue.async {
                self.unloadModelLocked()
                continuation.resume()
            }
        }
    }

    private func unloadModelLocked() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let ctx = context {
            whisper_free(ctx)
        }
        context = nil
        loadedModelPath = nil
    }

    // MARK: - Transcription

    /// Transcribe PCM Float32 audio samples (16kHz, mono).
    /// Async shim conforming to `TranscriptionEngine`; the inference still runs synchronously
    /// on the serial `engineQueue` via the untouched `transcribeLocked` machinery. The
    /// internal `threadCount` knob defaults to nil (whisper picks the core count itself).
    func transcribe(
        samples: [Float],
        language: String,
        prompt: String?,
        suppressRegex: String?
    ) async throws -> String {
        // Dispatch the serial-queue body via `async` + continuation so we don't block a
        // Swift-concurrency cooperative thread for the full inference (pool starvation).
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            engineQueue.async {
                do {
                    let result = try self.transcribeLocked(samples: samples, language: language, prompt: prompt, suppressRegex: suppressRegex, threadCount: nil)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Like `transcribe` but fires `progressHandler(0…100)` as whisper processes its
    /// internal 30-second windows. Also checks cancellation between windows via `isCancelled`.
    func transcribeWithProgress(
        samples: [Float],
        language: String,
        prompt: String?,
        suppressRegex: String?,
        skipSilenceTrim: Bool = false,
        progressHandler: @escaping (Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            engineQueue.async {
                do {
                    let result = try self.transcribeLocked(
                        samples: samples,
                        language: language,
                        prompt: prompt,
                        suppressRegex: suppressRegex,
                        threadCount: nil,
                        skipSilenceTrim: skipSilenceTrim,
                        progressHandler: progressHandler,
                        isCancelled: isCancelled
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func transcribeLocked(
        samples: [Float],
        language: String = "en",
        prompt: String? = nil,
        suppressRegex: String? = nil,
        threadCount: Int? = nil,
        skipSilenceTrim: Bool = false,
        progressHandler: ((Int) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> String {
        guard let ctx = context else {
            throw WhisperEngineError.modelNotLoaded
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(threadCount ?? ProcessInfo.processInfo.activeProcessorCount)
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        // Anti-hallucination: tighter entropy and logprob thresholds suppress low-confidence
        // segments before they reach the no-speech filter. Evidence: whisper.cpp #1724/#2286,
        // arXiv 2505.12969. Defaults are 2.4 / -1.0; these are more conservative.
        params.entropy_thold = 2.8
        params.logprob_thold = -1.25

        // Language
        let langCString = strdup(language)
        params.language = UnsafePointer(langCString)
        defer { free(langCString) }

        if language == "auto" {
            params.detect_language = true
        }

        // Initial prompt (for context/vocabulary priming)
        var promptCString: UnsafeMutablePointer<CChar>? = nil
        if let prompt = prompt, !prompt.isEmpty {
            promptCString = strdup(prompt)
            params.initial_prompt = UnsafePointer(promptCString)
        }
        defer { free(promptCString) }

        // Suppress regex (for spoken punctuation mode) — validate before passing to C library
        var regexCString: UnsafeMutablePointer<CChar>? = nil
        if let regex = suppressRegex, !regex.isEmpty {
            if (try? NSRegularExpression(pattern: regex)) != nil {
                regexCString = strdup(regex)
                params.suppress_regex = UnsafePointer(regexCString)
            } else {
                DiagnosticLogger.shared.log("WhisperEngine: invalid suppress_regex ignored: \(regex)")
            }
        }
        defer { free(regexCString) }

        // Trim leading/trailing silence (skipped for file-transcription path — long silences
        // in meetings/lectures are legitimate content, not noise to strip).
        let trimmedSamples = skipSilenceTrim ? samples : trimSilence(samples)

        // Progress + cancellation callbacks (file-transcription path only).
        if let progressHandler = progressHandler {
            let box = ProgressCallbackContext(progressHandler: progressHandler,
                                              isCancelled: isCancelled ?? { false })
            let ctx2 = Unmanaged.passRetained(box).toOpaque()
            params.progress_callback_user_data = ctx2
            params.progress_callback = { _, _, progress, userdata in
                let b = Unmanaged<ProgressCallbackContext>.fromOpaque(userdata!).takeUnretainedValue()
                DispatchQueue.main.async { b.progressHandler(Int(progress)) }
            }
            params.abort_callback_user_data = ctx2
            params.abort_callback = { userdata -> Bool in
                let b = Unmanaged<ProgressCallbackContext>.fromOpaque(userdata!).takeUnretainedValue()
                return b.isCancelled()
            }
            defer { Unmanaged<ProgressCallbackContext>.fromOpaque(ctx2).release() }

            // Run inference with callbacks
            DiagnosticLogger.shared.log("WhisperEngine: transcribing \(trimmedSamples.count) samples (\(String(format: "%.1f", Double(trimmedSamples.count) / 16000.0))s audio) [with progress]")
            let inferenceStart = CFAbsoluteTimeGetCurrent()
            let result = trimmedSamples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(trimmedSamples.count))
            }
            let inferenceTime = CFAbsoluteTimeGetCurrent() - inferenceStart
            if result != 0 {
                DiagnosticLogger.shared.log("WhisperEngine: transcription failed (code \(result))")
                throw WhisperEngineError.transcriptionFailed
            }
            let nSegments = whisper_full_n_segments(ctx)
            let text = collectSegments(ctx: ctx, nSegments: nSegments)
            checkLanguageMismatch(ctx: ctx, configuredLanguage: language)
            lastTranscriptionTime = Date()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DiagnosticLogger.shared.log("WhisperEngine: inference \(String(format: "%.2f", inferenceTime))s, result \(trimmed.count) chars")
            return trimmed
        }

        // Run inference
        DiagnosticLogger.shared.log("WhisperEngine: transcribing \(trimmedSamples.count) samples (\(String(format: "%.1f", Double(trimmedSamples.count) / 16000.0))s audio)")
        let inferenceStart = CFAbsoluteTimeGetCurrent()
        let result = trimmedSamples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(trimmedSamples.count))
        }
        let inferenceTime = CFAbsoluteTimeGetCurrent() - inferenceStart

        if result != 0 {
            DiagnosticLogger.shared.log("WhisperEngine: transcription failed (code \(result))")
            throw WhisperEngineError.transcriptionFailed
        }

        // Collect output segments, filtering by no-speech probability
        let nSegments = whisper_full_n_segments(ctx)
        let text = collectSegments(ctx: ctx, nSegments: nSegments)

        // Check detected language for mismatch
        checkLanguageMismatch(ctx: ctx, configuredLanguage: language)

        lastTranscriptionTime = Date()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DiagnosticLogger.shared.log("WhisperEngine: inference \(String(format: "%.2f", inferenceTime))s, result \(trimmed.count) chars")
        return trimmed
    }

    // MARK: - Streaming Transcription

    /// Transcribe audio incrementally, calling onPartialResult with each new segment.
    /// Designed to be called periodically with a growing audio buffer during recording.
    /// Returns the final accumulated text.
    /// Async shim conforming to `TranscriptionEngine`. The streaming inference + C-callback
    /// machinery is untouched in `transcribeStreamingLocked`; partials are still delivered on
    /// the main thread by that callback. This wrapper only hops the serial-queue body.
    func transcribeStreaming(
        samples: [Float],
        language: String,
        prompt: String?,
        suppressRegex: String?,
        onPartialResult: @escaping (String) -> Void
    ) async throws -> String {
        // Dispatch the serial-queue body via `async` + continuation so we don't block a
        // Swift-concurrency cooperative thread for the full inference (pool starvation).
        // `onPartialResult` still fires from within `transcribeStreamingLocked` as before;
        // the continuation resumes once with the final accumulated text.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            engineQueue.async {
                do {
                    let result = try self.transcribeStreamingLocked(samples: samples, language: language, prompt: prompt, suppressRegex: suppressRegex, onPartialResult: onPartialResult)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func transcribeStreamingLocked(
        samples: [Float],
        language: String = "en",
        prompt: String? = nil,
        suppressRegex: String? = nil,
        onPartialResult: @escaping (String) -> Void
    ) throws -> String {
        guard let ctx = context else { throw WhisperEngineError.modelNotLoaded }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(ProcessInfo.processInfo.activeProcessorCount / 2, 1))
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.single_segment = false
        params.entropy_thold = 2.8
        params.logprob_thold = -1.25

        // Language
        let langCString = strdup(language)
        params.language = UnsafePointer(langCString)
        defer { free(langCString) }

        if language == "auto" {
            params.detect_language = true
        }

        // Initial prompt
        var promptCString: UnsafeMutablePointer<CChar>? = nil
        if let prompt = prompt, !prompt.isEmpty {
            promptCString = strdup(prompt)
            params.initial_prompt = UnsafePointer(promptCString)
        }
        defer { free(promptCString) }

        // Suppress regex — validate before passing to C library
        var regexCString: UnsafeMutablePointer<CChar>? = nil
        if let regex = suppressRegex, !regex.isEmpty {
            if (try? NSRegularExpression(pattern: regex)) != nil {
                regexCString = strdup(regex)
                params.suppress_regex = UnsafePointer(regexCString)
            } else {
                DiagnosticLogger.shared.log("WhisperEngine: invalid suppress_regex ignored: \(regex)")
            }
        }
        defer { free(regexCString) }

        // Set up new segment callback via C function pointer
        // We use a reference-counted context object passed through an opaque pointer
        let callbackCtx = StreamingCallbackContext(onPartialResult)
        let callbackPtr = Unmanaged.passRetained(callbackCtx).toOpaque()

        params.new_segment_callback_user_data = callbackPtr
        params.new_segment_callback = { (ctx, state, nNew, userData) in
            guard let userData = userData, let ctx = ctx else { return }
            let cbCtx = Unmanaged<StreamingCallbackContext>.fromOpaque(userData).takeUnretainedValue()

            let nSegments = whisper_full_n_segments(ctx)
            var fullText = ""
            for i in 0..<nSegments {
                if let cStr = whisper_full_get_segment_text(ctx, i) {
                    fullText += String(cString: cStr)
                }
            }

            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != cbCtx.lastText {
                cbCtx.lastText = trimmed
                // Snapshot value types before crossing the async boundary — cbCtx may
                // be freed (via Unmanaged.release below) before the block runs.
                let snapshot = trimmed
                let cb = cbCtx.onPartialResult
                DispatchQueue.main.async {
                    cb(snapshot)
                }
            }
        }

        // Run inference
        let inferenceStart = CFAbsoluteTimeGetCurrent()
        DiagnosticLogger.shared.log("WhisperEngine: streaming transcribe \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s audio)")

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(samples.count))
        }

        // Release the callback context (balances passRetained above)
        Unmanaged<StreamingCallbackContext>.fromOpaque(callbackPtr).release()

        let inferenceTime = CFAbsoluteTimeGetCurrent() - inferenceStart

        if result != 0 {
            DiagnosticLogger.shared.log("WhisperEngine: streaming transcription failed (code \(result))")
            throw WhisperEngineError.transcriptionFailed
        }

        // Collect final text, filtering by no-speech probability
        let nSegments = whisper_full_n_segments(ctx)
        let text = collectSegments(ctx: ctx, nSegments: nSegments)

        lastTranscriptionTime = Date()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DiagnosticLogger.shared.log("WhisperEngine: streaming inference \(String(format: "%.2f", inferenceTime))s, result \(trimmed.count) chars")
        return trimmed
    }

    // MARK: - Segment Collection (shared between batch and streaming paths)

    /// Collect whisper segments, filtering by no-speech probability.
    /// If all segments are filtered, salvages the highest-confidence one (prob < 0.9).
    private func collectSegments(ctx: OpaquePointer, nSegments: Int32) -> String {
        var text = ""
        var bestSalvageSeg: Int32 = -1
        var bestSalvageProb: Float = 1.0

        for i in 0..<nSegments {
            let noSpeechProb = whisper_full_get_segment_no_speech_prob(ctx, i)
            if noSpeechProb > 0.6 {
                let segText = whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? ""
                // Log length only — transcript content must never reach the diagnostic log.
                DiagnosticLogger.shared.log("WhisperEngine: skipping no-speech segment (p=\(String(format: "%.2f", noSpeechProb)), \(segText.count) chars)")
                if noSpeechProb < bestSalvageProb {
                    bestSalvageProb = noSpeechProb
                    bestSalvageSeg = i
                }
                continue
            }
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cStr)
            }
        }

        // Salvage: if all segments were filtered, return the lowest-prob no-speech segment
        // as long as it's below the silence ceiling (< 0.9 = not true silence).
        if text.isEmpty, bestSalvageSeg >= 0, bestSalvageProb < 0.9 {
            if let cStr = whisper_full_get_segment_text(ctx, bestSalvageSeg) {
                let salvaged = String(cString: cStr)
                DiagnosticLogger.shared.log("WhisperEngine: salvaged segment (p=\(String(format: "%.2f", bestSalvageProb)), \(salvaged.count) chars)")
                text = salvaged
            }
        }

        return text
    }

    // MARK: - Language Mismatch Detection

    /// Check if the detected language differs from the configured language.
    /// Logs a warning after consecutive mismatches.
    private func checkLanguageMismatch(ctx: OpaquePointer, configuredLanguage: String) {
        guard configuredLanguage != "auto" else {
            languageMismatchCount = 0
            return
        }

        let detectedLangId = whisper_full_lang_id(ctx)
        guard let langStr = whisper_lang_str(detectedLangId) else {
            return
        }
        let detected = String(cString: langStr)

        if detected != configuredLanguage {
            languageMismatchCount += 1
            DiagnosticLogger.shared.log("WhisperEngine: language mismatch — configured '\(configuredLanguage)' but detected '\(detected)' (count: \(languageMismatchCount))")
            if languageMismatchCount >= languageMismatchThreshold {
                DiagnosticLogger.shared.log("WhisperEngine: \(languageMismatchCount) consecutive language mismatches — user may be speaking \(detected)")
                languageMismatchCount = 0
            }
        } else {
            languageMismatchCount = 0
        }
    }

    // MARK: - Voice Activity Detection (silence trimming)

    /// Trim leading and trailing silence from PCM samples.
    /// Uses an adaptive threshold — a fraction of the recording's own peak RMS —
    /// so quiet microphones (AirPods, soft speakers) aren't over-trimmed.
    func trimSilence(_ samples: [Float]) -> [Float] {
        let windowSize = 1600  // 100ms at 16kHz
        guard samples.count > windowSize * 2 else { return samples }

        // Compute per-window RMS values once
        var windowRMS: [Float] = []
        var i = 0
        while i + windowSize <= samples.count {
            let window = samples[i..<i + windowSize]
            let rms = sqrt(window.map { $0 * $0 }.reduce(0, +) / Float(window.count))
            windowRMS.append(rms)
            i += windowSize / 2
        }

        // Adaptive threshold: 8% of peak RMS, floored at 0.001 to avoid treating
        // genuine near-silence as speech when the recording is completely empty.
        let peakRMS = windowRMS.max() ?? 0
        let threshold = max(0.001, peakRMS * 0.08)

        // Find first voiced window
        var startWindow = 0
        for (idx, rms) in windowRMS.enumerated() {
            if rms > threshold {
                startWindow = idx
                break
            }
        }

        // Find last voiced window
        var endWindow = windowRMS.count - 1
        for idx in stride(from: windowRMS.count - 1, through: 0, by: -1) {
            if windowRMS[idx] > threshold {
                endWindow = idx
                break
            }
        }

        // Convert window indices back to sample indices, with safety buffers. The LEADING
        // buffer is 3 windows (was 1): a soft-onset first word (a quiet consonant, or a word
        // spoken before the speaker leans in) can sit just under the adaptive threshold, and a
        // 1-window pad clipped it. 3 windows (~300ms) protects the attack without re-admitting
        // real silence (the 80% over-trim guard below still bounds worst case).
        let startSample = max(0, startWindow * (windowSize / 2) - 3 * windowSize)
        let endSample   = min(samples.count, (endWindow + 1) * (windowSize / 2) + windowSize * 2)

        if startSample >= endSample { return samples }

        // Safety: never trim more than 80% of the recording — if that much would be
        // cut it means the threshold misfired, and returning the full audio is safer.
        let kept = endSample - startSample
        if kept < samples.count / 5 { return samples }

        let trimmed = Array(samples[startSample..<endSample])
        if trimmed.count < samples.count {
            DiagnosticLogger.shared.log(
                "VAD: trimmed \(samples.count) → \(trimmed.count) samples "
                + "(\(Int(Double(samples.count - trimmed.count) / 16000.0 * 1000))ms silence removed, "
                + "threshold=\(String(format: "%.4f", threshold)) peak=\(String(format: "%.4f", peakRMS)))"
            )
        }
        return trimmed
    }

    // MARK: - Smart Loading

    func startMemoryPressureMonitoring() {
        memoryPressureSource?.cancel()
        // Run the handler on engineQueue (NOT .main) so its reads of lastTranscriptionTime /
        // keepModelLoaded are serialized with the transcribe machinery that writes them (both
        // now on engineQueue). The handler only reads state, logs, and dispatches the unload —
        // no main-thread/AppKit work — so engineQueue is safe.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: engineQueue
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.keepModelLoaded != "always" else { return }

            let pressureLevel = source.data  // .warning or .critical

            if pressureLevel.contains(.critical) {
                // Critical: always unload — async to avoid re-entering engineQueue from main
                DiagnosticLogger.shared.log("WhisperEngine: critical memory pressure — unloading model")
                print("WhisperEngine: unloading model (critical memory pressure)")
                self.engineQueue.async { [weak self] in self?.unloadModelLocked() }
            } else if pressureLevel.contains(.warning) {
                // Warning: unload if idle for > 60 seconds
                let idleSeconds = self.lastTranscriptionTime.map { Date().timeIntervalSince($0) } ?? Double.infinity
                if idleSeconds > 60 {
                    print("WhisperEngine: unloading model (memory pressure warning, idle \(Int(idleSeconds))s)")
                    self.engineQueue.async { [weak self] in self?.unloadModelLocked() }
                } else {
                    print("WhisperEngine: keeping model loaded (memory pressure warning, but used \(Int(idleSeconds))s ago)")
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Call when system is under memory pressure to free the model.
    func handleMemoryPressure() {
        guard keepModelLoaded != "always" else { return }
        DiagnosticLogger.shared.log("WhisperEngine: memory pressure — unloading model")
        print("WhisperEngine: unloading model due to memory pressure")
        engineQueue.async { [weak self] in self?.unloadModelLocked() }
    }

    /// Approximate RSS of the loaded model in bytes, or 0 if unloaded.
    var estimatedMemoryUsage: UInt64 {
        var path: String?
        engineQueue.sync { path = self.loadedModelPath }
        guard let path = path else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let diskSize = attrs?[.size] as? UInt64 ?? 0
        // Loaded model is roughly 1.5-2x disk size
        return diskSize * 2
    }
}

/// Reference-counted context for file-transcription progress + cancellation C callbacks.
private class ProgressCallbackContext {
    let progressHandler: (Int) -> Void
    let isCancelled: () -> Bool
    init(progressHandler: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool) {
        self.progressHandler = progressHandler
        self.isCancelled = isCancelled
    }
}

/// Reference-counted context passed through whisper's C callback as an opaque pointer.
private class StreamingCallbackContext {
    let onPartialResult: (String) -> Void
    var lastText = ""
    init(_ callback: @escaping (String) -> Void) { self.onPartialResult = callback }
}

enum WhisperEngineError: LocalizedError {
    case modelLoadFailed(String)
    case modelNotLoaded
    case transcriptionFailed
    case noComputeBackends

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load Whisper model at \(path)"
        case .modelNotLoaded:
            return "No model loaded. Call loadModel() first."
        case .transcriptionFailed:
            return "Transcription failed"
        case .noComputeBackends:
            return "Whisper's compute backends (CPU/Metal) failed to load"
        }
    }
}
