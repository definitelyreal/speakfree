// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-processed:unverified · session:unknown/agent:audio_file_integrity · 2026-10-02
import Foundation
import AVFoundation

/// Named, rationale-carrying tuning constants for the hallucination-spare decision.
///
/// The filter deletes filler-word hallucinations ("So.", "Yeah.", "Okay.") that whisper/parakeet
/// emit on near-silence. A short filler is *spared* (kept) only when the captured audio actually
/// contains a real, voiced, human word. Two independent upgrades harden that spare:
///   1. QUIET-ROOM / SNR — in a genuinely quiet room ANY speech-level energy is almost certainly a
///      real word, so the spare fires on a lower bar (peak energy far above the room's noise floor)
///      than the stricter sustained-energy bar needed in a noisy room.
///   2. VOICEDNESS — a bang/tap/door-slam is a broadband transient with no pitch; voiced speech has
///      a clear fundamental (~85–255 Hz) and harmonics. A pitch-detector gate means a tap that
///      clears the energy bar but has no pitch does NOT resurrect a hallucinated filler word.
public enum HallucinationFilterTuning {
    /// Sustained-energy bar (the pre-existing noisy-room rule). Peak window must be clearly above
    /// speech level AND span several windows. 0.04 RMS sits well above breath/room tone (~0.01) and
    /// above the 0.02 "any speech energy" floor; 3 windows ≈ 90 ms, longer than a click transient.
    public static let sustainedPeakRMS: Float = 0.04
    public static let sustainedWindowCount = 3

    /// Quiet-room SNR margin. Peak speech energy must exceed the estimated room noise floor by this
    /// factor for the low-bar quiet-room spare. Tuned against the audit specimens: a genuinely quiet
    /// office floor runs ~0.001–0.004 RMS while even a soft real "Yeah." peaks ~0.03–0.06 (ratio
    /// 8–50×), whereas a noisy room's floor (~0.02) leaves a bare filler-level peak only ~1.5× above
    /// it. 8× cleanly separates "clearly a word spoken into quiet" from "barely above the noise" and
    /// keeps the strict sustained bar as the only path in noisy rooms. The absolute floor is still
    /// enforced by `hasAnySpeechEnergy` (peak ≥ 0.02), so a tiny noise floor cannot spare true silence.
    public static let quietRoomSNRMargin: Float = 8.0

    /// Noise-floor estimator percentile. The 20th-percentile window RMS across the whole take is a
    /// robust "quiet background" estimate: the median (50th) is polluted upward when a large share of
    /// the take is speech, while the 20th percentile still lands in the quiet portion of nearly every
    /// real dictation (which is mostly non-speech between words). Lower percentiles chase the single
    /// quietest sample and are noisy.
    public static let noiseFloorPercentile: Double = 0.20

    /// Voiced-pitch search band. Adult voice fundamental spans ~85 Hz (low male) to ~255 Hz (high
    /// female/child). At 16 kHz this is lag 63 (16000/255) to 188 (16000/85) samples.
    public static let voicingMinPitchHz: Double = 85.0
    public static let voicingMaxPitchHz: Double = 255.0

    /// Voicedness threshold on the normalized cross-correlation peak in the pitch band. A periodic
    /// (voiced) signal self-correlates ~0.9–1.0 at its pitch period; a single-impulse click stays
    /// near 0. 0.5 sits safely between; real voiced dictation windows measured 0.6–0.98 on the audit
    /// specimens. NCC alone is not enough — broadband white noise, maximized over ~125 lags × dozens
    /// of windows, can randomly clear any moderate NCC bar, and a constant/DC block self-correlates
    /// to 1.0 — so voicedness ALSO requires the zero-crossing band below.
    public static let voicingNCCThreshold: Float = 0.5

    /// Zero-crossing band for a voiced window (belt-and-suspenders with NCC, and the primary guard
    /// against broadband energy). A voiced fundamental of 85–255 Hz crosses zero ~5–15 times per
    /// 30 ms (480-sample) window; real speech's higher formants push this up modestly but stay well
    /// under a quarter of the window. A DC/constant block crosses ~0 times (→ reject as not speech);
    /// white noise and sharp clicks cross ~half the samples (~240/480 → far above the ceiling), so
    /// the ceiling rejects them decisively no matter how their autocorrelation happens to fall.
    public static let voicingMinZeroCrossings = 2
    public static let voicingMaxZeroCrossingFraction: Double = 0.25
}

public class Transcriber {
    /// What the user is told when a take ends with nothing to type. The status line is two
    /// sentences: what happened, then what to do. No em-dashes in UI copy.
    enum TakeStatus: Equatable {
        /// The engine returned nothing on real speech.
        case missed
        /// The take was static (a broken microphone stream).
        case staticNoise
        /// The Whisper engine returned text that is very likely invented
        /// (WhisperHallucinationGuard), so nothing was typed. Same line as a missed take.
        case likelyHallucination

        var message: String {
            switch self {
            case .missed, .likelyHallucination:
                return "Didn't catch that. Try again."
            case .staticNoise:
                return "Didn't catch that. The mic sounded like static."
            }
        }
    }

    struct AudioEvidence: Equatable {
        let durationSeconds: Double
        let peakWindowRMS: Float
        let speechWindowCount: Int
        /// Estimated room noise floor: the `noiseFloorPercentile` window RMS across the whole take.
        let noiseFloorRMS: Float
        /// True when at least one energetic window carries a voiced-speech pitch (harmonic structure
        /// in the 85–255 Hz band), i.e. the energy is a human word rather than a tap/click/noise burst.
        let hasVoicedSpeech: Bool
        /// Per-window RMS (`audioEvidenceWindowSize` samples each), for noise-relative measures.
        var windowRMS: [Float] = []

        var hasAnySpeechEnergy: Bool { speechWindowCount > 0 }
        var hasSustainedSpeechEnergy: Bool {
            peakWindowRMS >= HallucinationFilterTuning.sustainedPeakRMS
                && speechWindowCount >= HallucinationFilterTuning.sustainedWindowCount
        }
        /// Quiet-room SNR spare: peak speech energy stands a strong margin above the noise floor.
        /// (`hasAnySpeechEnergy` supplies the absolute floor, so a zero noise floor cannot spare silence.)
        var hasQuietRoomSNR: Bool {
            peakWindowRMS >= noiseFloorRMS * HallucinationFilterTuning.quietRoomSNRMargin
        }
    }

    /// Engine-agnostic backend, injected by EngineFactory (whisper or parakeet).
    public let engine: any TranscriptionEngine
    /// Model identifier for the active engine (whisper: a size like "large-v3-turbo";
    /// parakeet: "parakeet-tdt-0.6b-v3"). Doubles as the whisper model size for the CLI path.
    let modelID: String
    let language: String
    public var suppressAutoPunctuation: Bool = false
    var cliTranscriptionOverride: ((URL) throws -> String)? // instance-scoped test seam
    var onTakeStatus: ((TakeStatus) -> Void)?

    // MARK: - Engine lifecycle passthroughs (used by AppDelegate)

    public var supportsStreaming: Bool { engine.supportsStreaming }
    public var supportsPrompt: Bool { engine.supportsPrompt }
    public var lastDiagnostics: TranscriptionDiagnostics? { engine.lastDiagnostics }
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

    /// Launch-time model preparation. Parakeet compiles for the Neural Engine in a helper
    /// process while a CPU-only stand-in serves dictations (ParakeetFirstStart.swift); other
    /// engines just warm up. `onPhase` drives the menu line.
    public func prepare(onPhase: @escaping @Sendable (ModelPreparationPhase) -> Void) async {
        if let parakeet = engine as? ParakeetEngine {
            await parakeet.prepareModel(modelID: modelID, onPhase: onPhase)
        } else {
            await warmUp()
            onPhase(isLoaded ? .ready : .failed)
        }
    }

    private let preparationLock = NSLock()
    private var preparationsPending = 0

    /// True from `startPreparation` until that preparation returns. Set synchronously by the
    /// caller, so it already reads true before the preparation task has registered with the
    /// engine; key-press preload uses it to leave the load to the preparation.
    public var isPreparationPending: Bool {
        preparationLock.lock(); defer { preparationLock.unlock() }
        return preparationsPending > 0
    }

    /// Runs `prepare` in a detached task at the key-release path's priority, marking the
    /// preparation pending before returning.
    @discardableResult
    public func startPreparation(
        onPhase: @escaping @Sendable (ModelPreparationPhase) -> Void) -> Task<Void, Never> {
        adjustPendingPreparations(by: 1)
        return Task.detached(priority: .userInitiated) { [self] in
            await prepare(onPhase: onPhase)
            adjustPendingPreparations(by: -1)
        }
    }

    private func adjustPendingPreparations(by delta: Int) {
        preparationLock.lock(); preparationsPending += delta; preparationLock.unlock()
    }

    /// True when a dictation could be transcribed without waiting for a model load, counting
    /// Parakeet's CPU stand-in.
    public var isReadyToTranscribe: Bool {
        (engine as? ParakeetEngine)?.canTranscribeNow ?? engine.isLoaded
    }

    /// True when loading this engine's model could mean a Neural Engine compile (Parakeet,
    /// 16 to 73 s at first start). Background work (launch crash recovery) never loads such a
    /// model itself; see `LaunchRecoveryGate`.
    public var modelLoadMayCompile: Bool { engine.engineID == "parakeet" }

    /// Background file transcription pauses before each chunk while this returns true.
    static let liveTakePollNanoseconds: UInt64 = 100_000_000
    /// A background file transcription that has paused this long for live takes gives up
    /// (`BackgroundTranscriptionError.gaveWayToLiveTakes`) so it does not hold the recording's
    /// reading lease indefinitely; its caller retries later.
    static let liveTakeMaxYieldSeconds: Double = 60

    /// Waits while `isLiveTakeActive` reports a dictation recording or finalizing, so a
    /// background chunk never starts ahead of a live take. Throws on cancellation, and
    /// `gaveWayToLiveTakes` after `maxYieldSeconds` of waiting.
    static func yieldToLiveTakes(isLiveTakeActive: @Sendable () async -> Bool,
                                 isCancelled: () -> Bool,
                                 pollNanoseconds: UInt64 = liveTakePollNanoseconds,
                                 maxYieldSeconds: Double = liveTakeMaxYieldSeconds) async throws {
        let start = CFAbsoluteTimeGetCurrent()
        while await isLiveTakeActive() {
            if isCancelled() { throw TranscriptionEngineError.transcriptionFailed }
            if CFAbsoluteTimeGetCurrent() - start >= maxYieldSeconds {
                throw BackgroundTranscriptionError.gaveWayToLiveTakes
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    /// Seconds a take waited for a model load and spent in engine inference, summed over the
    /// empty-result retries. Reported on the "Transcription latency:" line, and for live
    /// dictations also on the per-take "Latency:" line (via TakeRecorder).
    struct EngineTiming {
        var modelWait: Double = 0
        var infer: Double = 0
        /// Model instance that produced the returned text (Parakeet: "ane" or "cpu-standin").
        var path: String?
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

    private static let speechSensitiveHallucinations: Set<String> = [
        "so", "hmm", "yeah", "yes", "no", "okay", "ok", "oh", "um", "uh",
        "hello", "hi", "thank you",
    ]

    static let audioEvidenceWindowSize = 480
    static let audioEvidenceSampleRate: Double = 16_000.0

    static func audioEvidence(in samples: [Float]) -> AudioEvidence {
        let windowSize = audioEvidenceWindowSize
        var peakWindowRMS: Float = 0
        var speechWindowCount = 0
        var windowRMSValues: [Float] = []
        windowRMSValues.reserveCapacity(samples.count / windowSize + 1)
        var hasVoicedSpeech = false
        var start = 0
        while start < samples.count {
            let end = min(start + windowSize, samples.count)
            let count = end - start
            guard count > 0 else { break }
            let window = samples[start..<end]
            var sumSquares: Float = 0
            for sample in window {
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(count))
            peakWindowRMS = max(peakWindowRMS, rms)
            windowRMSValues.append(rms)
            if rms >= PostBufferPolicy.defaultSpeechThreshold {
                speechWindowCount += 1
                // Voicedness is expensive relative to RMS, so only test energetic windows and
                // short-circuit once any one is voiced — a single genuinely voiced window is enough
                // to conclude the energy came from a human word, not a transient.
                if !hasVoicedSpeech, isVoicedWindow(window) {
                    hasVoicedSpeech = true
                }
            }
            start = end
        }
        return AudioEvidence(
            durationSeconds: Double(samples.count) / audioEvidenceSampleRate,
            peakWindowRMS: peakWindowRMS,
            speechWindowCount: speechWindowCount,
            noiseFloorRMS: noiseFloorRMS(from: windowRMSValues),
            hasVoicedSpeech: hasVoicedSpeech,
            windowRMS: windowRMSValues)
    }

    /// Robust room-noise-floor estimate: the `noiseFloorPercentile` window RMS across the take.
    /// Pure and directly testable. Empty input → 0 (treated as perfectly quiet).
    static func noiseFloorRMS(
        from windowRMSValues: [Float],
        percentile: Double = HallucinationFilterTuning.noiseFloorPercentile
    ) -> Float {
        guard !windowRMSValues.isEmpty else { return 0 }
        let sorted = windowRMSValues.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = min(sorted.count - 1, Int(clamped * Double(sorted.count)))
        return sorted[index]
    }

    /// Voiced-speech test for one sample window: is there harmonic pitch structure in the adult-voice
    /// band? Requires BOTH (a) a strong DC-removed normalized-cross-correlation peak in the pitch-lag
    /// band — a periodic voiced signal peaks near 1.0 at its pitch period, a click stays near 0 — AND
    /// (b) a zero-crossing count inside the voiced band, which rejects a DC/constant block (≈0
    /// crossings) and broadband white noise / sharp clicks (≈half the samples) regardless of how
    /// their autocorrelation happens to fall.
    static func isVoicedWindow(
        _ window: ArraySlice<Float>,
        sampleRate: Double = audioEvidenceSampleRate,
        threshold: Float = HallucinationFilterTuning.voicingNCCThreshold
    ) -> Bool {
        let crossings = zeroCrossingCount(window)
        let maxCrossings = Int(Double(window.count) * HallucinationFilterTuning.voicingMaxZeroCrossingFraction)
        guard crossings >= HallucinationFilterTuning.voicingMinZeroCrossings,
              crossings <= maxCrossings else { return false }
        return normalizedPitchAutocorrelation(window, sampleRate: sampleRate) >= threshold
    }

    /// Zero crossings of the mean-removed window. DC/constant → ~0; voiced tone → ~2·f·Δt;
    /// broadband noise/clicks → ~half the sample count. Pure and directly testable.
    static func zeroCrossingCount(_ window: ArraySlice<Float>) -> Int {
        let samples = Array(window)
        guard samples.count > 1 else { return 0 }
        var mean: Float = 0
        for value in samples { mean += value }
        mean /= Float(samples.count)
        var crossings = 0
        var previous = samples[0] - mean
        for index in 1..<samples.count {
            let current = samples[index] - mean
            if (previous < 0 && current >= 0) || (previous >= 0 && current < 0) {
                crossings += 1
            }
            previous = current
        }
        return crossings
    }

    /// Peak normalized cross-correlation over the pitch-period lag band (adult voice 85–255 Hz).
    /// Pure DSP over the Float samples (no Accelerate dependency, no allocation beyond the local
    /// mean-removed copy). Returns 0 when the window is too short, silent, or DC-only.
    static func normalizedPitchAutocorrelation(
        _ window: ArraySlice<Float>,
        sampleRate: Double = audioEvidenceSampleRate,
        minPitchHz: Double = HallucinationFilterTuning.voicingMinPitchHz,
        maxPitchHz: Double = HallucinationFilterTuning.voicingMaxPitchHz
    ) -> Float {
        let samples = Array(window)
        let n = samples.count
        let minLag = max(1, Int((sampleRate / maxPitchHz).rounded(.down)))
        let maxLag = min(n - 1, Int((sampleRate / minPitchHz).rounded(.up)))
        guard maxLag > minLag, n > maxLag else { return 0 }

        // Remove DC so a constant/near-constant block does not self-correlate as if it were pitched.
        var mean: Float = 0
        for value in samples { mean += value }
        mean /= Float(n)
        let centered = samples.map { $0 - mean }

        var bestNCC: Float = 0
        for lag in minLag...maxLag {
            var dot: Float = 0
            var energyA: Float = 0
            var energyB: Float = 0
            var index = 0
            let limit = n - lag
            while index < limit {
                let a = centered[index]
                let b = centered[index + lag]
                dot += a * b
                energyA += a * a
                energyB += b * b
                index += 1
            }
            let denom = sqrtf(energyA * energyB)
            guard denom > 0 else { continue }
            let ncc = dot / denom
            if ncc > bestNCC { bestNCC = ncc }
        }
        return bestNCC
    }

    /// One line per refused Whisper text. No text in the log, only its length and the evidence.
    static func logBlockedWhisper(_ verdict: WhisperHallucinationGuard.Verdict, chars: Int) {
        DiagnosticLogger.shared.log(
            "Transcriber: whisper engine text not typed, likely invented (\(verdict.reason ?? "?"); "
                + "\(verdict.noise.summary); \(chars) chars kept in sidecar only)")
    }

    /// Duration (seconds) at/above which a bare filler is spared on length alone (long take with
    /// at least one voiced window ⇒ the speaker said something even if energy wasn't sustained).
    static let spareMinDurationSeconds: Double = 2.5

    static func shouldSpareHallucination(_ text: String, evidence: AudioEvidence) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
        // Only these filler words are ever sparable; markers, "you", "bye", subtitle leaks stay deleted.
        guard speechSensitiveHallucinations.contains(normalized),
              evidence.hasAnySpeechEnergy else { return false }
        // BOTH energy-shaped evidence AND voicedness are required: a tap/click can clear the energy
        // bar but has no pitch, so it must not resurrect a hallucinated filler.
        let energyEvidence = evidence.hasQuietRoomSNR
            || evidence.hasSustainedSpeechEnergy
            || evidence.durationSeconds >= spareMinDurationSeconds
        return energyEvidence && evidence.hasVoicedSpeech
    }

    private static let captionCreditPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:subtitles by|translated by|transcribed by|captioned by|captions by)(?![\p{L}\p{N}])"#)

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

        // Subtitle/training data leakage. NOTE: "subscribe" alone is a legitimate imperative
        // ("Please subscribe Alex to the release updates.") — only the YouTube-outro PHRASES are
        // hallucinations. "please subscribe" is deliberately NOT listed: it collides with real
        // dictation. Match phrase forms that don't appear in ordinary sentences.
        let substringHallucinations = [
            "amara.org", "amara. org",
            "like and subscribe", "subscribe to my channel", "don't forget to subscribe",
        ]
        for pattern in substringHallucinations {
            if lower.contains(pattern) { return true }
        }
        // Attribution phrases must end on a word boundary: "translated bypass" is ordinary
        // text, not "translated by" followed by a credit. Keep this final gate consistent
        // with the Whisper guard so text it accepts can actually reach insertion.
        if Self.captionCreditPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            return true
        }

        // Formatting alone is not a sound caption. Share the guard's bounded label list
        // so a genuine wrapped sentence survives the final filter as well as the guard.
        if WhisperHallucinationGuard.isSoundTag(trimmed) { return true }

        return false
    }

    public init(engine: any TranscriptionEngine, modelID: String, language: String) {
        self.engine = engine
        self.modelID = modelID
        self.language = language
    }

    /// Transcribe using the in-process engine (fast, model stays loaded).
    /// Falls back to CLI (whisper only) if the engine fails or samples are not provided.
    public func transcribe(audioURL: URL, samples: [Float]? = nil, prompt: String? = nil,
                           punctuationMode: PunctuationMode = .off,
                           audioFileIsValid: Bool = true) async throws -> String {
        // This value is per take and captured by background work, never mutable shared state.
        // Explicit memory-only callers can continue. File-backed callers must not turn
        // a retained damaged WAV into samples and silently treat those as authoritative.
        if audioFileIsValid && AudioArchiveIntegrity.isInvalid(audioURL) {
            throw TranscriberError.audioArchiveUnavailable
        }
        let fileForRecognition: URL? = audioFileIsValid ? audioURL : nil
        let activityLease = try RecordingActivity.shared.acquireReading(audioURL)
        defer { activityLease.release() }
        let result: String
        // Per-take provenance for the dictation trace and the meta sidecar (see TakeRecorder).
        let recorder = TakeRecorder.current
        recorder?.engineDiagnostics = nil
        recorder?.engineTextKept = false
        recorder?.engine = nil
        recorder?.inferencePath = nil
        recorder?.modelWaitSeconds = nil
        func markReplacedByWhisperCLI() {
            recorder?.engine = "whisper"
            recorder?.engineTextKept = false
        }

        // Try engine first if we have samples
        if let samples = samples, !samples.isEmpty {
            do {
                var timing = EngineTiming()
                result = try await transcribeWithEngineRecoveringEmpty(
                    samples: samples, prompt: prompt, punctuationMode: punctuationMode,
                    timing: &timing)
                recorder?.engine = engine.engineID
                recorder?.engineTextKept = true
                // A live dictation also folds these into its per-take "Latency:" line.
                recorder?.inferencePath = timing.path ?? engine.engineID
                recorder?.modelWaitSeconds = timing.modelWait
                // One line per engine pass, for every caller and every outcome (the "Latency:"
                // line is only written after a successful insertion): which model instance ran
                // it (Neural Engine, or the CPU stand-in during a first-start compile), how long
                // it waited for a model, the inference time, and the priority it ran at. No text.
                DiagnosticLogger.shared.log(String(format: "Transcription latency: path=%@ wait=%.3f infer=%.3f audio=%.1f qos=%@",
                    timing.path ?? engine.engineID,
                    timing.modelWait, timing.infer, Double(samples.count) / 16_000.0,
                    currentQoSName()))
            } catch {
                // CLI fallback is whisper-only; other engines rethrow.
                if engine.engineID == "whisper" {
                    // Log to the diagnostic log, not just stdout: the CLI path uses different
                    // inference params, so a persistently failing in-process engine silently
                    // degrading every dictation must be visible in the log health checks read.
                    DiagnosticLogger.shared.log("Transcriber: in-process engine failed (\(error.localizedDescription)) — falling back to whisper CLI")
                    result = try transcribeWithCLI(audioURL: fileForRecognition, prompt: prompt)
                    markReplacedByWhisperCLI()
                } else {
                    throw error
                }
            }
        } else if engine.engineID == "whisper" {
            // Fallback to CLI (whisper only)
            result = try transcribeWithCLI(audioURL: fileForRecognition, prompt: prompt)
            markReplacedByWhisperCLI()
        } else {
            // Non-whisper engines have no CLI fallback and need samples.
            throw TranscriptionEngineError.transcriptionFailed
        }

        // Strip non-speech characters whisper sometimes outputs (bullets, arrows, etc.)
        var cleaned = result.replacingOccurrences(of: "[•◦▪▸►▻→←↑↓★☆♦♥♠♣]", with: "", options: .regularExpression)
        if engine.engineID == "whisper", !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Whisper is the chosen engine: without a Parakeet opinion, refusals require
            // audio evidence as well as a stock phrase, short static output, or subtitle dash.
            let verdict = WhisperHallucinationGuard.assess(
                whisperText: cleaned, samples: samples ?? [], parakeetText: nil)
            if verdict.block {
                Self.logBlockedWhisper(verdict, chars: cleaned.count)
                RecordingStore.saveAuxiliaryTranscription(text: cleaned, kind: .whisper, for: audioURL)
                cleaned = ""
                onTakeStatus?(.likelyHallucination)
            }
        }

        let evidence = Self.audioEvidence(in: samples ?? [])
        // A broken microphone stream (2026-09-25 AirPods static) has no words to recover.
        let takeWindows = CaptureStaticJudge.windows(of: samples ?? [])
        let takeIsStatic = CaptureStaticJudge.isStatic(takeWindows, minimumWindows: CaptureStaticJudge.wholeTakeMinimumWindows)
        let wordCount = cleaned.split(whereSeparator: { $0.isWhitespace }).count
        if engine.engineID != "whisper", takeIsStatic, wordCount <= 2,
           wordCount > 0 || !evidence.hasSustainedSpeechEnergy {
            // A stray word or two read out of static is not what was said.
            DiagnosticLogger.shared.log(
                "Transcriber: take sounded like static (\(CaptureStaticJudge.describe(takeWindows))); dropped \(wordCount) words")
            cleaned = ""
            onTakeStatus?(.staticNoise)
        } else if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           evidence.hasSustainedSpeechEnergy || evidence.hasVoicedSpeech {
            if evidence.hasSustainedSpeechEnergy {
                DiagnosticLogger.shared.log(String(
                    format: "Transcriber: speech-energy-present but model-empty "
                        + "(%.2fs, peak-window-rms %.3f, speech-windows %d)",
                    evidence.durationSeconds, evidence.peakWindowRMS, evidence.speechWindowCount))
            }
            // Parakeet (after its own empty-result retries, which voiced speech triggers) heard
            // nothing on real speech, loud or soft. There
            // is no second engine behind it (the Whisper backup was removed 2026-10-05: across
            // 22,179 archived takes it typed text 16 times, 13 of them invented, and it cost
            // 2 to 4 s per run), so the take is reported as missed.
            if engine.engineID != "whisper" {
                if takeIsStatic {
                    DiagnosticLogger.shared.log(
                        "Transcriber: take sounded like static (\(CaptureStaticJudge.describe(takeWindows))); nothing typed")
                    onTakeStatus?(.staticNoise)
                } else {
                    onTakeStatus?(.missed)
                }
            }
        }

        // Filter known hallucinations from all engines + the CLI path
        if isHallucination(cleaned) {
            if Self.shouldSpareHallucination(cleaned, evidence: evidence) {
                DiagnosticLogger.shared.log(String(
                    format: "Transcriber: spared short hallucination candidate with speech energy "
                        + "(%.2fs, peak-window-rms %.3f)",
                    evidence.durationSeconds, evidence.peakWindowRMS))
                return cleaned
            }
            print("Transcriber: filtered hallucination: \"\(cleaned)\"")
            return ""
        }
        return cleaned
    }

    /// Retry budget when the in-process engine returns EMPTY text on audio that carries genuine
    /// voiced speech. FluidAudio's Parakeet ANE decode intermittently yields an empty result on
    /// real dictation: the recordings corpus (2026-08) holds 250+ empty-drops, and re-running the
    /// exact same audio recovers coherent multi-second sentences. Proven on an 11.7 s
    /// production take dropped at record time that transcribes in full on replay (a complete
    /// multi-clause sentence), with whisper corroborating real
    /// speech in that and other dropped takes. An empty return is otherwise silently discarded, so
    /// a bounded, voiced-speech-gated retry only ever recovers loss: worst case it re-returns empty
    /// and the take is dropped exactly as before. Each retry gets a fresh decoder state (the engine
    /// builds one per call), which is what lets a transient bad decode clear.
    static let maxEmptyRetriesOnVoicedSpeech = 2

    /// Wrap the in-process engine call: on an EMPTY result over audio that contains voiced human
    /// speech, retry up to `maxEmptyRetriesOnVoicedSpeech` times. Gated on `hasVoicedSpeech` so an
    /// accidental silent key-tap (no harmonic pitch structure) still fast-paths to empty with no
    /// added latency. Non-empty results and true-silence returns are untouched.
    private func transcribeWithEngineRecoveringEmpty(
        samples: [Float], prompt: String?, punctuationMode: PunctuationMode,
        timing: inout EngineTiming
    ) async throws -> String {
        var text = try await transcribeWithEngine(
            samples: samples, prompt: prompt, punctuationMode: punctuationMode, timing: &timing)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.audioEvidence(in: samples).hasVoicedSpeech else { return text }
        for attempt in 1...Self.maxEmptyRetriesOnVoicedSpeech {
            DiagnosticLogger.shared.log(
                "Transcriber: engine returned empty on voiced speech, retry \(attempt)/\(Self.maxEmptyRetriesOnVoicedSpeech)")
            text = try await transcribeWithEngine(
                samples: samples, prompt: prompt, punctuationMode: punctuationMode, timing: &timing)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DiagnosticLogger.shared.log(
                    "Transcriber: empty-result retry \(attempt) recovered \(text.count) chars")
                break
            }
        }
        return text
    }

    private func transcribeWithEngine(samples: [Float], prompt: String?,
                                      punctuationMode: PunctuationMode,
                                      timing: inout EngineTiming) async throws -> String {
        // Ensure model is loaded (engine resolves its own on-disk/cache location). During a
        // Parakeet first start this returns as soon as the CPU stand-in can serve the take.
        let waitStart = CFAbsoluteTimeGetCurrent()
        if !engine.isLoaded {
            try await engine.loadModel(modelID: modelID)
        }
        let inferStart = CFAbsoluteTimeGetCurrent()
        timing.modelWait += inferStart - waitStart
        defer { timing.infer += CFAbsoluteTimeGetCurrent() - inferStart }

        let suppressRegex = suppressAutoPunctuation ? "[,\\.\\?!;:\\-—]" : nil

        let raw: String
        if let confidenceCorrectingEngine = engine as? ConfidencePunctuationCorrectingEngine {
            let result = try await confidenceCorrectingEngine.transcribeReportingPath(
                samples: samples, language: language, prompt: prompt,
                suppressRegex: suppressRegex,
                enablePunctuationCommandCorrection: punctuationMode != .off)
            raw = result.text
            timing.path = result.inferencePath
        } else {
            raw = try await engine.transcribe(
                samples: samples, language: language, prompt: prompt,
                suppressRegex: suppressRegex)
        }

        // Clean up output same way as CLI. Whisper emits one line per acoustic segment;
        // join them with a SPACE, not "\n" — a multi-segment split is not a user break.
        // After this, every "\n" reaching insertion is unambiguously a SPOKEN "new line"
        // (TextPostProcessor maps spoken "new line"/"new paragraph" → \n / \n\n). [Newline policy 2b / Option B]
        // The T2.3 reuse path applies the IDENTICAL collapse to the reused streaming partial.
        return TextPipeline.collapseSegmentNewlines(raw)
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

    /// whisper-cli fallback for the Whisper engine only (`modelID` is a Whisper size here).
    private func transcribeWithCLI(audioURL: URL?, prompt: String? = nil) throws -> String {
        guard let audioURL else { throw TranscriberError.audioArchiveUnavailable }
        if let cliTranscriptionOverride { return try cliTranscriptionOverride(audioURL) }
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        guard let modelPath = Transcriber.findModel(modelSize: modelID) else {
            throw TranscriberError.modelNotFound(modelID)
        }

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
        // Context-derived prompt is DROPPED on the CLI fallback: whisper-cli only accepts the
        // prompt via `--prompt` (in argv, ps-readable — a privacy leak of the surrounding text),
        // and offers no `--prompt-file`. The in-process engine path (the normal case) still
        // primes with the prompt safely; the CLI fallback runs promptless.
        if let prompt = prompt, !prompt.isEmpty {
            DiagnosticLogger.shared.log(
                "Transcriber: whisper CLI fallback running promptless — dropped \(prompt.count)-char "
                + "context prompt (no argv-free prompt path on whisper-cli)")
        }
        let duration = (try? AVAudioFile(forReading: audioURL)).map {
            Double($0.length) / max(1, $0.processingFormat.sampleRate)
        } ?? 60
        // The user is waiting on this run, so it runs at the key-release path's priority.
        let outputResult = try BoundedProcess.run(
            executable: URL(fileURLWithPath: whisperPath), arguments: args,
            timeout: Self.cliTimeout(audioDuration: duration),
            qualityOfService: .userInitiated)
        let data = outputResult.stdout
        let stderrData = outputResult.stderr

        // Whisper outputs one line per acoustic segment with leading spaces. Join with a
        // SPACE, not "\n" — a multi-segment split is not a user break, so it must never
        // reach insertion as a line break. [Newline policy 2b / Option B]
        let rawOutput = String(data: data, encoding: .utf8) ?? ""
        let output = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if outputResult.status != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderr.isEmpty { fputs("whisper-cpp: \(stderr)\n", Foundation.stderr) }
            throw TranscriberError.transcriptionFailed
        }

        return output
    }

    static func cliTimeout(audioDuration: Double) -> TimeInterval {
        // A duration-aware budget (up to 30 min).
        let duration = audioDuration.isFinite ? max(0, audioDuration) : 60
        return min(1800, max(30, duration * 2 + 15))
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

    // MARK: - File transcription

    /// Transcribe an arbitrary audio file with real progress feedback.
    ///
    /// - Whisper: uses `whisper_full_params.progress_callback` — fires 0→100 as it
    ///   processes internal 30-second windows. No manual chunking needed.
    /// - Parakeet: chunks at 5-minute intervals with 10-second overlap. Progress is
    ///   "chunk N of M". One AVAudioFile handle spans all chunks.
    ///
    /// `progressHandler(chunkIndex, chunkTotal, whisperPct)` is called on the main thread.
    /// `isCancelled` is polled between chunks and inside whisper_full.
    /// On cancellation throws `TranscriptionEngineError.transcriptionFailed`.
    /// On success returns the full transcript string.
    ///
    /// Background callers (launch crash recovery) pass `loadModelIfNeeded: false`: the call then
    /// never loads a model (which for Parakeet could be a Neural Engine compile a dictation
    /// would wait behind) and throws `TranscriptionEngineError.modelNotLoaded` unless the
    /// engine's own model is loaded, checked before every chunk. (Parakeet's CPU stand-in does
    /// not count: a background chunk on it would compete with live takes on the CPU.) They also
    /// pass `isLiveTakeActive`, checked before every chunk: while a dictation is recording or
    /// finalizing, the next chunk waits, so the live take goes first.
    public func transcribeFile(
        url: URL,
        progressHandler: @escaping (_ chunk: Int, _ totalChunks: Int, _ whisperPct: Int) -> Void,
        isCancelled: @escaping () -> Bool,
        loadModelIfNeeded: Bool = true,
        isLiveTakeActive: (@Sendable () async -> Bool)? = nil
    ) async throws -> String {
        guard !AudioArchiveIntegrity.isInvalid(url) else { throw TranscriberError.audioArchiveUnavailable }
        let activityLease = try RecordingActivity.shared.acquireReading(url)
        defer { activityLease.release() }
        // Ensure model loaded
        if !engine.isLoaded {
            guard loadModelIfNeeded else { throw TranscriptionEngineError.modelNotLoaded }
            try await engine.loadModel(modelID: modelID)
        }

        let file = try AVAudioFile(forReading: url)
        let srcRate = file.processingFormat.sampleRate
        let totalFrames = file.length

        // 5-minute chunks (at source sample rate) with 10-second overlap
        let chunkFrames = AVAudioFrameCount(srcRate * 5 * 60)
        let overlapFrames = AVAudioFrameCount(srcRate * 10)
        let stepFrames = chunkFrames - overlapFrames

        var chunks: [(start: AVAudioFramePosition, count: AVAudioFrameCount)] = []
        var pos: AVAudioFramePosition = 0
        while pos < totalFrames {
            let remaining = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - pos))
            chunks.append((pos, remaining))
            if remaining < chunkFrames { break }
            pos += AVAudioFramePosition(stepFrames)
        }
        // Single-chunk optimisation: if the file fits in one window, skip overlap logic
        if chunks.isEmpty { chunks = [(0, AVAudioFrameCount(totalFrames))] }

        let totalChunks = chunks.count
        var parts: [String] = []

        for (idx, chunk) in chunks.enumerated() {
            if isCancelled() { throw TranscriptionEngineError.transcriptionFailed }

            let samples = try ProcessCommand.loadSamplesChunk(
                from: file, startFrame: chunk.start, frameCount: chunk.count
            )
            if samples.isEmpty { continue }

            let suppressRegex = suppressAutoPunctuation ? "[,\\.\\?!;:\\-—]" : nil

            // A live dictation always goes first: never start a chunk while one is recording
            // or finalizing (only a chunk already in flight can delay it).
            if let isLiveTakeActive {
                try await Self.yieldToLiveTakes(isLiveTakeActive: isLiveTakeActive, isCancelled: isCancelled)
            }
            // Background callers never load, and never fall back to the CPU stand-in.
            if !loadModelIfNeeded, !engine.isLoaded { throw TranscriptionEngineError.modelNotLoaded }

            let raw: String
            if engine.engineID == "whisper", let whisperEngine = engine as? WhisperEngine {
                raw = try await whisperEngine.transcribeWithProgress(
                    samples: samples,
                    language: language,
                    prompt: parts.last.map { String($0.suffix(200)) },
                    suppressRegex: suppressRegex,
                    skipSilenceTrim: true,
                    progressHandler: { pct in
                        progressHandler(idx, totalChunks, pct)
                    },
                    isCancelled: isCancelled
                )
            } else {
                // Parakeet and other engines: progress by chunk count only.
                // Hop to main explicitly — whisper's transcribeWithProgress does this
                // internally, but this branch runs in the caller's Task context, and
                // FileTranscriptionController mutates AppKit views in the handler.
                DispatchQueue.main.async { progressHandler(idx, totalChunks, 0) }
                raw = try await engine.transcribe(
                    samples: samples,
                    language: language,
                    prompt: parts.last.map { String($0.suffix(200)) },
                    suppressRegex: suppressRegex
                )
                DispatchQueue.main.async { progressHandler(idx + 1, totalChunks, 100) }
            }

            // Preserve multi-segment whisper breaks as newlines HERE. Unlike live dictation
            // (Transcriber.transcribe → TextInserter), transcribeFile writes a DOCUMENT
            // (.txt/.md via FileTranscriptionController.writeOutput). Segment newlines are
            // document STRUCTURE there, not insertion keystrokes, so they must survive — the
            // Newline-policy-2b/Option-B space-join applies ONLY to insertion paths, never here.
            let cleaned = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            // Overlap reconciliation: strip likely-duplicated content at the seam
            if idx > 0, let prev = parts.last, !prev.isEmpty {
                let deduped = stripOverlapSeam(new: cleaned, previous: prev)
                parts.append(deduped)
            } else {
                parts.append(cleaned)
            }
        }

        // Join reconciled 5-minute chunks with a newline. This is the DOCUMENT path
        // (transcribeFile → writeOutput), not live dictation, so a chunk boundary becomes a
        // visible structural break in the saved file rather than collapsing the whole
        // transcript into one unbroken line. (Insertion paths keep the space-join.)
        return parts.joined(separator: "\n")
    }

    /// Remove words at the start of `new` that also appear at the end of `previous`
    /// (the 10-second overlap region). Simple word-match heuristic — V1 acceptable.
    private func stripOverlapSeam(new: String, previous: String) -> String {
        let newWords = new.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let prevWords = previous.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !newWords.isEmpty, !prevWords.isEmpty else { return new }

        // Look for the longest suffix of prevWords that matches a prefix of newWords (up to 40 words)
        let maxCheck = min(40, min(newWords.count, prevWords.count))
        for len in stride(from: maxCheck, through: 1, by: -1) {
            let prevSuffix = prevWords.suffix(len).map { $0.lowercased() }
            let newPrefix  = Array(newWords.prefix(len)).map { $0.lowercased() }
            if prevSuffix.elementsEqual(newPrefix) {
                return newWords.dropFirst(len).joined(separator: " ")
            }
        }
        return new
    }
}

enum TranscriberError: LocalizedError {
    case audioArchiveUnavailable
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .audioArchiveUnavailable:
            return "The audio archive could not be repaired; file recognition is unavailable."
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: speakfree download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
