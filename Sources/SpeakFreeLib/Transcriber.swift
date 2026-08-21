// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
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
    struct AudioEvidence: Equatable {
        let durationSeconds: Double
        let peakWindowRMS: Float
        let speechWindowCount: Int
        /// Estimated room noise floor: the `noiseFloorPercentile` window RMS across the whole take.
        let noiseFloorRMS: Float
        /// True when at least one energetic window carries a voiced-speech pitch (harmonic structure
        /// in the 85–255 Hz band), i.e. the energy is a human word rather than a tap/click/noise burst.
        let hasVoicedSpeech: Bool

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
    private let language: String
    public var suppressAutoPunctuation: Bool = false

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
            hasVoicedSpeech: hasVoicedSpeech)
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
            "amara.org", "amara. org", "subtitles by", "translated by",
            "transcribed by", "captioned by", "captions by",
            "like and subscribe", "subscribe to my channel", "don't forget to subscribe",
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
                result = try await transcribeWithEngineRecoveringEmpty(samples: samples, prompt: prompt)
            } catch {
                // CLI fallback is whisper-only; other engines rethrow.
                if engine.engineID == "whisper" {
                    // Log to the diagnostic log, not just stdout: the CLI path uses different
                    // inference params, so a persistently failing in-process engine silently
                    // degrading every dictation must be visible in the log health checks read.
                    DiagnosticLogger.shared.log("Transcriber: in-process engine failed (\(error.localizedDescription)) — falling back to whisper CLI")
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
        var cleaned = result.replacingOccurrences(of: "[•◦▪▸►▻→←↑↓★☆♦♥♠♣]", with: "", options: .regularExpression)

        let evidence = Self.audioEvidence(in: samples ?? [])
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           evidence.hasSustainedSpeechEnergy {
            DiagnosticLogger.shared.log(String(
                format: "Transcriber: speech-energy-present but model-empty "
                    + "(%.2fs, peak-window-rms %.3f, speech-windows %d)",
                evidence.durationSeconds, evidence.peakWindowRMS, evidence.speechWindowCount))
            // ACTIVE whisper rescue (2026-08-20): Parakeet (post empty-retries) produced
            // nothing on audio with sustained speech — the take is otherwise LOST, so a
            // slower second opinion is strictly better than silence. Corpus evidence:
            // whisper-large-v3-turbo recovered coherent text from takes Parakeet zeroed
            // (2026-08-19 airplane forensics; 56 empty-sentinel takes in the corpus).
            // Guarded on the whisper model actually being on disk; failure keeps empty.
            if engine.engineID != "whisper", Self.modelExists(modelSize: "large-v3-turbo") {
                do {
                    let rescued = try transcribeWithCLI(audioURL: audioURL, prompt: prompt,
                                                        modelOverride: "large-v3-turbo")
                    if !rescued.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DiagnosticLogger.shared.log(
                            "Transcriber: whisper rescue recovered \(rescued.count) chars from an empty take")
                        cleaned = rescued.replacingOccurrences(
                            of: "[•◦▪▸►▻→←↑↓★☆♦♥♠♣]", with: "", options: .regularExpression)
                    }
                } catch {
                    // A failed rescue must say so — a silent catch hid the modelID bug above.
                    DiagnosticLogger.shared.log(
                        "Transcriber: whisper rescue failed (\(error.localizedDescription))")
                }
            }
        } else if engine.engineID != "whisper",
                  Self.sparseRescueEligible(
                      parakeetWordCount: cleaned.split(separator: " ").count,
                      durationSeconds: Double((samples ?? []).count) / 16_000.0),
                  Self.modelExists(modelSize: "large-v3-turbo") {
            // SPARSE rescue (revised 2026-08-21): the confidence-triggered active swap
            // was WITHDRAWN same-day — the 23-take active-band adjudication measured it
            // helping 30% and harming 43%, and no veto set separated the two. What the
            // data does support: when Parakeet returned drastically fewer words than the
            // audio carries (<0.5 words/sec, the dropped-sentence shape), whisper gets a
            // synchronous shot and replaces ONLY when materially longer (>=2x words) and
            // under the 20s confabulation cap. Everything else is shadow-only.
            let conf = engine.lastDiagnostics?.aggregateConfidence ?? 0
            do {
                let swap = try transcribeWithCLI(audioURL: audioURL, prompt: prompt,
                                                 modelOverride: "large-v3-turbo")
                let duration = Double((samples ?? []).count) / 16_000.0
                let pWords = cleaned.split(separator: " ").count
                let wWords = swap.split(separator: " ").count
                if duration <= Self.swapMaxDurationSeconds,
                   Self.sparseRescueAccepts(parakeetWordCount: pWords, whisperWordCount: wWords),
                   Self.activeSwapVeto(parakeet: cleaned, whisper: swap,
                                       durationSeconds: duration) == nil {
                    let sidecar = audioURL.deletingPathExtension().appendingPathExtension("parakeet.txt")
                    try? cleaned.write(to: sidecar, atomically: true, encoding: .utf8)
                    DiagnosticLogger.shared.log(String(
                        format: "Transcriber: SPARSE whisper rescue (%.2f) — %d words replace %d over %.1fs",
                        conf, wWords, pWords, duration))
                    cleaned = swap.replacingOccurrences(
                        of: "[•◦▪▸►▻→←↑↓★☆♦♥♠♣]", with: "", options: .regularExpression)
                } else {
                    DiagnosticLogger.shared.log(String(
                        format: "Transcriber: sparse rescue declined (%.2f, %d vs %d words) — whisper to sidecar",
                        conf, wWords, pWords))
                    let sidecar = audioURL.deletingPathExtension().appendingPathExtension("whisper.txt")
                    try? swap.write(to: sidecar, atomically: true, encoding: .utf8)
                }
            } catch {
                DiagnosticLogger.shared.log(
                    "Transcriber: sparse-rescue whisper failed (\(error.localizedDescription)) — keeping Parakeet")
            }
        } else if engine.engineID != "whisper",
                  Self.secondOpinionTier(aggregateConfidence: engine.lastDiagnostics?.aggregateConfidence) == .shadow,
                  Self.modelExists(modelSize: "large-v3-turbo") {
            // SHADOW second opinion (2026-08-20): the take reads as suspect (corpus:
            // clean takes score >=0.94, garbled-but-fluent 0.73-0.83) but replacing text
            // automatically isn't yet earned — so whisper runs in the background, writes
            // a .whisper.txt sidecar beside the recording, and logs agreement. Never
            // blocks or changes what the user gets; the sidecars are the tuning corpus
            // for an eventual active low-confidence swap.
            let parakeetText = cleaned
            let conf = engine.lastDiagnostics?.aggregateConfidence ?? 0
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let shadow: String
                do {
                    shadow = try self.transcribeWithCLI(audioURL: audioURL, prompt: prompt,
                                                        modelOverride: "large-v3-turbo")
                } catch {
                    // A failed shadow must say so — a silent guard hid the modelID bug
                    // (2026-08-20: every shadow threw modelNotFound("parakeet-tdt-0.6b-v2")
                    // and left no trace).
                    DiagnosticLogger.shared.log(
                        "Transcriber: shadow whisper failed (\(error.localizedDescription))")
                    return
                }
                let sidecar = audioURL.deletingPathExtension().appendingPathExtension("whisper.txt")
                try? shadow.write(to: sidecar, atomically: true, encoding: .utf8)
                let agree = TextPipeline.normalizedForComparison(shadow)
                    == TextPipeline.normalizedForComparison(parakeetText)
                DiagnosticLogger.shared.log(String(
                    format: "Transcriber: shadow whisper on low-confidence take (%.2f) — %@ (%d vs %d chars)",
                    conf, agree ? "agrees" : "DIFFERS", shadow.count, parakeetText.count))
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
    /// exact same audio recovers coherent multi-second sentences. Proven on rec-2026-07-14-115522,
    /// an 11.7 s take dropped at record time that transcribes in full on replay ("Another thing
    /// that can happen is sometimes we will push a meeting..."), with whisper corroborating real
    /// speech in that and other dropped takes. An empty return is otherwise silently discarded, so
    /// a bounded, voiced-speech-gated retry only ever recovers loss: worst case it re-returns empty
    /// and the take is dropped exactly as before. Each retry gets a fresh decoder state (the engine
    /// builds one per call), which is what lets a transient bad decode clear.
    static let maxEmptyRetriesOnVoicedSpeech = 2

    /// Aggregate-confidence bound under which a background whisper "shadow" pass runs on a
    /// Parakeet take. Corpus (1,055 takes with diagnostics, 2026-08-20): clean takes score
    /// p25 = 0.945 / median 0.966, the known garbled-but-fluent failures score 0.73–0.83,
    /// and conf < 0.92 selects 8.8% of takes — wide enough to collect tuning data, cheap
    /// enough to run as a background CLI call. The shadow NEVER alters inserted text.
    static let whisperShadowConfidenceThreshold: Float = 0.92

    /// Below this bound the take is presumed garbled and whisper's transcript REPLACES
    /// Parakeet's (Michael approved the active swap 2026-08-20). The band is deliberately
    /// well under the shadow bound: every known word-salad take scored 0.73–0.83, while
    /// 0.85–0.92 is a mixed band that stays observe-only until the sidecar corpus proves
    /// it. Cost: one synchronous whisper-CLI call (~1.1–1.6 s) on ~2–3% of takes.
    static let whisperActiveSwapConfidenceThreshold: Float = 0.85

    /// Pure decision for what the whisper second opinion does on a non-empty Parakeet
    /// take. Split out so the tiers are unit-testable without live engines.
    ///
    /// REVISED 2026-08-21 (23-take active-band adjudication): a confidence-triggered
    /// swap in 0.5–0.85 helps 30% and HARMS 43% — near coin-flip, net negative — and
    /// no text-feature veto set separates the two (the mixed-band train/test showed the
    /// same). So confidence alone NEVER triggers a swap any more; every sub-0.92 take
    /// is shadow-only, and replacement is reserved for the two shapes the data actually
    /// supports: the empty rescue, and the sparse rescue below.
    enum SecondOpinionTier: Equatable { case none, shadow }
    static func secondOpinionTier(aggregateConfidence conf: Float?) -> SecondOpinionTier {
        guard let conf = conf, conf > 0.15 else { return .none }  // 0.1 = empty sentinel, handled by rescue
        if conf < whisperShadowConfidenceThreshold { return .shadow }
        return .none
    }

    /// Sparse rescue: Parakeet returned drastically fewer words than the audio carries
    /// (< 0.5 words/sec — the dropped-sentence failure shape both adjudications endorsed).
    /// Whisper's candidate must be materially longer (≥ 2×) to replace, so a whisper
    /// collapse ("Oh!") can never displace a short-but-real Parakeet take, and the
    /// >20s confabulation cap still applies at the call site.
    static func sparseRescueEligible(parakeetWordCount: Int, durationSeconds: Double) -> Bool {
        durationSeconds >= 5 && Double(parakeetWordCount) / max(durationSeconds, 0.1) < 0.5
    }
    static func sparseRescueAccepts(parakeetWordCount: Int, whisperWordCount: Int) -> Bool {
        whisperWordCount >= 2 * max(parakeetWordCount, 1)
    }

    /// Literal spoken-punctuation command words. In the 64-take mixed-band adjudication
    /// (2026-08-21) whisper's dominant failure was OVER-NORMALIZING these to glyphs or
    /// garbling them ("Gamma", "Conlon") — a candidate that lost command words is almost
    /// always whisper error, never Parakeet error.
    private static let commandWordPattern =
        "\\b(?:comma|period|question mark|exclamation (?:mark|point)|new line|new paragraph)\\b"

    /// Names whisper drifted on in the adjudication (clod/Koda/favorable/codecs). A swap
    /// candidate that LOSES one of these while Parakeet had it is rejected.
    /// TODO: derive from vocabulary.txt so user terms are covered automatically.
    static let swapProtectedTerms = [
        "Claude", "Codex", "Fable", "Opus", "Parakeet", "speakfree",
        "Anthropic", "Karma", "Zander", "Airtable", "Premiere",
    ]

    /// Whisper's confabulation risk concentrates on long takes (both BOTH_BAD rows in the
    /// adjudication were >39s whisper inventions). Above this, swap downgrades to shadow.
    static let swapMaxDurationSeconds: Double = 20

    /// Veto an active swap candidate. Returns the reason (for the log) or nil to allow.
    /// Derived from the 2026-08-21 adjudication of all 64 archived mixed-band takes:
    /// whisper wins only specific failure shapes, so the swap must refuse the shapes
    /// where whisper is the danger.
    static func activeSwapVeto(parakeet: String, whisper: String,
                               durationSeconds: Double) -> String? {
        if durationSeconds > swapMaxDurationSeconds {
            return "take >\(Int(swapMaxDurationSeconds))s — whisper confabulation risk"
        }
        func commandCount(_ s: String) -> Int {
            (try? NSRegularExpression(pattern: commandWordPattern, options: .caseInsensitive))
                .map { $0.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) } ?? 0
        }
        if commandCount(whisper) < commandCount(parakeet) {
            return "whisper lost spoken punctuation commands"
        }
        for term in swapProtectedTerms {
            if parakeet.localizedCaseInsensitiveContains(term),
               !whisper.localizedCaseInsensitiveContains(term) {
                return "whisper lost protected term '\(term)'"
            }
        }
        return nil
    }

    /// Wrap the in-process engine call: on an EMPTY result over audio that contains voiced human
    /// speech, retry up to `maxEmptyRetriesOnVoicedSpeech` times. Gated on `hasVoicedSpeech` so an
    /// accidental silent key-tap (no harmonic pitch structure) still fast-paths to empty with no
    /// added latency. Non-empty results and true-silence returns are untouched.
    private func transcribeWithEngineRecoveringEmpty(samples: [Float], prompt: String?) async throws -> String {
        var text = try await transcribeWithEngine(samples: samples, prompt: prompt)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.audioEvidence(in: samples).hasVoicedSpeech else { return text }
        for attempt in 1...Self.maxEmptyRetriesOnVoicedSpeech {
            DiagnosticLogger.shared.log(
                "Transcriber: engine returned empty on voiced speech, retry \(attempt)/\(Self.maxEmptyRetriesOnVoicedSpeech)")
            text = try await transcribeWithEngine(samples: samples, prompt: prompt)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DiagnosticLogger.shared.log(
                    "Transcriber: empty-result retry \(attempt) recovered \(text.count) chars")
                break
            }
        }
        return text
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

    /// `modelOverride` exists for the rescue/shadow paths: under the Parakeet engine,
    /// `modelID` is a Parakeet id ("parakeet-tdt-0.6b-v2") and resolving it as a ggml
    /// file can only throw — which is exactly how the 2026-08-20 shadow pass silently
    /// never fired (take 135106 "Caramore Kaima", conf 0.911, no sidecar, no log).
    private func transcribeWithCLI(audioURL: URL, prompt: String? = nil,
                                   modelOverride: String? = nil) throws -> String {
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        let cliModel = modelOverride ?? modelID
        guard let modelPath = Transcriber.findModel(modelSize: cliModel) else {
            throw TranscriberError.modelNotFound(cliModel)
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
        // Context-derived prompt is DROPPED on the CLI fallback: whisper-cli only accepts the
        // prompt via `--prompt` (in argv, ps-readable — a privacy leak of the surrounding text),
        // and offers no `--prompt-file`. The in-process engine path (the normal case) still
        // primes with the prompt safely; the CLI fallback runs promptless.
        if let prompt = prompt, !prompt.isEmpty {
            DiagnosticLogger.shared.log(
                "Transcriber: whisper CLI fallback running promptless — dropped \(prompt.count)-char "
                + "context prompt (no argv-free prompt path on whisper-cli)")
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

        // Whisper outputs one line per acoustic segment with leading spaces. Join with a
        // SPACE, not "\n" — a multi-segment split is not a user break, so it must never
        // reach insertion as a line break. [Newline policy 2b / Option B]
        let rawOutput = String(data: data, encoding: .utf8) ?? ""
        let output = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

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
    public func transcribeFile(
        url: URL,
        progressHandler: @escaping (_ chunk: Int, _ totalChunks: Int, _ whisperPct: Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws -> String {
        // Ensure model loaded
        if !engine.isLoaded {
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
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: speakfree download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
