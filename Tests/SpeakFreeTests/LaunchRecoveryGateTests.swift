// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-25
//
// Launch crash recovery must never load a Parakeet model itself (a load that is not warm is a
// Neural Engine compile a dictation would wait behind), must give way to live dictations, and
// must start only after the launch warm-up is marked running. No real model: a fake compile
// helper holds the preparation open, and fake engines count loads and inference calls.

import AVFoundation
import XCTest
@testable import SpeakFreeLib

final class LaunchRecoveryGateTests: XCTestCase {
    private let missingModel = "parakeet-test-missing"

    // MARK: - Fakes

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool = false) { self.value = value }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    /// A Parakeet-like engine that is never loaded unless `loadModel` runs, and counts both.
    /// `onTranscribe` runs at the start of every inference call, with its call index.
    final class CountingEngine: TranscriptionEngine, @unchecked Sendable {
        let engineID = "parakeet"
        var keepModelLoaded = "auto"
        var supportsStreaming: Bool { false }
        var supportsPrompt: Bool { false }
        private let lock = NSLock()
        private var loaded: Bool
        private var loads = 0
        private var calls = 0
        var onTranscribe: (Int) -> Void = { _ in }

        init(loaded: Bool) { self.loaded = loaded }

        var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }
        var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
        var transcribeCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func loadModel(modelID: String) async throws {
            lock.lock(); loads += 1; loaded = true; lock.unlock()
        }
        func unloadModel() async { lock.lock(); loaded = false; lock.unlock() }
        func startMemoryPressureMonitoring() {}
        func transcribe(samples: [Float], language: String, prompt: String?,
                        suppressRegex: String?) async throws -> String {
            lock.lock(); let index = calls; calls += 1; lock.unlock()
            onTranscribe(index)
            return "chunk \(index) text."
        }
        func transcribeStreaming(samples: [Float], language: String, prompt: String?,
                                 suppressRegex: String?,
                                 onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    /// Mono 16-bit WAV of a low tone (so no chunk is dropped as empty).
    private func writeWAV(seconds: Double, sampleRate: Double = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-recovery-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let total = AVAudioFrameCount(seconds * sampleRate)
        var written: AVAudioFrameCount = 0
        var phase: Float = 0
        let inc: Float = 2 * .pi * 220 / Float(sampleRate)
        while written < total {
            let n = min(16_000, total - written)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            buf.frameLength = n
            for i in 0..<Int(n) { buf.floatChannelData![0][i] = 0.05 * sin(phase); phase += inc }
            try file.write(from: buf)
            written += n
        }
        return url
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("\(what) not within \(timeout) s") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Gate decisions

    func testDecisionTable() {
        typealias G = LaunchRecoveryGate
        func d(active: Bool = false, has: Bool = true, pending: Bool = false,
               ready: Bool = false, compile: Bool = true) -> G.Decision {
            G.decide(dictationActive: active, hasTranscriber: has, preparationPending: pending,
                     modelLoaded: ready, loadMayCompile: compile)
        }
        XCTAssertEqual(d(active: true, ready: true), .waitForDictation)
        XCTAssertEqual(d(has: false), .stop)
        // Preparation running without the Neural Engine model (whether or not the CPU stand-in
        // serves; recovery never uses the stand-in, item 2): wait.
        XCTAssertEqual(d(pending: true), .waitForModel)
        // Neural Engine model loaded: start.
        XCTAssertEqual(d(ready: true), .start)
        XCTAssertEqual(d(pending: true, ready: true), .start)
        // Review item 1: the preparation ended without a model or stand-in (8 GB Mac, or the
        // stand-in failed). A Parakeet load could compile: wait, never load.
        XCTAssertEqual(d(), .waitForLoadedModel)
        // Whisper (a load cannot compile): the ordinary load path.
        XCTAssertEqual(d(compile: false), .start)
        XCTAssertEqual(G.decide(dictationActive: false, transcriber: nil), .stop)

        XCTAssertEqual(G.pollSeconds(for: .waitForModel), G.modelPollSeconds)
        XCTAssertEqual(G.pollSeconds(for: .waitForLoadedModel), G.loadedModelPollSeconds)
        XCTAssertEqual(G.pollSeconds(for: .waitForDictation), G.dictationPollSeconds)
        XCTAssertNil(G.pollSeconds(for: .start))
        XCTAssertNil(G.pollSeconds(for: .stop))
    }

    /// While the compile helper runs (no stand-in), recovery waits. When the preparation fails
    /// with no stand-in (the 8 GB case), recovery still waits instead of starting its own
    /// Neural Engine compile.
    func testRecoveryNeverStartsACompileAfterAFailedPreparationWithoutStandIn() async throws {
        let helper = ParakeetFirstStartTests.FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInAllowed: false)
        let transcriber = Transcriber(engine: engine, modelID: missingModel, language: "en")
        XCTAssertTrue(transcriber.modelLoadMayCompile)

        let preparation = transcriber.startPreparation { _ in }
        // Checked synchronously after startPreparation, before its task has even run.
        XCTAssertEqual(LaunchRecoveryGate.decide(dictationActive: false, transcriber: transcriber),
                       .waitForModel)

        try await waitUntil("compile helper start") { !helper.started.isEmpty }
        XCTAssertEqual(LaunchRecoveryGate.decide(dictationActive: false, transcriber: transcriber),
                       .waitForModel, "compiling without a stand-in: recovery must not load")

        helper.started[0].finish(false)
        await preparation.value
        XCTAssertFalse(transcriber.isPreparationPending)
        XCTAssertFalse(transcriber.isReadyToTranscribe)
        XCTAssertEqual(LaunchRecoveryGate.decide(dictationActive: false, transcriber: transcriber),
                       .waitForLoadedModel, "failed warm-up, no stand-in: recovery must not load")
        XCTAssertEqual(helper.started.count, 1, "recovery never started a second compile")
    }

    // MARK: - Recovery's file path never loads (item 1)

    func testBackgroundTranscribeFileNeverLoadsTheModel() async throws {
        let engine = CountingEngine(loaded: false)
        let transcriber = Transcriber(engine: engine, modelID: missingModel, language: "en")
        let url = try writeWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await transcriber.transcribeFile(url: url, progressHandler: { _, _, _ in },
                                                     isCancelled: { false }, loadModelIfNeeded: false)
            XCTFail("expected modelNotLoaded")
        } catch TranscriptionEngineError.modelNotLoaded {
        } catch {
            XCTFail("expected modelNotLoaded, got \(error)")
        }
        XCTAssertEqual(engine.loadCount, 0, "background recovery must never load the model")
        XCTAssertEqual(engine.transcribeCount, 0)

        // Default callers (file transcription the user started) still load on demand.
        _ = try await transcriber.transcribeFile(url: url, progressHandler: { _, _, _ in },
                                                 isCancelled: { false })
        XCTAssertEqual(engine.loadCount, 1)
    }

    /// The real engine after a failed preparation with no stand-in: the background file path
    /// throws modelNotLoaded (it did not try a load, which would report missing assets) and
    /// starts no compile.
    func testBackgroundTranscribeFileOnRealEngineWithoutModelDoesNotLoad() async throws {
        let helper = ParakeetFirstStartTests.FakeHelper(finishImmediately: false)
        let engine = ParakeetEngine(compileHelper: helper, standInAllowed: false)
        let transcriber = Transcriber(engine: engine, modelID: missingModel, language: "en")
        await transcriber.startPreparation { _ in }.value
        let url = try writeWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await transcriber.transcribeFile(url: url, progressHandler: { _, _, _ in },
                                                     isCancelled: { false }, loadModelIfNeeded: false)
            XCTFail("expected modelNotLoaded")
        } catch TranscriptionEngineError.modelNotLoaded {
        } catch {
            XCTFail("expected modelNotLoaded (no load attempted), got \(error)")
        }
        XCTAssertEqual(helper.started.count, 1)
    }

    // MARK: - Live takes go first (item 2)

    func testRecoveryChunkWaitsWhileALiveTakeIsActive() async throws {
        let engine = CountingEngine(loaded: true)
        let transcriber = Transcriber(engine: engine, modelID: missingModel, language: "en")
        let url = try writeWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let live = Flag(true)

        let recovery = Task {
            try await transcriber.transcribeFile(
                url: url, progressHandler: { _, _, _ in }, isCancelled: { false },
                loadModelIfNeeded: false, isLiveTakeActive: { live.isSet })
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(engine.transcribeCount, 0, "no recovery inference while a live take is active")
        live.set(false)
        let text = try await recovery.value
        XCTAssertEqual(engine.transcribeCount, 1)
        XCTAssertEqual(text, "chunk 0 text.")
    }

    /// A take that starts during a multi-chunk recovery holds the next chunk until it is done.
    func testRecoveryPausesBetweenChunksForATakeThatStartsMidFile() async throws {
        let engine = CountingEngine(loaded: true)
        let live = Flag(false)
        engine.onTranscribe = { index in if index == 0 { live.set(true) } }
        let transcriber = Transcriber(engine: engine, modelID: missingModel, language: "en")
        // Several 5-minute chunks (as in TranscribeFileNewlineTests); a low rate keeps it small.
        let url = try writeWAV(seconds: 11 * 60, sampleRate: 4_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let recovery = Task {
            try await transcriber.transcribeFile(
                url: url, progressHandler: { _, _, _ in }, isCancelled: { false },
                loadModelIfNeeded: false, isLiveTakeActive: { live.isSet })
        }
        try await waitUntil("first chunk") { engine.transcribeCount == 1 }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(engine.transcribeCount, 1, "second chunk must wait for the live take")
        live.set(false)
        _ = try await recovery.value
        XCTAssertGreaterThanOrEqual(engine.transcribeCount, 2)
    }

    /// Review round 1: a model that goes away mid-file ends the background pass before the
    /// next chunk (no load, no CPU stand-in).
    func testBackgroundTranscribeFileStopsWhenTheModelGoesAwayMidFile() async throws {
        let engine = CountingEngine(loaded: true)
        engine.onTranscribe = { index in if index == 0 { Task { await engine.unloadModel() } } }
        let transcriber = Transcriber(engine: engine, modelID: missingModel, language: "en")
        let url = try writeWAV(seconds: 11 * 60, sampleRate: 4_000)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            // The live-take check sleeps 50 ms, so the unload lands before the second chunk.
            _ = try await transcriber.transcribeFile(
                url: url, progressHandler: { _, _, _ in }, isCancelled: { false },
                loadModelIfNeeded: false,
                isLiveTakeActive: { try? await Task.sleep(nanoseconds: 50_000_000); return false })
            XCTFail("expected modelNotLoaded")
        } catch TranscriptionEngineError.modelNotLoaded {
        } catch {
            XCTFail("expected modelNotLoaded, got \(error)")
        }
        XCTAssertEqual(engine.transcribeCount, 1)
        XCTAssertEqual(engine.loadCount, 0)
    }

    func testYieldToLiveTakesGivesUpAfterTheLimit() async {
        do {
            try await Transcriber.yieldToLiveTakes(isLiveTakeActive: { true }, isCancelled: { false },
                                                   pollNanoseconds: 1_000_000, maxYieldSeconds: 0.05)
            XCTFail("expected to give up")
        } catch BackgroundTranscriptionError.gaveWayToLiveTakes {
        } catch {
            XCTFail("expected gaveWayToLiveTakes, got \(error)")
        }
    }

    // MARK: - Recovery queue (AppDelegate's driver)

    func testQueueWaitsTranscribesAndNeverAsksToLoadACompilingModel() {
        let a = URL(fileURLWithPath: "/orphans/a.wav"), b = URL(fileURLWithPath: "/orphans/b.wav")
        var queue = LaunchRecoveryQueue([a, b])
        XCTAssertEqual(queue.nextStep(decision: .waitForModel, loadMayCompile: true),
                       .wait(seconds: LaunchRecoveryGate.modelPollSeconds))
        XCTAssertEqual(queue.nextStep(decision: .waitForLoadedModel, loadMayCompile: true),
                       .wait(seconds: LaunchRecoveryGate.loadedModelPollSeconds))
        XCTAssertEqual(queue.nextStep(decision: .waitForDictation, loadMayCompile: true),
                       .wait(seconds: LaunchRecoveryGate.dictationPollSeconds))
        XCTAssertEqual(queue.pending, [a, b], "waiting never drops an orphan")
        // Parakeet: never load. Whisper: the ordinary load path.
        XCTAssertEqual(queue.nextStep(decision: .start, loadMayCompile: true),
                       .transcribe(a, loadModelIfNeeded: false))
        XCTAssertEqual(queue.nextStep(decision: .start, loadMayCompile: false),
                       .transcribe(b, loadModelIfNeeded: true))
        XCTAssertEqual(queue.nextStep(decision: .start, loadMayCompile: true), .done)

        var stopped = LaunchRecoveryQueue([a])
        XCTAssertEqual(stopped.nextStep(decision: .stop, loadMayCompile: true), .done)
    }

    func testQueuePutsBackOrphansThatStoppedWithoutFailing() {
        let a = URL(fileURLWithPath: "/orphans/a.wav"), b = URL(fileURLWithPath: "/orphans/b.wav")
        var queue = LaunchRecoveryQueue([a, b])
        _ = queue.nextStep(decision: .start, loadMayCompile: true)

        // No loaded model (never loaded here): back to the front, retried after the slow poll.
        var outcome = queue.finished(a, error: TranscriptionEngineError.modelNotLoaded,
                                     loadModelIfNeeded: false)
        XCTAssertTrue(outcome.requeued)
        XCTAssertEqual(outcome.delaySeconds, LaunchRecoveryGate.loadedModelPollSeconds)
        XCTAssertEqual(queue.pending, [a, b])

        // Gave way to live takes for too long: back to the front.
        _ = queue.nextStep(decision: .start, loadMayCompile: true)
        outcome = queue.finished(a, error: BackgroundTranscriptionError.gaveWayToLiveTakes,
                                 loadModelIfNeeded: false)
        XCTAssertTrue(outcome.requeued)
        XCTAssertEqual(queue.pending, [a, b])

        // A real failure, or success: left for the next launch, next orphan after 5 s.
        _ = queue.nextStep(decision: .start, loadMayCompile: true)
        outcome = queue.finished(a, error: TranscriptionEngineError.transcriptionFailed,
                                 loadModelIfNeeded: false)
        XCTAssertFalse(outcome.requeued)
        XCTAssertEqual(outcome.delaySeconds, LaunchRecoveryQueue.betweenOrphansSeconds)
        _ = queue.nextStep(decision: .start, loadMayCompile: false)
        outcome = queue.finished(b, error: TranscriptionEngineError.modelNotLoaded,
                                 loadModelIfNeeded: true)
        XCTAssertFalse(outcome.requeued, "a load-allowed engine's failure is a real failure")
        outcome = queue.finished(b, error: nil, loadModelIfNeeded: true)
        XCTAssertFalse(outcome.requeued)
        XCTAssertEqual(queue.pending, [])
    }

    func testYieldToLiveTakesStopsOnCancellation() async {
        do {
            try await Transcriber.yieldToLiveTakes(isLiveTakeActive: { true }, isCancelled: { true },
                                                   pollNanoseconds: 1_000_000)
            XCTFail("expected cancellation to throw")
        } catch {}
    }

    // MARK: - Launch order (item 3)

    func testLaunchSequenceStartsRecoveryOnlyAfterWarmUpIsMarkedRunning() async throws {
        let helper = ParakeetFirstStartTests.FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInAllowed: false)
        let transcriber = Transcriber(engine: engine, modelID: missingModel, language: "en")
        var events: [String] = []
        var decisionAtRecoveryStart: LaunchRecoveryGate.Decision?
        var preparation: Task<Void, Never>?
        let orphan = URL(fileURLWithPath: "/nonexistent/orphan.wav")

        LaunchModelSequence.run(
            orphans: [orphan],
            warmUp: {
                events.append("warmUp")
                preparation = transcriber.startPreparation { _ in }
            },
            startRecovery: { urls in
                events.append("recovery")
                XCTAssertEqual(urls, [orphan])
                XCTAssertTrue(transcriber.isPreparationPending,
                              "recovery started before the warm-up was marked running")
                decisionAtRecoveryStart = LaunchRecoveryGate.decide(dictationActive: false,
                                                                    transcriber: transcriber)
            })

        XCTAssertEqual(events, ["warmUp", "recovery"])
        XCTAssertEqual(decisionAtRecoveryStart, .waitForModel)

        try await waitUntil("compile helper start") { !helper.started.isEmpty }
        helper.started[0].finish(false)
        await preparation?.value
    }

    func testLaunchSequenceSkipsRecoveryWithoutOrphans() {
        var events: [String] = []
        LaunchModelSequence.run(orphans: [], warmUp: { events.append("warmUp") },
                                startRecovery: { _ in events.append("recovery") })
        XCTAssertEqual(events, ["warmUp"])
    }
}
