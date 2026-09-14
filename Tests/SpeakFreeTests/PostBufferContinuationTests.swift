// ai-suggestion:unverified · session:01a09da8-0424-7b71-a705-10868c5f46e4 · 2026-09-13

import XCTest
@testable import SpeakFreeLib

private final class PostBufferCapture: DeviceCapturing {
    var deliver: ((CapturePacket) -> Void)?
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
               failure: @escaping (String) -> Void) { deliver = packet }
    func stop() {}
}

/// Exercise production key/timer/recorder paths without starting inference or desktop UI.
private final class PostBufferTestApp: AppDelegate {
    var finalize: (() -> Void)?
    override func finalizeRecording(keyReleaseTime: Double) { finalize?() }
    override func resetRecordingUIAfterAbort() {}
}

@MainActor
final class PostBufferContinuationTests: XCTestCase {
    private func withRecording(_ body: (PostBufferTestApp, PostBufferCapture, URL) throws -> Void) throws {
        let device = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in", isBuiltIn: true,
                                     isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
        let capture = PostBufferCapture()
        let recorder = AudioRecorder(factory: { capture })
        recorder.capture.configure(devices: [device], systemDefault: device, pin: nil, prelisten: true)
        recorder.capture.start()
        recorder.capture.queue.sync {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configDirectory = directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let previousConfigDirectory = Config.configDirOverride
        Config.configDirOverride = configDirectory
        let url = directory.appendingPathComponent("same-take.wav")
        defer {
            recorder.shutdown()
            recorder.capture.queue.sync {}
            Config.configDirOverride = previousConfigDirectory
            try? FileManager.default.removeItem(at: directory)
        }
        try recorder.startRecording(to: url)
        RecordingStore.writeSentinel(recordingURL: url)
        let app = PostBufferTestApp()
        app.recorder = recorder
        app.config = Config.defaultConfig
        app.config.streamingEnabled = FlexBool(false)
        app.isPressed = true
        try body(app, capture, url)
    }

    private func assertWAV(_ url: URL, contains samples: [Float], file: StaticString = #filePath,
                           line: UInt = #line) throws {
        let decoded = try ProcessCommand.loadSamples(from: url)
        XCTAssertEqual(decoded.count, samples.count, file: file, line: line)
        // WAV archives are s16: retain every sample in order within its quantization step.
        let largestError = zip(decoded, samples).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(largestError, 1.0 / 32768.0, file: file, line: line)
    }

    func testRepressContinuesSameTakeAndOnlyNextReleaseCanFinalize() throws {
        try withRecording { app, capture, url in
            let recorder = app.recorder!
            let first = Array(repeating: Float(0.25), count: 1600)
            capture.deliver?(CapturePacket(start: 0, samples: first))
            recorder.capture.queue.sync {}
            let obsoleteFinalization = expectation(description: "The old release must not finalize the held take")
            obsoleteFinalization.isInverted = true
            app.finalize = {
                obsoleteFinalization.fulfill()
                _ = recorder.stopRecording()
            }
            app.handleRecordingStop()
            // The production continuation returns before model setup, focus capture,
            // another sentinel/WAV, or another call to recorder.startRecording.
            app.handleRecordingStart()
            XCTAssertTrue(app.isPressed)
            // Below the silence threshold: an obsolete timer would finalize at 90 ms,
            // comfortably inside the inverted wait (speech would extend it to 1.2 s).
            let continued = Array(repeating: Float(0.005), count: 1600)
            capture.deliver?(CapturePacket(start: 0.1, samples: continued))
            wait(for: [obsoleteFinalization], timeout: 0.3)
            XCTAssertTrue(app.isPressed)
            XCTAssertEqual(recorder.currentSamples(), first + continued)
            XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStore.sentinelFile.path))

            let newFinalization = expectation(description: "The next release finalizes once")
            var result: (url: URL, samples: [Float])?
            var finalizations = 0
            app.finalize = {
                finalizations += 1
                result = recorder.stopRecording()
                newFinalization.fulfill()
            }
            app.handleRecordingStop()
            let silence = Array(repeating: Float(0), count: 1440)
            capture.deliver?(CapturePacket(start: 0.2, samples: silence))
            wait(for: [newFinalization], timeout: 1)
            XCTAssertEqual(finalizations, 1)
            XCTAssertEqual(result?.url, url)
            XCTAssertEqual(result?.samples, first + continued + silence)
            try assertWAV(url, contains: first + continued + silence)
            let wavs = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                   includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }
            XCTAssertEqual(wavs.map(\.lastPathComponent), [url.lastPathComponent])
        }
    }

    func testShortcutAbortOfContinuationPreservesReleasedTakeAndFinalizesNormally() throws {
        try withRecording { app, capture, url in
            let recorder = app.recorder!
            let first = Array(repeating: Float(0.25), count: 1600)
            capture.deliver?(CapturePacket(start: 0, samples: first))
            recorder.capture.queue.sync {}
            app.handleRecordingStop()
            app.handleRecordingStart()
            let finalized = expectation(description: "Canceling only the continuation still finalizes the take")
            var result: (url: URL, samples: [Float])?
            app.finalize = {
                result = recorder.stopRecording()
                finalized.fulfill()
            }
            app.handleRecordingAbort()
            XCTAssertFalse(app.isPressed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStore.sentinelFile.path))
            let silence = Array(repeating: Float(0), count: 1440)
            capture.deliver?(CapturePacket(start: 0.1, samples: silence))
            wait(for: [finalized], timeout: 1)
            XCTAssertEqual(result?.url, url)
            XCTAssertEqual(result?.samples, first + silence)
            try assertWAV(url, contains: first + silence)
        }
    }

    func testShortcutAbortOfFirstPressStillDiscardsTheCanceledTake() throws {
        try withRecording { app, capture, url in
            let recorder = app.recorder!
            capture.deliver?(CapturePacket(start: 0, samples: Array(repeating: 0.25, count: 1600)))
            recorder.capture.queue.sync {}
            let finalized = expectation(description: "A canceled first press must not finalize")
            finalized.isInverted = true
            app.finalize = { finalized.fulfill() }
            app.handleRecordingAbort()
            XCTAssertFalse(app.isPressed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingStore.sentinelFile.path))
            XCTAssertNil(recorder.stopRecording())
            wait(for: [finalized], timeout: 0.3)
        }
    }
}
