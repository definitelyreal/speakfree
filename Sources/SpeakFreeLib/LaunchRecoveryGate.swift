// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-25
import Foundation

/// When launch crash recovery may start transcribing its next orphan.
///
/// Recovery never loads a Parakeet model itself. A Parakeet load that is not already warm
/// compiles for the Neural Engine in-process (16 to 73 s at first start), and a dictation made
/// while that runs waits the whole compile behind it. So for Parakeet, recovery only starts
/// once the Neural Engine model is loaded. It waits for the launch preparation while that runs,
/// and after a failed preparation (8 GB Macs without a stand-in, a stand-in that failed to
/// load, or a stand-in kept after a failed Neural Engine load) until a dictation or the
/// background retry has loaded the model. It never runs on the CPU stand-in, which would
/// compete with live takes on the CPU. Engines whose load cannot compile (Whisper) keep the
/// ordinary load-on-demand path.
///
/// Recovery also gives way to live dictations: it starts only while none is recording or
/// finalizing, and pauses before each chunk while one is (`Transcriber.transcribeFile`).
enum LaunchRecoveryGate {
    enum Decision: Hashable {
        /// Transcribe the next orphan now.
        case start
        /// A dictation is recording or transcribing; recovery would queue it. Poll slowly.
        case waitForDictation
        /// The launch preparation is still loading the model. Poll soon.
        case waitForModel
        /// The Neural Engine model is not loaded and loading it could compile. Wait until
        /// something else (a dictation, the background retry) has loaded it. Poll slowly.
        case waitForLoadedModel
        /// No transcriber (setup failed or model missing). Nothing to recover with.
        case stop
    }

    /// Poll interval while a dictation is active.
    static let dictationPollSeconds: Double = 30
    /// Poll interval while the launch preparation is loading the model.
    static let modelPollSeconds: Double = 2
    /// Poll interval while waiting for a model that only a dictation or retry will load.
    static let loadedModelPollSeconds: Double = 30

    /// `modelLoaded` is the engine's own model (for Parakeet the Neural Engine model; the CPU
    /// stand-in does not count).
    static func decide(dictationActive: Bool,
                       hasTranscriber: Bool,
                       preparationPending: Bool,
                       modelLoaded: Bool,
                       loadMayCompile: Bool) -> Decision {
        if dictationActive { return .waitForDictation }
        guard hasTranscriber else { return .stop }
        if modelLoaded { return .start }
        if preparationPending { return .waitForModel }
        if loadMayCompile { return .waitForLoadedModel }
        return .start
    }

    static func decide(dictationActive: Bool, transcriber: Transcriber?) -> Decision {
        decide(dictationActive: dictationActive,
               hasTranscriber: transcriber != nil,
               preparationPending: transcriber?.isPreparationPending ?? false,
               modelLoaded: transcriber?.isLoaded ?? false,
               loadMayCompile: transcriber?.modelLoadMayCompile ?? false)
    }

    /// Poll interval for a waiting decision; nil for `.start` and `.stop`.
    static func pollSeconds(for decision: Decision) -> Double? {
        switch decision {
        case .waitForDictation: return dictationPollSeconds
        case .waitForModel: return modelPollSeconds
        case .waitForLoadedModel: return loadedModelPollSeconds
        case .start, .stop: return nil
        }
    }
}

/// The launch order of the model warm-up and crash recovery, kept in one place so a test can
/// pin it: the warm-up must be marked running (`Transcriber.startPreparation`, synchronous in
/// `warmUpEngine`) before recovery first asks `LaunchRecoveryGate`.
enum LaunchModelSequence {
    static func run(orphans: [URL], warmUp: () -> Void, startRecovery: ([URL]) -> Void) {
        warmUp()
        if !orphans.isEmpty { startRecovery(orphans) }
    }
}

/// Why a background file transcription stopped early without failing.
enum BackgroundTranscriptionError: Error, Equatable {
    /// Paused for live dictations longer than `Transcriber.liveTakeMaxYieldSeconds`.
    case gaveWayToLiveTakes
}

/// Launch crash recovery's queue, free of AppKit so a test can drive it: which orphan to
/// transcribe next and how (never loading a model that could compile), when to poll again,
/// and which outcomes put an orphan back at the front of the queue.
struct LaunchRecoveryQueue {
    enum Step: Equatable {
        case done
        case wait(seconds: Double)
        case transcribe(URL, loadModelIfNeeded: Bool)
    }

    /// Delay before the next orphan after one finished or failed.
    static let betweenOrphansSeconds: Double = 5

    private(set) var pending: [URL]

    init(_ urls: [URL]) { pending = urls }

    /// The next step, given the gate's decision and whether a load could compile. A
    /// `.transcribe` step removes the orphan from the queue.
    mutating func nextStep(decision: LaunchRecoveryGate.Decision, loadMayCompile: Bool) -> Step {
        guard let url = pending.first, decision != .stop else { return .done }
        if let poll = LaunchRecoveryGate.pollSeconds(for: decision) { return .wait(seconds: poll) }
        pending.removeFirst()
        return .transcribe(url, loadModelIfNeeded: !loadMayCompile)
    }

    /// Records how an orphan's attempt ended and returns the delay before the next step, and
    /// whether the orphan went back to the front of the queue. It goes back when the attempt
    /// stopped without failing: no loaded model (never loaded here) or it gave way to live
    /// takes. Anything else is left for the next launch.
    mutating func finished(_ url: URL, error: Error?, loadModelIfNeeded: Bool)
        -> (delaySeconds: Double, requeued: Bool) {
        var requeue = false
        if let engineError = error as? TranscriptionEngineError, case .modelNotLoaded = engineError {
            requeue = !loadModelIfNeeded
        } else if let yieldError = error as? BackgroundTranscriptionError,
                  yieldError == .gaveWayToLiveTakes {
            requeue = true
        }
        guard requeue else { return (Self.betweenOrphansSeconds, false) }
        pending.insert(url, at: 0)
        return (LaunchRecoveryGate.loadedModelPollSeconds, true)
    }
}
