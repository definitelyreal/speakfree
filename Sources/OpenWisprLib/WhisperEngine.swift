import Foundation
import CWhisper

/// Wraps the whisper.cpp C library for in-process transcription.
/// Keeps the model loaded in memory between transcriptions for speed.
class WhisperEngine {
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

    var isLoaded: Bool {
        var result = false
        engineQueue.sync { result = self.context != nil }
        return result
    }

    deinit {
        engineQueue.sync { unloadModelLocked() }
    }

    // MARK: - Model Lifecycle

    /// Load a GGML model from disk. Metal GPU is used automatically.
    func loadModel(path: String) throws {
        var thrownError: Error?
        engineQueue.sync {
            do { try loadModelLocked(path: path) } catch { thrownError = error }
        }
        if let e = thrownError { throw e }
    }

    private func loadModelLocked(path: String) throws {
        // Don't reload if same model is already loaded
        if let loaded = loadedModelPath, loaded == path, context != nil { return }

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

    /// Free the model from memory.
    func unloadModel() {
        engineQueue.sync { unloadModelLocked() }
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
    func transcribe(
        samples: [Float],
        language: String = "en",
        prompt: String? = nil,
        suppressRegex: String? = nil,
        threadCount: Int? = nil
    ) throws -> String {
        var result: String = ""
        var thrownError: Error?
        engineQueue.sync {
            do { result = try transcribeLocked(samples: samples, language: language, prompt: prompt, suppressRegex: suppressRegex, threadCount: threadCount) }
            catch { thrownError = error }
        }
        if let e = thrownError { throw e }
        return result
    }

    private func transcribeLocked(
        samples: [Float],
        language: String = "en",
        prompt: String? = nil,
        suppressRegex: String? = nil,
        threadCount: Int? = nil
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

        // Trim leading/trailing silence to improve speed and accuracy
        let trimmedSamples = trimSilence(samples)

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
    func transcribeStreaming(
        samples: [Float],
        language: String = "en",
        prompt: String? = nil,
        suppressRegex: String? = nil,
        onPartialResult: @escaping (String) -> Void
    ) throws -> String {
        var result: String = ""
        var thrownError: Error?
        engineQueue.sync {
            do { result = try transcribeStreamingLocked(samples: samples, language: language, prompt: prompt, suppressRegex: suppressRegex, onPartialResult: onPartialResult) }
            catch { thrownError = error }
        }
        if let e = thrownError { throw e }
        return result
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
                DiagnosticLogger.shared.log("WhisperEngine: skipping no-speech segment (p=\(String(format: "%.2f", noSpeechProb))): \"\(segText.prefix(50))\"")
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
                DiagnosticLogger.shared.log("WhisperEngine: salvaged segment (p=\(String(format: "%.2f", bestSalvageProb))): \"\(salvaged.prefix(50))\"")
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
    /// Returns the trimmed samples, or the original if no silence detected.
    func trimSilence(_ samples: [Float], threshold: Float = 0.01) -> [Float] {
        let windowSize = 1600  // 100ms at 16kHz
        guard samples.count > windowSize * 2 else { return samples }

        // Find first window with energy above threshold
        var start = 0
        for i in stride(from: 0, to: samples.count - windowSize, by: windowSize / 2) {
            let window = samples[i..<min(i + windowSize, samples.count)]
            let rms = sqrt(window.map { $0 * $0 }.reduce(0, +) / Float(window.count))
            if rms > threshold {
                start = max(0, i - windowSize)  // Include a small buffer before speech
                break
            }
        }

        // Find last window with energy above threshold
        var end = samples.count
        for i in stride(from: samples.count - windowSize, through: 0, by: -windowSize / 2) {
            let window = samples[i..<min(i + windowSize, samples.count)]
            let rms = sqrt(window.map { $0 * $0 }.reduce(0, +) / Float(window.count))
            if rms > threshold {
                end = min(samples.count, i + windowSize * 2)  // Include buffer after speech
                break
            }
        }

        if start >= end { return samples }
        let trimmed = Array(samples[start..<end])
        if trimmed.count < samples.count {
            DiagnosticLogger.shared.log("VAD: trimmed \(samples.count) → \(trimmed.count) samples (\(Int(Double(samples.count - trimmed.count) / 16000.0 * 1000))ms silence removed)")
        }
        return trimmed
    }

    // MARK: - Smart Loading

    func startMemoryPressureMonitoring() {
        memoryPressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
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

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load Whisper model at \(path)"
        case .modelNotLoaded:
            return "No model loaded. Call loadModel() first."
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
