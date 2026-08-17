// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

#if canImport(CoreML)
import CoreML
#endif

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// Hybrid local dictation: a true-streaming 320 ms Parakeet EOU model supplies a revisable
/// preview, then the higher-accuracy Parakeet TDT 0.6B model replaces that entire owned preview
/// with a final result. The preview is never marked finalized, so the keyboard can prove and
/// safely replace it without rewriting host- or user-owned text.
///
/// This lives in the containing app. iOS custom keyboard extensions cannot capture microphone
/// audio, even with Full Access.
actor ParakeetStreamingDictationEngine {
    typealias ProgressHandler = @Sendable (Double) -> Void

    enum State: Sendable, Equatable {
        case idle
        case ready(ParakeetDictationModel)
        case streaming(ParakeetDictationModel)
    }

    struct Update: Sendable, Equatable {
        let confirmedText: String
        let volatileText: String
        let text: String
        let confidence: Float?
        let isConfirmed: Bool
        let isFinal: Bool
    }

    enum EngineError: LocalizedError, Equatable {
        case fluidAudioNotLinked
        case modelNotPrepared
        case streamAlreadyActive
        case noActiveStream
        case unableToCopyAudioBuffer
        case unableToConvertAudioBuffer

        var errorDescription: String? {
            switch self {
            case .fluidAudioNotLinked:
                return "FluidAudio is not linked into the iOS app target."
            case .modelNotPrepared:
                return "Prepare the Parakeet models before starting dictation."
            case .streamAlreadyActive:
                return "Finish or cancel the current dictation before starting another one."
            case .noActiveStream:
                return "There is no active Parakeet dictation stream."
            case .unableToCopyAudioBuffer:
                return "Unable to copy the microphone audio buffer."
            case .unableToConvertAudioBuffer:
                return "Unable to convert microphone audio to 16 kHz mono."
            }
        }
    }

    private(set) var state: State = .idle

#if canImport(FluidAudio)
    private var liveManager: StreamingEouAsrManager?
    private let finalEngine = ParakeetDictationEngine()
    private var streamingConverter: AVAudioConverter?
    private var streamingConverterInputFormat: AVAudioFormat?
#endif

    private var accumulatedSamples: [Float] = []
    private var lastPartial = ""
    private var modelForLiveReload: ParakeetDictationModel?
    private var activeToken: UUID?
    private var updatesContinuation: AsyncStream<Update>.Continuation?
    private var updatesToken: UUID?

    /// The background intent must never turn a missing 657 MiB onboarding download into an
    /// invisible network operation. Require both complete caches before it attempts model load.
    nonisolated static var requiredModelsAreCached: Bool {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return false }
        let root = support.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let v2 = root.appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
        // FluidAudio's default EOU root already contains `parakeet-eou-streaming`; the repository
        // folder adds that component again. Bind to the audited pinned revision's exact layout.
        let eou = root.appendingPathComponent(
            "parakeet-eou-streaming/parakeet-eou-streaming/320ms",
            isDirectory: true
        )
        return cacheIsComplete(
            at: v2,
            files: [
                "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                "JointDecision.mlmodelc", "parakeet_vocab.json"
            ]
        ) && cacheIsComplete(
            at: eou,
            files: [
                "streaming_encoder.mlmodelc", "decoder.mlmodelc",
                "joint_decision.mlmodelc", "vocab.json"
            ]
        )
    }

    private nonisolated static func cacheIsComplete(at directory: URL, files: [String]) -> Bool {
        let fileManager = FileManager.default
        guard files.allSatisfy({ name in
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                return fileManager.fileExists(
                    atPath: url.appendingPathComponent("coremldata.bin").path
                )
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return false
            }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }) else { return false }
        let partials = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasSuffix(".partial") }
        return partials != true
    }

    var updates: AsyncStream<Update> {
        let token = UUID()
        return AsyncStream { continuation in
            updatesContinuation?.finish()
            updatesContinuation = continuation
            updatesToken = token
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.clearUpdatesContinuation(ifMatching: token) }
            }
        }
    }

    /// Prepares the live track and downloads the final model without retaining it. Progress
    /// 0...0.35 is the 320 ms streaming model; the remainder is the English TDT final model.
    /// Keeping only one recognizer resident avoids a roughly two-model Core ML memory peak.
    func prepare(
        model: ParakeetDictationModel = .englishV2,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws {
        guard !isStreaming else { throw EngineError.streamAlreadyActive }

#if canImport(FluidAudio)
        if case .ready(model) = state, liveManager != nil {
            progress(1)
            return
        }

        // In the pinned FluidAudio revision `AsrModels.download` still transiently compiles model
        // files. Do that before retaining the EOU recognizer so onboarding never holds both.
        do {
            _ = try await finalEngine.download(model: model) { finalProgress in
                progress(0.65 * min(1, max(0, finalProgress)))
            }
        } catch {
            throw error
        }
        let live = makeLiveManager()
        try await live.loadModels(progressHandler: { snapshot in
            progress(0.65 + 0.35 * min(1, max(0, snapshot.fractionCompleted)))
        })
        excludeFluidAudioModelsFromBackup()
        liveManager = live
        modelForLiveReload = model
        state = .ready(model)
        progress(1)
#else
        _ = model
        _ = progress
        throw EngineError.fluidAudioNotLinked
#endif
    }

    func begin() async throws {
        guard !isStreaming else { throw EngineError.streamAlreadyActive }

#if canImport(FluidAudio)
        guard let liveManager, case .ready(let model) = state else {
            throw EngineError.modelNotPrepared
        }
        await liveManager.reset()
        accumulatedSamples.removeAll(keepingCapacity: true)
        streamingConverter = nil
        streamingConverterInputFormat = nil
        lastPartial = ""
        activeToken = UUID()
        state = .streaming(model)
#else
        throw EngineError.fluidAudioNotLinked
#endif
    }

    /// Feed buffers in capture order. The controller owns a single sequential pump so model work
    /// never runs on the realtime audio callback and buffers cannot be reordered by detached tasks.
    func append(_ buffer: AVAudioPCMBuffer) async throws {
        guard isStreaming else { throw EngineError.noActiveStream }

#if canImport(FluidAudio)
        guard let liveManager else { throw EngineError.noActiveStream }
        let modelBuffer = try convertToModelFormat(buffer)
        guard let channel = modelBuffer.floatChannelData?[0] else {
            throw EngineError.unableToConvertAudioBuffer
        }
        accumulatedSamples.append(contentsOf: UnsafeBufferPointer(
            start: channel,
            count: Int(modelBuffer.frameLength)
        ))
        _ = try await liveManager.process(audioBuffer: modelBuffer)
        let partial = await liveManager.getPartialTranscript()
        if let activeToken {
            publishPartial(partial, token: activeToken)
        }
#else
        _ = buffer
        throw EngineError.fluidAudioNotLinked
#endif
    }

    nonisolated static func copyForStreaming(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else {
            throw EngineError.unableToCopyAudioBuffer
        }
        return copy
    }

    /// Flush the low-latency track, then run a complete-utterance TDT decode. If the final track
    /// fails but the live model produced text, preserve that text rather than losing the utterance.
    func finish(
        checkpointLiveFallback: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        guard isStreaming else { throw EngineError.noActiveStream }

#if canImport(FluidAudio)
        guard let liveManager else { throw EngineError.noActiveStream }
        let model = activeModel
        try await drainStreamingConverter(into: liveManager)
        let fallback = (try? await liveManager.finish())?.trimmedForDictation
        if let fallback, !fallback.isEmpty {
            // Persist the fully drained streaming result before the larger batch recognizer starts.
            // A background-time expiration during that pass can then preserve every captured word.
            await checkpointLiveFallback(fallback)
        }
        activeToken = nil

        // Move ownership of the long-session buffer instead of COW-clearing it while aliased.
        // At the five-minute cap, retaining both capacities costs roughly 48 MiB exactly when the
        // larger final model is loading.
        var samples = accumulatedSamples
        accumulatedSamples = []
        await liveManager.cleanup()
        self.liveManager = nil

        var finalResult: ParakeetDictationResult?
        do {
            try Task.checkCancellation()
            try await finalEngine.prepare(model: model ?? .englishV2)
            finalResult = try await finalEngine.transcribe(samples: samples)
            try Task.checkCancellation()
        } catch is CancellationError {
            await finalEngine.unload()
            samples.removeAll(keepingCapacity: false)
            throw CancellationError()
        } catch {
            // Preserve the usable live transcript. A failed high-quality pass must not erase it.
            finalResult = nil
        }
        await finalEngine.unload()
        samples.removeAll(keepingCapacity: false)
        let finalText = [finalResult?.text.trimmedForDictation, fallback, lastPartial]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""

        // Do not hold the completed final transcript behind low-priority model rehydration. The
        // controller first persists the terminal snapshot and ends the Live Activity, then asks
        // us to restore the live model for the next session.
        modelForLiveReload = model
        state = .idle
        updatesContinuation?.yield(Update(
            confirmedText: finalText,
            volatileText: "",
            text: finalText,
            confidence: finalResult?.confidence,
            isConfirmed: true,
            isFinal: true
        ))
        return finalText
#else
        throw EngineError.fluidAudioNotLinked
#endif
    }

    func restoreLiveModel() async throws {
#if canImport(FluidAudio)
        guard liveManager == nil, let modelForLiveReload else { return }
        let replacement = makeLiveManager()
        try await replacement.loadModels()
        liveManager = replacement
        state = .ready(modelForLiveReload)
#endif
    }

    func cancel() async {
#if canImport(FluidAudio)
        guard let liveManager else { return }
        let model = activeModel
        activeToken = nil
        await liveManager.reset()
        accumulatedSamples.removeAll(keepingCapacity: false)
        streamingConverter = nil
        streamingConverterInputFormat = nil
        lastPartial = ""
        state = model.map(State.ready) ?? .idle
#endif
    }

    func cleanup() async {
#if canImport(FluidAudio)
        if let liveManager { await liveManager.cleanup() }
        await finalEngine.unload()
        self.liveManager = nil
#endif
        activeToken = nil
        accumulatedSamples.removeAll(keepingCapacity: false)
        streamingConverter = nil
        streamingConverterInputFormat = nil
        lastPartial = ""
        state = .idle
        modelForLiveReload = nil
        updatesContinuation?.finish()
        updatesContinuation = nil
        updatesToken = nil
    }

    private var isStreaming: Bool {
        if case .streaming = state { return true }
        return false
    }

    private var activeModel: ParakeetDictationModel? {
        if case .streaming(let model) = state { return model }
        return nil
    }

    var isReadyForNextSession: Bool {
        if case .ready = state { return true }
        return false
    }

#if canImport(FluidAudio) && canImport(CoreML)
    private func makeLiveManager() -> StreamingEouAsrManager {
        let configuration = MLModelConfiguration()
        // GPU work is not eligible for the containing app's background recording path.
        configuration.computeUnits = .cpuAndNeuralEngine
        return StreamingEouAsrManager(configuration: configuration, chunkSize: .ms320)
    }
#endif

    private func publishPartial(_ rawText: String, token: UUID) {
        guard token == activeToken, isStreaming else { return }
        let text = rawText
            .replacingOccurrences(of: "<EOU>", with: "")
            .trimmedForDictation
        guard text != lastPartial else { return }
        lastPartial = text
        updatesContinuation?.yield(Update(
            confirmedText: "",
            volatileText: text,
            text: text,
            confidence: nil,
            isConfirmed: false,
            isFinal: false
        ))
    }

#if canImport(AVFoundation)
    /// Uses one stateful converter across callback boundaries and feeds the exact same 16 kHz
    /// samples to both recognizers. Recreating a converter for every 1,024-frame tap can lose or
    /// duplicate fractional-rate samples at 44.1/48 kHz boundaries.
    private func convertToModelFormat(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard input.frameLength > 0,
              input.format.sampleRate > 0,
              input.format.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
              ) else {
            throw EngineError.unableToConvertAudioBuffer
        }

        if streamingConverter != nil,
           !formatsMatch(streamingConverterInputFormat, input.format) {
            // Route changes are session boundaries. Replacing a stateful converter mid-stream
            // would discard its filter tail and corrupt final sample timing.
            throw EngineError.unableToConvertAudioBuffer
        }
        if streamingConverter == nil {
            guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw EngineError.unableToConvertAudioBuffer
            }
            streamingConverter = converter
            streamingConverterInputFormat = input.format
        }
        guard let streamingConverter else { throw EngineError.unableToConvertAudioBuffer }

        let estimatedFrames = ceil(
            Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate
        )
        guard estimatedFrames.isFinite,
              let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(estimatedFrames) + 64
              ) else {
            throw EngineError.unableToConvertAudioBuffer
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = streamingConverter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error else {
            throw EngineError.unableToConvertAudioBuffer
        }
        return output
    }

    private func drainStreamingConverter(
        into liveManager: StreamingEouAsrManager
    ) async throws {
        guard let streamingConverter else { return }
        let outputFormat = streamingConverter.outputFormat

        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 4_096
            ) else {
                throw EngineError.unableToConvertAudioBuffer
            }
            var conversionError: NSError?
            let status = streamingConverter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard conversionError == nil, status != .error else {
                throw EngineError.unableToConvertAudioBuffer
            }
            if output.frameLength > 0 {
                guard let channel = output.floatChannelData?[0] else {
                    throw EngineError.unableToConvertAudioBuffer
                }
                accumulatedSamples.append(contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(output.frameLength)
                ))
                _ = try await liveManager.process(audioBuffer: output)
                if let activeToken {
                    publishPartial(await liveManager.getPartialTranscript(), token: activeToken)
                }
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }

        self.streamingConverter = nil
        streamingConverterInputFormat = nil
    }

    private func formatsMatch(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
#endif

    private func clearUpdatesContinuation(ifMatching token: UUID) {
        guard updatesToken == token else { return }
        updatesContinuation = nil
        updatesToken = nil
    }

    private func excludeFluidAudioModelsFromBackup() {
        guard var modelsRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true),
              FileManager.default.fileExists(atPath: modelsRoot.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? modelsRoot.setResourceValues(values)
    }
}

private extension String {
    var trimmedForDictation: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
