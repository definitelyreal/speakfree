import Foundation
import CWhisper

/// Wraps the whisper.cpp C library for in-process transcription.
/// Keeps the model loaded in memory between transcriptions for speed.
class WhisperEngine {
    private var context: OpaquePointer?  // whisper_context*
    private var loadedModelPath: String?
    private var idleTimer: Timer?

    /// Configurable idle timeout in seconds. 0 = never unload.
    var idleTimeout: TimeInterval = 300  // 5 min default

    var isLoaded: Bool { context != nil }

    deinit {
        unloadModel()
    }

    // MARK: - Model Lifecycle

    /// Load a GGML model from disk. Metal GPU is used automatically.
    func loadModel(path: String) throws {
        // Don't reload if same model is already loaded
        if let loaded = loadedModelPath, loaded == path, context != nil { return }

        // Unload any existing model first
        if context != nil { unloadModel() }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(path, cparams) else {
            throw WhisperEngineError.modelLoadFailed(path)
        }

        self.context = ctx
        self.loadedModelPath = path
        resetIdleTimer()
    }

    /// Free the model from memory.
    func unloadModel() {
        idleTimer?.invalidate()
        idleTimer = nil
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

        // Suppress regex (for spoken punctuation mode)
        var regexCString: UnsafeMutablePointer<CChar>? = nil
        if let regex = suppressRegex, !regex.isEmpty {
            regexCString = strdup(regex)
            params.suppress_regex = UnsafePointer(regexCString)
        }
        defer { free(regexCString) }

        // Run inference
        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(samples.count))
        }

        if result != 0 {
            throw WhisperEngineError.transcriptionFailed
        }

        // Collect output segments
        let nSegments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cStr)
            }
        }

        resetIdleTimer()

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Smart Loading

    func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil

        guard idleTimeout > 0 else { return }  // 0 = never unload

        // Timer must be scheduled on main run loop
        DispatchQueue.main.async { [weak self] in
            self?.idleTimer = Timer.scheduledTimer(withTimeInterval: self?.idleTimeout ?? 300, repeats: false) { [weak self] _ in
                self?.unloadModel()
                print("WhisperEngine: model unloaded after idle timeout")
            }
        }
    }

    /// Call when system is under memory pressure to free the model.
    func handleMemoryPressure() {
        if isLoaded {
            print("WhisperEngine: unloading model due to memory pressure")
            unloadModel()
        }
    }

    /// Approximate RSS of the loaded model in bytes, or 0 if unloaded.
    var estimatedMemoryUsage: UInt64 {
        guard let path = loadedModelPath else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let diskSize = attrs?[.size] as? UInt64 ?? 0
        // Loaded model is roughly 1.5-2x disk size
        return diskSize * 2
    }
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
