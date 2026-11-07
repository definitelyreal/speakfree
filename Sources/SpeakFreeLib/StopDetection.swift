import Foundation

/// How a dictation ends after the stop press.
public enum StopDetection: String, CaseIterable {
    /// The recording ends on the press. A word still being finished can lose its tail.
    case instant
    /// Waits for a short quiet moment below a set level (the post-buffer as it always was).
    case fixed
    /// Waits for a short quiet moment measured against the take's own background level,
    /// so a noisy room does not hold every dictation open for the full extended cap.
    case room
}

extension PostBufferPolicy {
    /// The two loudness lines the post-buffer judges trailing audio by.
    public struct StopLevels: Equatable {
        /// At or below this, a window counts as quiet.
        public let silence: Float
        /// At or above this, the speaker is still finishing a word and the cap extends.
        public let speech: Float
    }

    /// The range the fixed quiet level can be set to, from a quiet room to a loud one.
    public static let quietLevelRange: ClosedRange<Float> = 0.005...0.05

    /// How far above the background a window must be to count as sound. Tuned on the
    /// 15 Oct recordings (background 0.009–0.014): 2× ended all 35 takes in ~180 ms
    /// instead of 26 of them waiting the full 1.2 s, and left quiet rooms unchanged.
    static let roomFactor: Float = 2

    /// The speaking line sits this far above the quiet line, the default 0.01 / 0.02 ratio.
    static let speechFactor: Float = defaultSpeechThreshold / defaultSilenceThreshold

    /// The lines for a mode. nil means do not wait at all.
    /// - Parameter recordedSoFar: the take up to the stop press, used only by `.room`.
    public static func stopLevels(for mode: StopDetection, quietLevel: Float,
                                  recordedSoFar: [Float]) -> StopLevels? {
        switch mode {
        case .instant:
            return nil
        case .fixed:
            return StopLevels(silence: quietLevel, speech: quietLevel * speechFactor)
        case .room:
            // Never quieter than the default lines, so a quiet room behaves exactly as before.
            let silence = max(defaultSilenceThreshold, backgroundLevel(of: recordedSoFar) * roomFactor)
            return StopLevels(silence: silence, speech: max(defaultSpeechThreshold, silence * speechFactor))
        }
    }

    /// The take's background level: the RMS of its quietest tenth, in 30 ms windows.
    /// Speech fills most of a dictation, so the median would measure the voice, not the room.
    public static func backgroundLevel(of samples: [Float], sampleRate: Double = 16_000.0) -> Float {
        let windowSamples = max(1, Int((defaultWindowMs / 1000.0) * sampleRate))
        let windows = windowRMSValues(samples: samples, windowSamples: windowSamples).sorted()
        guard !windows.isEmpty else { return 0 }
        return windows[windows.count / 10]
    }

    /// `decideWaitMs(trailingSamples:)` judged by the given lines.
    public static func decideWaitMs(trailingSamples samples: [Float], sampleRate: Double = 16_000.0,
                                    windowMs: Double = defaultWindowMs, levels: StopLevels) -> Double {
        let windowSamples = max(1, Int((windowMs / 1000.0) * sampleRate))
        let rms = windowRMSValues(samples: samples, windowSamples: windowSamples)
        guard !rms.isEmpty else { return defaultCapMs }
        return decideWaitMs(windowRMS: rms, windowMs: windowMs,
                            silenceThreshold: levels.silence, speechThreshold: levels.speech)
    }
}
