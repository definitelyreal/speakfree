// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// The on-device Parakeet variants SpeakFree exposes on iOS.
enum ParakeetDictationModel: String, Sendable {
    /// English-only and the default for the first iOS release.
    case englishV2 = "parakeet-tdt-0.6b-v2"
    /// Multilingual model. It is intentionally opt-in because its larger vocabulary
    /// slightly trails v2 for English-only dictation.
    case multilingualV3 = "parakeet-tdt-0.6b-v3"
}

struct ParakeetDictationResult: Sendable, Equatable {
    let text: String
    let confidence: Float
    let audioDuration: TimeInterval
    let processingTime: TimeInterval
}

enum ParakeetDictationEngineError: LocalizedError, Equatable {
    case fluidAudioNotLinked
    case invalidAudio
    case modelNotPrepared

    var errorDescription: String? {
        switch self {
        case .fluidAudioNotLinked:
            return "FluidAudio is not linked into the iOS app target."
        case .invalidAudio:
            return "Dictation audio must be nonempty, finite, 16 kHz mono Float32 samples."
        case .modelNotPrepared:
            return "The Parakeet model has not been prepared."
        }
    }
}

/// A narrow host-app adapter around FluidAudio's batch Parakeet API.
///
/// This type belongs in the containing app, not the keyboard extension. iOS custom keyboard
/// extensions cannot access the microphone even when Full Access is enabled. The containing app
/// must capture 16 kHz mono Float32 audio, call this actor, and hand finalized text to the keyboard
/// through an App Group transport designed by the app layer.
actor ParakeetDictationEngine {
    typealias ProgressHandler = @Sendable (Double) -> Void

    private(set) var preparedModel: ParakeetDictationModel?

#if canImport(FluidAudio)
    private var manager: AsrManager?
#endif

    /// Downloads and validates the model cache without retaining Core ML models in memory.
    /// The streaming EOU model remains the only resident recognizer until finalization.
    @discardableResult
    func download(
        model: ParakeetDictationModel = .englishV2,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> URL {
#if canImport(FluidAudio)
        let version: AsrModelVersion = model == .englishV2 ? .v2 : .v3
        let directory = try await AsrModels.download(
            version: version,
            progressHandler: { snapshot in
                progress(min(1, max(0, snapshot.fractionCompleted)))
            }
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        progress(1)
        return directory
#else
        _ = model
        _ = progress
        throw ParakeetDictationEngineError.fluidAudioNotLinked
#endif
    }

    /// Downloads missing model components, compiles them, and retains a loaded manager.
    /// Repeated calls for the same model are cheap and do not reload it.
    func prepare(
        model: ParakeetDictationModel = .englishV2,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws {
        if preparedModel == model {
#if canImport(FluidAudio)
            if manager != nil { return }
#endif
        }

#if canImport(FluidAudio)
        let version: AsrModelVersion = model == .englishV2 ? .v2 : .v3
        let models = try await AsrModels.downloadAndLoad(
            version: version,
            progressHandler: { snapshot in
                progress(min(1, max(0, snapshot.fractionCompleted)))
            }
        )

        // One long-form worker is the conservative iPhone default. Four workers can multiply
        // Core ML intermediates during >15-second finalization and trigger memory pressure.
        let replacement = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
        try await replacement.loadModels(models)

        if let old = manager {
            await old.cleanup()
        }
        manager = replacement
        preparedModel = model
        progress(1)
#else
        _ = model
        _ = progress
        throw ParakeetDictationEngineError.fluidAudioNotLinked
#endif
    }

    /// Transcribes complete 16 kHz mono Float32 audio. FluidAudio already marks and pads the final
    /// chunk internally; adding three seconds here would push a 12-second utterance into its much
    /// more complex long-form seam path.
    func transcribe(samples: [Float]) async throws -> ParakeetDictationResult {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw ParakeetDictationEngineError.invalidAudio
        }

#if canImport(FluidAudio)
        guard let manager else {
            throw ParakeetDictationEngineError.modelNotPrepared
        }

        var decoderState = TdtDecoderState.make(
            decoderLayers: await manager.decoderLayerCount
        )
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState
        )
        return ParakeetDictationResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: result.confidence,
            audioDuration: TimeInterval(samples.count) / 16_000,
            processingTime: result.processingTime
        )
#else
        throw ParakeetDictationEngineError.fluidAudioNotLinked
#endif
    }

    func unload() async {
#if canImport(FluidAudio)
        if let manager {
            await manager.cleanup()
        }
        manager = nil
#endif
        preparedModel = nil
    }
}
