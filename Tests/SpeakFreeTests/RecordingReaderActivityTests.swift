// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
import XCTest
@testable import SpeakFreeLib

final class RecordingReaderActivityTests: XCTestCase {
    private actor Gate {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    private final class Engine: TranscriptionEngine {
        let engineID = "synthetic"
        var keepModelLoaded = "auto"
        var supportsStreaming: Bool { false }
        var supportsPrompt: Bool { false }
        var isLoaded = false
        var loadCalls = 0
        var load: () async throws -> Void = {}
        var infer: () async throws -> Void = {}
        func loadModel(modelID: String) async throws { loadCalls += 1; try await load(); isLoaded = true }
        func unloadModel() async { isLoaded = false }
        func startMemoryPressureMonitoring() {}
        func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String {
            XCTAssertFalse(samples.isEmpty)
            try await infer()
            return "synthetic speech"
        }
        func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                                 onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    private let fm = FileManager.default
    private var root: URL!
    private var recordings: URL!
    private var audio: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recording-reader-\(UUID())")
        recordings = root.appendingPathComponent("recordings")
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        Config.configDirOverride = root
        audio = recordings.appendingPathComponent("recording-2026-01-01-120000-reader.wav")
        let writer = try WavWriter(url: audio)
        try writer.append(Array(repeating: 0.1, count: 16_000)); writer.close()
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = nil
        try fm.removeItem(at: root)
    }

    private func remove() -> RecordingRemoval.Result {
        RecordingStore.trashAllRecordings(trash: { staged in
            let destination = self.root.appendingPathComponent("fake-trash-\(UUID())")
            try RecordingRemoval.moveWithoutReplacing(staged, destination)
            return destination
        })
    }

    private func transcriber(_ engine: Engine) -> Transcriber {
        Transcriber(engine: engine, modelID: "synthetic-no-download", language: "en")
    }

    func testColdFileLoadProtectsURLAndCancellationWaitsForTaskExit() async throws {
        let gate = Gate(), entered = expectation(description: "model load entered")
        let engine = Engine()
        engine.load = { entered.fulfill(); await gate.wait(); try Task.checkCancellation() }
        let transcriber = transcriber(engine), audio = try XCTUnwrap(self.audio)
        let task = Task {
            try await transcriber.transcribeFile(url: audio, progressHandler: { _, _, _ in }, isCancelled: { false })
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        let protected = remove()
        XCTAssertEqual(protected.retainedRecordings, 1)
        XCTAssertTrue(fm.fileExists(atPath: audio.path))
        await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(remove().removedFiles, 1)
    }

    func testFileReadStaysProtectedThroughAwaitedInference() async throws {
        let gate = Gate(), entered = expectation(description: "PCM read and inference entered")
        let engine = Engine()
        engine.isLoaded = true
        engine.infer = { entered.fulfill(); await gate.wait() }
        let transcriber = transcriber(engine), audio = try XCTUnwrap(self.audio)
        let task = Task {
            try await transcriber.transcribeFile(url: audio, progressHandler: { _, _, _ in }, isCancelled: { false })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(remove().retainedRecordings, 1)
        await gate.open()
        let text = try await task.value
        XCTAssertEqual(text, "synthetic speech")
        XCTAssertEqual(remove().removedFiles, 1)
    }

    func testClaimedFileFailsBeforeModelLoading() async throws {
        let engine = Engine(), removal = RecordingActivity.shared.beginRemoval(in: recordings)
        XCTAssertTrue(removal.claim(audio))
        do {
            _ = try await transcriber(engine).transcribeFile(url: audio,
                progressHandler: { _, _, _ in }, isCancelled: { false })
            XCTFail("A claimed recording must not start work")
        } catch { XCTAssertTrue(error is RecordingActivity.ActivityError) }
        XCTAssertEqual(engine.loadCalls, 0)
        removal.finish()
    }

    func testThrownModelLoadReleasesFileAdmission() async throws {
        enum Failure: Error { case synthetic }
        let engine = Engine()
        engine.load = { throw Failure.synthetic }
        do {
            _ = try await transcriber(engine).transcribeFile(url: audio,
                progressHandler: { _, _, _ in }, isCancelled: { false })
            XCTFail("Expected synthetic load failure")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(remove().removedFiles, 1)
    }
}
