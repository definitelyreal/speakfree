// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22

import Foundation

/// Decides whether a "too few words for this much speech" take is worth the synchronous
/// Whisper rescue (about 3 s on the key-release path).
///
/// The maintainer, 2026-09-22 (lightly cleaned): "When we re-run with a new model, can we add a check
/// that discovers whether that didn't do anything and updates the signal-to-noise ratio? ...
/// Maybe it updates the ratio immediately, then dual-tests it occasionally (the more
/// deterministic and fast that can be, the more often it can dual-test)."
///
/// The problem it fixes: "seconds of speech" was every 30 ms window above a fixed 0.02 RMS. In a
/// room whose noise sits near 0.015, pauses clear that bar, so a speak-then-pause take looked
/// like 12 s of speech with 2 words and pulled a rescue that returned the same 2 words
/// (one noisy-room take, 3.64 s to text). Here speech must also clear `ratio` times the take's
/// own noise floor: an instant per-take SNR, so the gate recovers the moment the room quiets.
///
/// `ratio` is learned per input device. A rescue that gains nothing raises it one step; one that
/// helps lowers it. A take the gate skips is occasionally still checked with Whisper in the
/// background (never on the key-release path); if that check would have helped, the ratio drops.
/// Checks are dense while a device's ratio is unproven and thin out as agreeing checks
/// accumulate. Takes where Parakeet returned zero words always rescue: every accepted rescue in
/// the logs was one of those, and they never train the ratio. Takes over the 20 s swap cap never
/// reach the gate (the rescue could not replace their text). In memory only; a relaunch starts
/// from `initialRatio`. Known limit: with saving off the WAV is deleted before a background check
/// can read it, so those users' skips are never verified and the ratio learns only from rescues.
public final class SparseRescueGate {
    public static let shared = SparseRescueGate()

    public static let initialRatio: Float = 2.0
    public static let minRatio: Float = 1.5
    public static let maxRatio: Float = 6.0
    public static let step: Float = 1.25
    /// Background checks: every skip while fewer than this many checks agreed, then 1 in
    /// `settledCheckInterval` skips.
    public static let learningChecks = 3
    public static let settledCheckInterval = 5

    public enum Decision: Equatable {
        /// Run the synchronous rescue (today's behavior).
        case rescue
        /// Skip it; `backgroundCheck` says whether to verify the skip off the key-release path.
        case skip(backgroundCheck: Bool)
    }

    private struct DeviceState {
        var ratio: Float = SparseRescueGate.initialRatio
        var agreeingChecks = 0
        var skipsSinceCheck = 0
    }

    private let lock = NSLock()
    private var states: [String: DeviceState] = [:]

    public init() {}

    static func key(_ device: String?) -> String { device ?? "unknown" }

    public func ratio(for device: String?) -> Float {
        lock.lock(); defer { lock.unlock() }
        return states[Self.key(device)]?.ratio ?? Self.initialRatio
    }

    /// Windows at the start of a take that come from the pre-roll (audio from before the key
    /// press, normally room tone).
    public static let prerollWindows = 16

    /// Noise floor for the gate: the lower of the whole-take estimate and the quietest
    /// pre-roll windows. A take that is almost all continuous speech (the dropped-sentence
    /// shape the rescue exists for) pushes a whole-take percentile up onto speech; the pre-roll
    /// keeps the floor on the room.
    public static func gateNoiseFloor(windowRMS: [Float], takeFloor: Float) -> Float {
        let head = windowRMS.prefix(prerollWindows).filter { $0.isFinite }.sorted()
        guard !head.isEmpty else { return takeFloor }
        let prerollFloor = head[min(head.count - 1, head.count / 10)]
        return takeFloor.isFinite ? min(takeFloor, prerollFloor) : prerollFloor
    }

    /// Seconds of windows whose RMS clears both the fixed speech bar and `ratio` x noise floor.
    public static func speechSeconds(
        windowRMS: [Float], windowSeconds: Double, noiseFloor: Float, ratio: Float
    ) -> Double {
        let floor = noiseFloor.isFinite ? max(0, noiseFloor) : 0
        let bar = max(PostBufferPolicy.defaultSpeechThreshold, ratio * floor)
        return Double(windowRMS.filter { $0 >= bar }.count) * windowSeconds
    }

    /// Called only for takes the fixed-bar check already found sparse.
    public func decide(
        device: String?, parakeetWords: Int, durationSeconds: Double,
        windowRMS: [Float], windowSeconds: Double, noiseFloor: Float
    ) -> (decision: Decision, relativeSpeechSeconds: Double, ratio: Float) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(device)
        var state = states[key] ?? DeviceState()
        let floor = Self.gateNoiseFloor(windowRMS: windowRMS, takeFloor: noiseFloor)
        let speech = Self.speechSeconds(windowRMS: windowRMS, windowSeconds: windowSeconds,
                                        noiseFloor: floor, ratio: state.ratio)
        let ratio = state.ratio
        if parakeetWords == 0 || Transcriber.sparseRescueEligible(
            parakeetWordCount: parakeetWords, durationSeconds: durationSeconds,
            speechDurationSeconds: speech) {
            return (.rescue, speech, ratio)
        }
        state.skipsSinceCheck += 1
        let interval = state.agreeingChecks < Self.learningChecks ? 1 : Self.settledCheckInterval
        let check = state.skipsSinceCheck >= interval
        if check { state.skipsSinceCheck = 0 }
        states[key] = state
        return (.skip(backgroundCheck: check), speech, ratio)
    }

    /// A synchronous rescue finished. `gained` = Whisper was materially longer (the same test
    /// that decides replacement).
    public func recordRescue(device: String?, gained: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(device)
        var state = states[key] ?? DeviceState()
        state.ratio = gained ? max(Self.minRatio, state.ratio / Self.step)
                             : min(Self.maxRatio, state.ratio * Self.step)
        states[key] = state
    }

    /// A background check of a skipped take finished. Would-have-gained means the skip lost
    /// words: lower the ratio and restart learning. Otherwise the skip was right.
    public func recordSkipCheck(device: String?, wouldHaveGained: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(device)
        var state = states[key] ?? DeviceState()
        if wouldHaveGained {
            state.ratio = max(Self.minRatio, state.ratio / Self.step)
            state.agreeingChecks = 0
        } else {
            state.agreeingChecks += 1
        }
        states[key] = state
    }
}
