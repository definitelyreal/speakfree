// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// First-start preparation: the Neural Engine compile runs in a helper process while a CPU-only
// stand-in serves dictations (ParakeetFirstStart.swift). Orchestration tests use a fake helper
// and a model id that is never on disk, so they spawn nothing and load nothing. The one
// real-model test is skipped unless the v3 model and VAD assets are already cached; it never
// downloads.

import FluidAudio
import XCTest
@testable import SpeakFreeLib

final class ParakeetFirstStartTests: XCTestCase {
    private let missingModel = "parakeet-test-missing"

    // MARK: - Fakes

    final class FakeHandle: CompileHelperHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []
        private(set) var canceled = false

        func finish(_ ok: Bool) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = ok
            let pending = waiters
            waiters = []
            lock.unlock()
            for waiter in pending { waiter.resume(returning: ok) }
        }

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func cancel() {
            lock.lock(); canceled = true; lock.unlock()
            finish(false)
        }
    }

    final class FakeHelper: CompileHelperStarting, @unchecked Sendable {
        private let lock = NSLock()
        private var handles: [FakeHandle] = []
        let finishImmediately: Bool?

        init(finishImmediately: Bool? = nil) { self.finishImmediately = finishImmediately }

        func start(modelID: String) -> CompileHelperHandle? {
            let handle = FakeHandle()
            if let finishImmediately { handle.finish(finishImmediately) }
            lock.lock(); handles.append(handle); lock.unlock()
            return handle
        }

        var started: [FakeHandle] { lock.lock(); defer { lock.unlock() }; return handles }
    }

    final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ModelPreparationPhase] = []
        func record(_ phase: ModelPreparationPhase) { lock.lock(); list.append(phase); lock.unlock() }
        var phases: [ModelPreparationPhase] { lock.lock(); defer { lock.unlock() }; return list }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("condition not met within \(timeout) s"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Menu copy

    func testMenuCopySaysWhatIsHappeningWithoutEmDashes() {
        XCTAssertEqual(ModelPreparationPhase.preparing(standInReady: false).menuMessage,
                       "Preparing speech model…")
        XCTAssertEqual(ModelPreparationPhase.preparing(standInReady: true).menuMessage,
                       "Preparing speech model… Dictation works meanwhile.")
        XCTAssertNil(ModelPreparationPhase.ready.menuMessage)
        for phase in [ModelPreparationPhase.preparing(standInReady: false), .preparing(standInReady: true),
                      .failed, .cpuFallback] {
            XCTAssertFalse(phase.menuMessage?.contains("—") ?? true, "\(phase)")
        }
    }

    // MARK: - Orchestration (fake helper, no model)

    func testWithoutHelperTheLoadStaysInProcess() async {
        let engine = ParakeetEngine(compileHelper: nil)
        let recorder = PhaseRecorder()
        await engine.prepareModel(modelID: missingModel) { recorder.record($0) }
        XCTAssertEqual(recorder.phases, [.preparing(standInReady: false), .failed])
        XCTAssertEqual(engine.standInAttemptsForTesting.value, 0)
    }

    func testDictationDuringCompileWaitsForPreparationInsteadOfCompilingAgain() async throws {
        let helper = FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInAllowed: false)
        let recorder = PhaseRecorder()
        let prepare = Task { await engine.prepareModel(modelID: missingModel) { recorder.record($0) } }
        try await waitUntil { helper.started.count == 1 }

        let loadReturned = LockedCounter()
        let load = Task { () -> Error? in
            defer { loadReturned.set() }
            do { try await engine.loadModel(modelID: missingModel); return nil } catch { return error }
        }
        // An in-process load of a missing model throws at once, so still being suspended here
        // proves loadModel is waiting on the preparation, not starting its own load.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(loadReturned.isSet, "loadModel must wait for the running preparation")

        helper.started[0].finish(true)
        await prepare.value
        let error = await load.value
        guard case TranscriptionEngineError.modelAssetsMissing = error ?? TranscriptionEngineError.transcriptionFailed else {
            return XCTFail("expected modelAssetsMissing after preparation failed, got \(String(describing: error))")
        }
        XCTAssertEqual(helper.started.count, 1, "one compile helper per preparation")
        XCTAssertEqual(recorder.phases, [.preparing(standInReady: false), .failed])
    }

    func testWarmHelperNeverStartsTheStandInAndDoesNotWaitOutItsDelay() async {
        let helper = FakeHelper(finishImmediately: true)
        let engine = ParakeetEngine(compileHelper: helper, standInDelaySeconds: 2)
        let start = Date()
        await engine.prepareModel(modelID: missingModel)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a warm launch must not sit out the stand-in delay")
        // Give a wrongly scheduled stand-in time to start.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.standInAttemptsForTesting.value, 0)
    }

    func testFailedHelperLoadsTheStandInBeforeTheInProcessCompile() async {
        // A helper that fails at once: the stand-in must still be tried (first, because an
        // in-process compile would block its load), without waiting for the delay.
        let helper = FakeHelper(finishImmediately: false)
        let engine = ParakeetEngine(compileHelper: helper, standInDelaySeconds: 30)
        let recorder = PhaseRecorder()
        let start = Date()
        await engine.prepareModel(modelID: missingModel) { recorder.record($0) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(engine.standInAttemptsForTesting.value, 1)
        XCTAssertEqual(recorder.phases, [.preparing(standInReady: false), .failed])
    }

    func testSlowHelperStartsTheStandInOnce() async throws {
        let helper = FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInDelaySeconds: 0.01)
        let prepare = Task { await engine.prepareModel(modelID: missingModel) }
        try await waitUntil { engine.standInAttemptsForTesting.value == 1 }
        helper.started[0].finish(true)
        await prepare.value
        XCTAssertEqual(engine.standInAttemptsForTesting.value, 1)
        XCTAssertFalse(engine.canTranscribeNow, "a missing model publishes no stand-in")
    }

    func testStandInSkippedWhenNotAllowed() async throws {
        let helper = FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInDelaySeconds: 0.01, standInAllowed: false)
        let prepare = Task { await engine.prepareModel(modelID: missingModel) }
        try await Task.sleep(nanoseconds: 200_000_000)
        helper.started[0].finish(true)
        await prepare.value
        XCTAssertEqual(engine.standInAttemptsForTesting.value, 0)
    }

    func testUnloadStopsTheHelperAndPublishesNoLaterPhase() async throws {
        let helper = FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInAllowed: false)
        let recorder = PhaseRecorder()
        let prepare = Task { await engine.prepareModel(modelID: missingModel) { recorder.record($0) } }
        try await waitUntil { helper.started.count == 1 }
        await engine.unloadModel()
        await prepare.value
        XCTAssertTrue(helper.started[0].canceled)
        XCTAssertEqual(recorder.phases, [.preparing(standInReady: false)])
        let lifecycle = await engine.lifecycleStateForTesting
        XCTAssertEqual(lifecycle.queuedOperations, 0)
        XCTAssertFalse(lifecycle.tearingDown)
    }

    // MARK: - Process helper handle (real child processes, no model)

    func testProcessHelperReportsExitStatus() async throws {
        let ok = ProcessCompileHelper(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let okResult = await ok.start(modelID: "x")?.wait()
        XCTAssertEqual(okResult, true)
        // /bin/sh tries to run a script named "precompile-parakeet" and exits nonzero.
        let bad = ProcessCompileHelper(executable: URL(fileURLWithPath: "/bin/sh"))
        let badResult = await bad.start(modelID: "x")?.wait()
        XCTAssertEqual(badResult, false)
    }

    func testProcessHelperCancelStopsAStuckHelper() async throws {
        // `yes` ignores its arguments' meaning and never exits on its own.
        let helper = ProcessCompileHelper(executable: URL(fileURLWithPath: "/usr/bin/yes"))
        let handle = try XCTUnwrap(helper.start(modelID: "x"))
        let start = Date()
        handle.cancel()
        let result = await handle.wait()
        XCTAssertFalse(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testHelperCommandRejectsBadArguments() {
        XCTAssertEqual(ParakeetCompileHelperCommand.run(arguments: []), 64)
        XCTAssertEqual(ParakeetCompileHelperCommand.run(arguments: ["not-a-model"]), 64)
        XCTAssertEqual(ParakeetCompileHelperCommand.run(arguments: ["parakeet-tdt-0.6b-v2", "extra"]), 64)
    }

    func testHelperIsOnlyUsedInsideAnAppBundle() {
        // The test runner is not an .app, so the app-bundle helper must be off here (and in the
        // CLI), keeping those loads in-process exactly as before.
        XCTAssertNil(ProcessCompileHelper.forRunningApp())
    }

    // MARK: - Real model (skipped unless cached)

    private func requireCachedModel(_ model: String) throws {
        guard ParakeetModelManager.shared.isModelDownloaded(model) else {
            throw XCTSkip("Parakeet \(model) not downloaded; this test never downloads")
        }
    }

    func testStandInIsKeptWhenTheNeuralEngineLoadFails() async throws {
        let model = "parakeet-tdt-0.6b-v3"
        try requireCachedModel(model)
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "fixture-1-clean", withExtension: "wav", subdirectory: "AudioFixtures"))
        let samples = try ProcessCommand.loadSamples(from: fixture)
        struct NeuralEngineRefused: Error {}
        let engine = ParakeetEngine(
            compileHelper: FakeHelper(finishImmediately: false), standInDelaySeconds: 30,
            neuralEngineLoadForTesting: { _ in throw NeuralEngineRefused() })
        let recorder = PhaseRecorder()
        await engine.prepareModel(modelID: model) { recorder.record($0) }
        XCTAssertEqual(recorder.phases,
                       [.preparing(standInReady: false), .preparing(standInReady: true), .cpuFallback])
        XCTAssertFalse(engine.isLoaded)
        XCTAssertTrue(engine.canTranscribeNow, "the working stand-in must not be thrown away")
        let start = Date()
        try await engine.loadModel(modelID: model)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a take must not wait on a compile")
        let text = try await engine.transcribe(samples: samples, language: "en", prompt: nil, suppressRegex: nil)
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(engine.lastDiagnostics?.inferencePath, "cpu-standin")
        await engine.unloadModel()
        XCTAssertFalse(engine.canTranscribeNow, "unload releases the stand-in")
    }

    func testAfterACPUFallbackADictationRetriesTheNeuralEngineInTheBackground() async throws {
        let model = "parakeet-tdt-0.6b-v3"
        try requireCachedModel(model)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previousDirectory = Config.configDirOverride
        Config.configDirOverride = scratch
        defer {
            Config.configDirOverride = previousDirectory
            try? FileManager.default.removeItem(at: scratch)
        }
        struct NeuralEngineRefused: Error {}
        // Only the launch-time load is made to fail; the retry uses the real load.
        let engine = ParakeetEngine(
            compileHelper: FakeHelper(finishImmediately: false), standInDelaySeconds: 30,
            neuralEngineLoadForTesting: { _ in throw NeuralEngineRefused() },
            neuralEngineRetryIntervalSeconds: 0)
        let recorder = PhaseRecorder()
        await engine.prepareModel(modelID: model) { recorder.record($0) }
        XCTAssertEqual(recorder.phases.last, .cpuFallback)
        XCTAssertFalse(engine.isLoaded)

        let start = Date()
        try await engine.loadModel(modelID: model)  // what the next dictation calls
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "the dictation must not wait for the retry")
        try await waitUntil(120) { engine.isLoaded }
        try await waitUntil(10) { recorder.phases.last == .ready }
        XCTAssertTrue(engine.canTranscribeNow)
        await engine.unloadModel()
        XCTAssertFalse(engine.canTranscribeNow)
    }

    func testUnloadDuringTheFailurePathStandInLoadLoadsNothingAfterwards() async throws {
        let model = "parakeet-tdt-0.6b-v3"
        try requireCachedModel(model)
        let engine = ParakeetEngine(compileHelper: FakeHelper(finishImmediately: false), standInDelaySeconds: 30)
        let recorder = PhaseRecorder()
        let prepare = Task { await engine.prepareModel(modelID: model) { recorder.record($0) } }
        try await waitUntil { engine.standInAttemptsForTesting.value == 1 }
        await engine.unloadModel()
        await prepare.value
        // Give any wrongly scheduled load time to land.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(engine.isLoaded, "no Neural Engine load may run after the unload")
        XCTAssertFalse(engine.canTranscribeNow)
        XCTAssertFalse(recorder.phases.contains(.ready))
    }

    func testUnloadWhileTheStandInLoadsLeavesNothingBehind() async throws {
        let model = "parakeet-tdt-0.6b-v3"
        try requireCachedModel(model)
        let helper = FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInDelaySeconds: 0.01)
        let recorder = PhaseRecorder()
        let prepare = Task { await engine.prepareModel(modelID: model) { recorder.record($0) } }
        try await waitUntil { engine.standInAttemptsForTesting.value == 1 }
        await engine.unloadModel()  // waits for the in-flight stand-in load, then releases it
        await prepare.value
        XCTAssertTrue(helper.started[0].canceled)
        XCTAssertFalse(engine.canTranscribeNow)
        XCTAssertFalse(engine.isLoaded)
        XCTAssertFalse(recorder.phases.contains(.ready))
        let lifecycle = await engine.lifecycleStateForTesting
        XCTAssertEqual(lifecycle.queuedOperations, 0)
        XCTAssertFalse(lifecycle.tearingDown)
    }

    func testStandInServesTakesUntilTheNeuralEngineModelIsReady() async throws {
        let model = "parakeet-tdt-0.6b-v3"
        try requireCachedModel(model)
        let vadDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m).deletingLastPathComponent()
            .appendingPathComponent(Repo.vad.folderName)
        guard ModelNames.VAD.requiredModels.allSatisfy({
            FileManager.default.fileExists(atPath: vadDirectory.appendingPathComponent($0).path)
        }) else {
            throw XCTSkip("Cached VAD assets required; the Neural Engine load starts endpointing")
        }
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "fixture-1-clean", withExtension: "wav", subdirectory: "AudioFixtures"))
        let samples = try ProcessCommand.loadSamples(from: fixture)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previousDirectory = Config.configDirOverride
        Config.configDirOverride = scratch
        defer {
            Config.configDirOverride = previousDirectory
            try? FileManager.default.removeItem(at: scratch)
        }

        let helper = FakeHelper()
        let engine = ParakeetEngine(compileHelper: helper, standInDelaySeconds: 0.01)
        let recorder = PhaseRecorder()
        let prepare = Task { await engine.prepareModel(modelID: model) { recorder.record($0) } }
        do {
            try await waitUntil(120) { engine.canTranscribeNow }
            XCTAssertFalse(engine.isLoaded, "the Neural Engine model waits for the helper")

            // The same call Transcriber makes: returns at once because the stand-in can serve.
            try await engine.loadModel(modelID: model)
            let cpuText = try await engine.transcribe(samples: samples, language: "en", prompt: nil, suppressRegex: nil)
            XCTAssertFalse(cpuText.isEmpty)
            XCTAssertEqual(engine.lastDiagnostics?.inferencePath, "cpu-standin")

            helper.started[0].finish(true)
            await prepare.value
            XCTAssertTrue(engine.isLoaded)
            let aneText = try await engine.transcribe(samples: samples, language: "en", prompt: nil, suppressRegex: nil)
            XCTAssertFalse(aneText.isEmpty)
            XCTAssertEqual(engine.lastDiagnostics?.inferencePath, "ane")
            XCTAssertEqual(recorder.phases,
                           [.preparing(standInReady: false), .preparing(standInReady: true), .ready])
        } catch {
            helper.started.first?.finish(false)
            await prepare.value
            await engine.unloadModel()
            throw error
        }
        await engine.unloadModel()
        XCTAssertFalse(engine.canTranscribeNow)
    }
}
