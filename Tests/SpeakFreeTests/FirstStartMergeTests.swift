// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-25
//
// Where perf/first-start meets dogfood's speed loop: the key-press preload must leave the first
// Parakeet load to the launch preparation, and a live take's path / model wait / priority go on
// the one per-take "Latency:" line (scripts/latency-report.py parses it).

import XCTest
@testable import SpeakFreeLib

final class FirstStartMergeTests: XCTestCase {
    private final class SlowLoadEngine: TranscriptionEngine, @unchecked Sendable {
        let engineID = "whisper"
        private let lock = NSLock()
        private var loaded = false
        var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }
        let supportsStreaming = false
        let supportsPrompt = false
        var keepModelLoaded = "auto"
        func loadModel(modelID: String) async throws {
            try await Task.sleep(nanoseconds: 50_000_000)
            markLoaded()
        }
        private func markLoaded() { lock.lock(); loaded = true; lock.unlock() }
        func unloadModel() async {}
        func startMemoryPressureMonitoring() {}
        func transcribe(samples: [Float], language: String, prompt: String?,
                        suppressRegex: String?) async throws -> String { "hello there" }
        func transcribeStreaming(samples: [Float], language: String, prompt: String?,
                                 suppressRegex: String?, onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    func testPreparationReadsPendingBeforeItsTaskRunsAndClearsAfter() async {
        let transcriber = Transcriber(engine: SlowLoadEngine(), modelID: "m", language: "en")
        XCTAssertFalse(transcriber.isPreparationPending)
        let task = transcriber.startPreparation { _ in }
        // Synchronous: a key press right after launch already sees it.
        XCTAssertTrue(transcriber.isPreparationPending)
        await task.value
        XCTAssertFalse(transcriber.isPreparationPending)
        XCTAssertTrue(transcriber.isReadyToTranscribe)
    }

    func testLiveTakeHandsPathAndModelWaitToItsRecorder() async throws {
        let transcriber = Transcriber(engine: SlowLoadEngine(), modelID: "m", language: "en")
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        let recorder = TakeRecorder()
        let text = try await TakeRecorder.$current.withValue(recorder) {
            try await transcriber.transcribe(audioURL: url, samples: Array(repeating: 0.2, count: 16_000))
        }
        XCTAssertTrue(text.lowercased().contains("hello there"), text)
        XCTAssertEqual(recorder.inferencePath, "whisper")
        XCTAssertGreaterThanOrEqual(recorder.modelWaitSeconds ?? -1, 0.04, "the cold load counts as model wait")
    }

    func testLatencyLineAppendsFirstStartFieldsOnlyWhenKnown() {
        var t = TakeLatency(keyRelease: 0)
        t.finalizeStart = 0.1; t.gateEnd = 0.1; t.inferStart = 0.1; t.inferEnd = 0.3
        t.pipelineEnd = 0.31; t.insertEnd = 0.35
        let plain = t.logLine(chars: 3, audioSeconds: 1, engine: "parakeet")
        XCTAssertTrue(plain.hasSuffix(" engine=parakeet"), plain)
        t.path = "cpu-standin"; t.modelWait = 0.0123; t.qos = "userInitiated"
        let line = t.logLine(chars: 3, audioSeconds: 1, engine: "parakeet")
        XCTAssertTrue(line.hasSuffix(" engine=parakeet path=cpu-standin modelWait=0.012 qos=userInitiated"), line)
    }
}
