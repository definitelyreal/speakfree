// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import XCTest
@testable import SpeakFreeLib

private final class ScriptedCapture: DeviceCapturing {
    var device: AudioInputDevice?
    var deliver: ((CapturePacket) -> Void)?
    var fail: ((String) -> Void)?
    var stopped = false
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void, failure: @escaping (String) -> Void) {
        self.device = device; deliver = packet; fail = failure
    }
    func stop() { stopped = true }
}

final class MicrophoneCaptureCoordinatorTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in", isBuiltIn: true, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
    private let airPods = AudioInputDevice(id: 2, uid: "airpods", name: "AirPods", isBuiltIn: false, isBluetooth: true, nominalSampleRate: 24_000, inputChannels: 1)

    func testPrelistenUsesBuiltInAndAirPodsStartOnlyForDictation() {
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: nil, prelisten: true)
        router.start(); router.queue.sync {}
        XCTAssertEqual(sessions.map { $0.device?.uid }, [builtIn.uid])
        router.queue.sync { router.setRecording(true) }
        XCTAssertEqual(sessions.map { $0.device?.uid }, [builtIn.uid, airPods.uid])
        router.stop(); router.queue.sync {}
    }

    func testDelayedStartCannotBlockFallbackAndRetiredCallbacksAreDropped() {
        var sessions: [ScriptedCapture] = []
        var received: [Float] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { received += $0; _ = $1 }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: nil, prelisten: true)
        router.start(); router.queue.sync { router.setRecording(true) }
        // AirPods never finish starting. Built-in capture and control still progress.
        sessions[0].deliver?(CapturePacket(start: 0, samples: [1, 2, 3]))
        router.queue.sync {}
        XCTAssertEqual(received, [1, 2, 3])
        router.configure(devices: [builtIn], systemDefault: builtIn, pin: nil, prelisten: true)
        router.queue.sync {}
        XCTAssertTrue(sessions[1].stopped)
        sessions[1].deliver?(CapturePacket(start: 1, samples: [999]))
        router.queue.sync {}
        XCTAssertEqual(received, [1, 2, 3])
        router.stop(); router.queue.sync {}
    }

    func testExplicitBuiltInPinWinsOverConnectedAirPods() {
        let routes = MicrophoneCaptureCoordinator.routes(devices: [airPods, builtIn], systemDefault: airPods, pin: builtIn.uid)
        XCTAssertEqual(routes.base, builtIn)
        XCTAssertEqual(routes.preferred, builtIn)
    }

    func testAirPodsOnlyMacKeepsPrelistenOnItsAvailableMicrophone() {
        let routes = MicrophoneCaptureCoordinator.routes(devices: [airPods], systemDefault: airPods, pin: nil)
        XCTAssertEqual(routes.base, airPods)
        XCTAssertEqual(routes.preferred, airPods)
    }

    func testIdleTimeoutReleasesOnlyAirPodsAndKeepsPrelistenAlive() {
        var time = 0.0
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {}, now: { time })
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: nil, prelisten: true)
        router.start(); router.queue.sync { router.setRecording(true); router.setRecording(false) }
        XCTAssertFalse(sessions[1].stopped)
        router.queue.sync { time = 31 }
        // Keep the base healthy at the simulated timeout.
        sessions[0].deliver?(CapturePacket(start: 31, samples: [1]))
        router.recover(); router.queue.sync {}
        XCTAssertFalse(sessions[0].stopped)
        XCTAssertTrue(sessions[1].stopped)
        router.stop(); router.queue.sync {}
    }

    func testRecorderPreservesHalfSecondPrerollAndRepeatedStartDoesNotTruncate() throws {
        var sessions: [ScriptedCapture] = []
        let recorder = AudioRecorder(factory: { let s = ScriptedCapture(); sessions.append(s); return s })
        recorder.capture.configure(devices: [builtIn], systemDefault: builtIn, pin: nil, prelisten: true)
        recorder.capture.start(); recorder.capture.queue.sync {}
        let samples = [Float](repeating: 0.25, count: 12_000)
        sessions[0].deliver?(CapturePacket(start: 0, samples: samples))
        recorder.capture.queue.sync {}
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url); recorder.shutdown(); recorder.capture.queue.sync {} }
        try recorder.startRecording(to: url)
        try recorder.startRecording(to: url)
        sessions[0].deliver?(CapturePacket(start: 0.75, samples: [Float](repeating: 0.5, count: 1600)))
        recorder.capture.queue.sync {}
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples, [Float](repeating: 0.25, count: 8000) + [Float](repeating: 0.5, count: 1600))
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 9600 * 2)
    }

    func testVirtualDriverIsNotChosenAsAutomaticBackupOverAvailableAirPods() {
        let virtual = AudioInputDevice(id: 3, uid: "zoom", name: "Zoom", isBuiltIn: false, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 2, isVirtual: true)
        let routes = MicrophoneCaptureCoordinator.routes(devices: [virtual, airPods], systemDefault: airPods, pin: nil)
        XCTAssertEqual(routes.base, airPods)
        XCTAssertEqual(MicrophoneCaptureCoordinator.routes(devices: [virtual, airPods], systemDefault: airPods, pin: virtual.uid).preferred, virtual)
    }

    func testPinnedAirPodsRejoinWithoutChangingTheSavedPreferenceOrStoppingBase() {
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: airPods.uid, prelisten: true)
        router.start(); router.queue.sync { router.setRecording(true) }
        router.configure(devices: [builtIn], systemDefault: builtIn, pin: airPods.uid, prelisten: true)
        router.queue.sync {}
        XCTAssertTrue(sessions[1].stopped)
        XCTAssertFalse(sessions[0].stopped)
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: airPods.uid, prelisten: true)
        router.queue.sync {}
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[2].device?.uid, airPods.uid)
        XCTAssertFalse(sessions[0].stopped)
        router.stop(); router.queue.sync {}
    }
}
