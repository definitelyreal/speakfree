import Foundation

public class Transcriber {
    /// Engine-agnostic backend, injected by EngineFactory (whisper or parakeet).
    public let engine: any TranscriptionEngine
    /// Model identifier for the active engine (whisper: a size like "large-v3-turbo";
    /// parakeet: "parakeet-tdt-0.6b-v3"). Doubles as the whisper model size for the CLI path.
    let modelID: String
    private let language: String
    public var suppressAutoPunctuation: Bool = false

    // MARK: - Engine lifecycle passthroughs (used by AppDelegate)

    public var supportsStreaming: Bool { engine.supportsStreaming }
    public var isLoaded: Bool { engine.isLoaded }
    public var keepModelLoaded: String {
        get { engine.keepModelLoaded }
        set { engine.keepModelLoaded = newValue }
    }
    public func unloadModel() async { await engine.unloadModel() }
    /// Synchronous unload bridge for non-async contexts (e.g. applicationWillTerminate,
    /// which cannot await). Blocks the calling thread until the async unload completes.
    public func unloadModelSync() {
        let sem = DispatchSemaphore(value: 0)
        Task { await engine.unloadModel(); sem.signal() }
        // Bound the wait so termination can't hang on a stuck unload — the OS
        // reclaims ANE/Metal resources on process exit regardless.
        _ = sem.wait(timeout: .now() + 2.0)
    }
    public func startMemoryPressureMonitoring() { engine.startMemoryPressureMonitoring() }
    /// Preload the model so the first dictation isn't a multi-second cold start.
    /// Parakeet compiles/loads ~470 MB of CoreML onto the Neural Engine on first
    /// use (~15-20s); warming it at launch makes the first transcription instant.
    /// No-ops if a model is already loaded; never triggers a download (loadModel
    /// throws .modelAssetsMissing for Parakeet when assets are absent, swallowed here).
    public func warmUp() async {
        if isLoaded { return }
        try? await engine.loadModel(modelID: modelID)
    }

    // Known whisper hallucinations on silence/noise.
    // "So." / "So," are among the most common silence hallucinations across all model sizes.
    private static let hallucinations: Set<String> = [
        "[MUSIC]", "(music)", "[music]", "Music.", "Music",
        "[APPLAUSE]", "(applause)", "[applause]", "Applause.",
        "[BLANK_AUDIO]", "[BLANK AUDIO]", "(blank audio)",
        "[SILENCE]", "(silence)", "[silence]",
        "[NOISE]", "(noise)", "[noise]",
        "Thank you.", "Thanks for watching.",
        "you", "You",
        "...", "\u{2026}",
        ".", "",
        // Short filler hallucinations common on near-silence
        "So.", "So,", "So...", "Hmm.", "Hmm,", "Hmm...",
        "Yeah.", "Yeah,", "Yes.", "No.",
        "Okay.", "OK.", "Oh.", "Oh,",
        "Um.", "Um,", "Uh.", "Uh,",
        "Hello.", "Hi.",
    ]

    private func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 { return true }
        if Self.hallucinations.contains(trimmed) { return true }

        // Case-insensitive check: "music", "Music", "MUSIC", "Music playing", etc.
        let lower = trimmed.lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
        let hallucinationPatterns = [
            "music", "applause", "blank audio", "silence", "noise",
            "thank you", "thanks for watching", "thanks for listening",
            "you", "the end", "bye",
            // Single filler words that only appear alone — "so" mid-sentence is real
            "so", "hmm", "yeah", "okay", "ok", "oh", "um", "uh", "hello", "hi",
        ]
        if hallucinationPatterns.contains(lower) { return true }

        // Subtitle/training data leakage
        let substringHallucinations = [
            "amara.org", "amara. org", "subtitles by", "translated by",
            "transcribed by", "captioned by", "captions by",
            "subscribe", "like and subscribe",
        ]
        for pattern in substringHallucinations {
            if lower.contains(pattern) { return true }
        }

        // Bracketed/parenthesized content like [Music], (applause), etc.
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
           (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            return true
        }

        return false
    }

    public init(engine: any TranscriptionEngine, modelID: String, language: String) {
        self.engine = engine
        self.modelID = modelID
        self.language = language
    }

    /// Transcribe using the in-process engine (fast, model stays loaded).
    /// Falls back to CLI (whisper only) if the engine fails or samples are not provided.
    public func transcribe(audioURL: URL, samples: [Float]? = nil, prompt: String? = nil) async throws -> String {
        let result: String

        // Try engine first if we have samples
        if let samples = samples, !samples.isEmpty {
            do {
                result = try await transcribeWithEngine(samples: samples, prompt: prompt)
            } catch {
                // CLI fallback is whisper-only; other engines rethrow.
                if engine.engineID == "whisper" {
                    print("WhisperEngine failed: \(error.localizedDescription) — falling back to CLI")
                    result = try transcribeWithCLI(audioURL: audioURL, prompt: prompt)
                } else {
                    throw error
                }
            }
        } else if engine.engineID == "whisper" {
            // Fallback to CLI (whisper only)
            result = try transcribeWithCLI(audioURL: audioURL, prompt: prompt)
        } else {
            // Non-whisper engines have no CLI fallback and need samples.
            throw TranscriptionEngineError.transcriptionFailed
        }

        // Strip non-speech characters whisper sometimes outputs (bullets, arrows, etc.)
        let cleaned = result.replacingOccurrences(of: "[•◦▪▸►▻→←↑↓★☆♦♥♠♣]", with: "", options: .regularExpression)

        // Filter known hallucinations from all engines + the CLI path
        if isHallucination(cleaned) {
            print("Transcriber: filtered hallucination: \"\(cleaned)\"")
            return ""
        }
        return cleaned
    }

    private func transcribeWithEngine(samples: [Float], prompt: String?) async throws -> String {
        // Ensure model is loaded (engine resolves its own on-disk/cache location)
        if !engine.isLoaded {
            try await engine.loadModel(modelID: modelID)
        }

        let suppressRegex = suppressAutoPunctuation ? "[,\\.\\?!;:\\-—]" : nil

        let raw = try await engine.transcribe(
            samples: samples,
            language: language,
            prompt: prompt,
            suppressRegex: suppressRegex
        )

        // Clean up output same way as CLI
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Streaming (live-preview) transcription — passthrough to the engine.
    /// Engines without native streaming throw TranscriptionEngineError.streamingUnsupported.
    /// `onPartialResult` is invoked on the main thread by the engine.
    public func transcribeStreaming(samples: [Float],
                                    language: String,
                                    prompt: String?,
                                    suppressRegex: String?,
                                    onPartialResult: @escaping (String) -> Void) async throws -> String {
        return try await engine.transcribeStreaming(
            samples: samples,
            language: language,
            prompt: prompt,
            suppressRegex: suppressRegex,
            onPartialResult: onPartialResult
        )
    }

    private func transcribeWithCLI(audioURL: URL, prompt: String? = nil) throws -> String {
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        guard let modelPath = Transcriber.findModel(modelSize: modelID) else {
            throw TranscriberError.modelNotFound(modelID)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        var args = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", language,
            "--no-timestamps",
            "-nt",
            "-t", "\(ProcessInfo.processInfo.activeProcessorCount)",
        ]
        // Spoken mode: suppress whisper's auto-punctuation so only spoken words produce symbols
        if suppressAutoPunctuation {
            args += ["--suppress-regex", "[,\\.\\?!;:\\-—]"]
        }
        // Pass context from text field so whisper can match style/terminology
        if let prompt = prompt, !prompt.isEmpty {
            args += ["--prompt", prompt]
        }
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let group = DispatchGroup()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        // Whisper outputs one line per segment with leading spaces — clean up but preserve line breaks.
        let rawOutput = String(data: data, encoding: .utf8) ?? ""
        let output = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderr.isEmpty { fputs("whisper-cpp: \(stderr)\n", Foundation.stderr) }
            throw TranscriberError.transcriptionFailed
        }

        return output
    }

    public static func findWhisperBinary() -> String? {
        // Check bundle first — self-contained app, no Homebrew required
        if let bundlePath = Bundle.main.bundlePath as String? {
            let bundled = bundlePath + "/Contents/MacOS/whisper-cli"
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        for name in ["whisper-cli", "whisper-cpp"] {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [name]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()

            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let result = result, !result.isEmpty {
                return result
            }
        }

        return nil
    }

    public static func modelExists(modelSize: String) -> Bool {
        return findModel(modelSize: modelSize) != nil
    }

    static func findModel(modelSize: String) -> String? {
        let modelFileName = "ggml-\(modelSize).bin"

        let candidates = [
            "\(Config.configDir.path)/models/\(modelFileName)",
            "/opt/homebrew/share/whisper-cpp/models/\(modelFileName)",
            "/usr/local/share/whisper-cpp/models/\(modelFileName)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/whisper/\(modelFileName)",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}

enum TranscriberError: LocalizedError {
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: open-wispr download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
