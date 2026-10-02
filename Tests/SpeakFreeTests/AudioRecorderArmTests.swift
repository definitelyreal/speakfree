// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22
//
// Key press arms the recorder so audio captured while record start is blocked on the disk
// (logged up to 2.4 s) is kept instead of scrolling out of the 500 ms pre-roll.

import XCTest
@testable import SpeakFreeLib

private final class ArmCapture: DeviceCapturing {
    var deliver: ((CapturePacket) -> Void)?
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
               failure: @escaping (String) -> Void) { deliver = packet }
    func stop() {}
}

final class AudioRecorderArmTests: XCTestCase {
    private var directory: URL!
    private var previousConfigDirectory: URL?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        previousConfigDirectory = Config.configDirOverride
        Config.configDirOverride = directory
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = previousConfigDirectory
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecorder() -> (AudioRecorder, ArmCapture) {
        let device = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in", isBuiltIn: true,
                                     isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
        let capture = ArmCapture()
        let recorder = AudioRecorder(factory: { capture })
        recorder.capture.configure(devices: [device], systemDefault: device, pin: nil, prelisten: true)
        recorder.capture.start()
        recorder.capture.queue.sync {}
        return (recorder, capture)
    }

    /// Distinct values so a test can tell which samples survived.
    private func ramp(_ count: Int, from start: Int) -> [Float] {
        (0..<count).map { Float((start + $0) % 30_000) / 60_000 }
    }

    /// Packets carry increasing capture times; the coordinator drops overlapping ones.
    private var clock: Double = 0

    private func deliver(_ capture: ArmCapture, _ recorder: AudioRecorder, _ samples: [Float]) {
        capture.deliver?(CapturePacket(start: clock, samples: samples))
        clock += Double(samples.count) / 16_000
        recorder.capture.queue.sync {}
    }

    func testUnarmedStartKeepsOnlyTheLast500ms() throws {
        let (recorder, capture) = makeRecorder()
        defer { recorder.shutdown(); recorder.capture.queue.sync {} }
        let before = ramp(32_000, from: 0)
        deliver(capture, recorder, before)
        let url = directory.appendingPathComponent("a.wav")
        try recorder.startRecording(to: url)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples, Array(before.suffix(AudioRecorder.prerollSamples)))
    }

    func testArmedStartKeepsEverythingSinceKeyPress() throws {
        let (recorder, capture) = makeRecorder()
        defer { recorder.shutdown(); recorder.capture.queue.sync {} }
        let beforePress = ramp(16_000, from: 0)
        deliver(capture, recorder, beforePress)
        recorder.armTake()
        // 2 s of speech while the main thread is stuck creating the file.
        let whileBlocked = ramp(32_000, from: 16_000)
        deliver(capture, recorder, whileBlocked)
        let url = directory.appendingPathComponent("b.wav")
        try recorder.startRecording(to: url)
        let during = ramp(1_600, from: 48_000)
        deliver(capture, recorder, during)
        let result = try XCTUnwrap(recorder.stopRecording())
        let expected = Array(beforePress.suffix(AudioRecorder.prerollSamples)) + whileBlocked + during
        XCTAssertEqual(result.samples.count, expected.count)
        let firstDiff = zip(result.samples, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertNil(firstDiff, "first difference at sample \(firstDiff ?? -1)")
        let wav = try ProcessCommand.loadSamples(from: url)
        XCTAssertEqual(wav.count, expected.count)
    }

    func testFailedStartDisarmsSoPrerollTrimsAgain() throws {
        let (recorder, capture) = makeRecorder()
        defer { recorder.shutdown(); recorder.capture.queue.sync {} }
        recorder.armTake()
        deliver(capture, recorder, ramp(24_000, from: 0))
        let unwritable = directory.appendingPathComponent("missing-dir/c.wav")
        XCTAssertThrowsError(try recorder.startRecording(to: unwritable))
        // Disarmed: the next buffer trims back to 500 ms, so a later take starts normally.
        deliver(capture, recorder, ramp(1_000, from: 24_000))
        let url = directory.appendingPathComponent("c.wav")
        try recorder.startRecording(to: url)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples.count, AudioRecorder.prerollSamples)
    }

    /// The app's own catch path (lease or path failure before startRecording) disarms.
    func testDisarmWithoutStartTrimsAgain() throws {
        let (recorder, capture) = makeRecorder()
        defer { recorder.shutdown(); recorder.capture.queue.sync {} }
        recorder.armTake()
        recorder.disarmTake()
        deliver(capture, recorder, ramp(24_000, from: 0))
        let url = directory.appendingPathComponent("g.wav")
        try recorder.startRecording(to: url)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples.count, AudioRecorder.prerollSamples)
    }

    func testArmedPrerollIsBounded() throws {
        let (recorder, capture) = makeRecorder()
        defer { recorder.shutdown(); recorder.capture.queue.sync {} }
        recorder.armTake()
        deliver(capture, recorder, [Float](repeating: 0.1, count: AudioRecorder.armedPrerollCapSamples + 5_000))
        let url = directory.appendingPathComponent("d.wav")
        try recorder.startRecording(to: url)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples.count, AudioRecorder.armedPrerollCapSamples)
    }

    func testArmingDuringATakeDoesNothing() throws {
        let (recorder, capture) = makeRecorder()
        defer { recorder.shutdown(); recorder.capture.queue.sync {} }
        let url = directory.appendingPathComponent("e.wav")
        try recorder.startRecording(to: url)
        recorder.armTake()
        deliver(capture, recorder, ramp(1_600, from: 0))
        _ = recorder.stopRecording()
        // After the take, pre-roll is the normal 500 ms window again.
        deliver(capture, recorder, ramp(20_000, from: 0))
        let next = directory.appendingPathComponent("f.wav")
        try recorder.startRecording(to: next)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples.count, AudioRecorder.prerollSamples)
    }
}
