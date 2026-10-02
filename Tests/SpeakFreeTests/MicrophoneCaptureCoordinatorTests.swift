// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
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

    func testPinnedAirPodsPrelistenUsesBuiltInAndAirPodsStartOnlyForDictation() {
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: airPods.uid, prelisten: true)
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
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: airPods.uid, prelisten: true)
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

    func testFailedRecordingActuallyRestartsEvenWhenPacketsAreRecent() {
        var sessions: [ScriptedCapture] = []
        var received: [Float] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { received += $0; _ = $1 }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn], systemDefault: builtIn, pin: nil, prelisten: true)
        router.start(); router.queue.sync {}
        sessions[0].deliver?(CapturePacket(start: 0, samples: [0]))
        router.queue.sync {}
        router.recoverFailedCapture(); router.queue.sync {}
        XCTAssertTrue(sessions[0].stopped)
        XCTAssertEqual(sessions.count, 2)
        sessions[0].deliver?(CapturePacket(start: 1, samples: [999]))
        sessions[1].deliver?(CapturePacket(start: 1, samples: [0.25]))
        router.queue.sync {}
        XCTAssertEqual(received, [0, 0.25])
        router.stop(); router.queue.sync {}
    }

    func testZeroFilledAirPodsCannotReplaceWorkingBaseAndAreRetired() {
        var sessions: [ScriptedCapture] = []
        var received: [Float] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { received += $0; _ = $1 }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: airPods.uid, prelisten: true)
        router.start(); router.queue.sync { router.setRecording(true) }
        for i in 0..<10 {
            sessions[0].deliver?(CapturePacket(start: Double(i) / 10, samples: Array(repeating: 0.25, count: 1600)))
            sessions[1].deliver?(CapturePacket(start: Double(i) / 10, samples: Array(repeating: 0, count: 1600)))
            router.queue.sync {}
        }
        XCTAssertEqual(received, Array(repeating: 0.25, count: 16000))
        XCTAssertFalse(sessions[0].stopped)
        XCTAssertTrue(sessions[1].stopped)
        router.stop(); router.queue.sync {}
    }

    func testQuietNonzeroMicrophoneDoesNotTriggerDigitalSilenceRecovery() {
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn], systemDefault: builtIn, pin: nil, prelisten: true)
        router.start(); router.queue.sync {}
        sessions[0].deliver?(CapturePacket(start: 0, samples: Array(repeating: 0.0000001, count: 32000)))
        router.queue.sync {}
        XCTAssertFalse(sessions[0].stopped)
        XCTAssertEqual(sessions.count, 1)
        router.stop(); router.queue.sync {}
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
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: airPods.uid, prelisten: true)
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

    func testStopDrainsPacketsAlreadyQueuedAtTheRecordingBoundary() throws {
        let session = ScriptedCapture()
        let recorder = AudioRecorder(factory: { session })
        recorder.capture.configure(devices: [builtIn], systemDefault: builtIn, pin: nil, prelisten: true)
        recorder.capture.start()
        recorder.capture.queue.sync {}
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url); recorder.shutdown(); recorder.capture.queue.sync {} }
        try recorder.startRecording(to: url)
        let samples = Array(repeating: Float(0.25), count: 1600)
        session.deliver?(CapturePacket(start: 0, samples: samples))
        // No explicit routing/write drain here: stopRecording must serialize both queues itself.
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples, samples)
        XCTAssertEqual(try ProcessCommand.loadSamples(from: url).count, samples.count)
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

    // MARK: - Default flip (2026-09-24): Bluetooth is never chosen automatically

    private let jack = AudioInputDevice(id: 4, uid: "BuiltInHeadphoneInputDevice", name: "External Microphone", isBuiltIn: true, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
    private let usb = AudioInputDevice(id: 5, uid: "usb-mic", name: "Shure MV7+", isBuiltIn: false, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)

    func testUnpinnedDefaultIgnoresConnectedAirPodsEvenWhenTheyAreTheSystemDefault() {
        let routes = MicrophoneCaptureCoordinator.routes(devices: [airPods, builtIn], systemDefault: airPods, pin: nil)
        XCTAssertEqual(routes.base, builtIn)
        XCTAssertEqual(routes.preferred, builtIn)
    }

    func testUnpinnedDefaultNeverOpensAirPodsEvenWhileRecording() {
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {})
        router.configure(devices: [builtIn, airPods], systemDefault: airPods, pin: nil, prelisten: true)
        router.start(); router.queue.sync { router.setRecording(true) }
        XCTAssertEqual(sessions.map { $0.device?.uid }, [builtIn.uid])
        router.stop(); router.queue.sync {}
    }

    func testExplicitBluetoothPinIsPreserved() {
        let routes = MicrophoneCaptureCoordinator.routes(devices: [builtIn, airPods], systemDefault: builtIn, pin: airPods.uid)
        XCTAssertEqual(routes.base, builtIn)
        XCTAssertEqual(routes.preferred, airPods)
    }

    func testExplicitWiredPinIsPreserved() {
        let routes = MicrophoneCaptureCoordinator.routes(devices: [builtIn, usb, airPods], systemDefault: airPods, pin: usb.uid)
        XCTAssertEqual(routes.preferred, usb)
    }

    func testDesktopWithoutBuiltInMicUsesWiredMicNotHeadset() {
        let routes = MicrophoneCaptureCoordinator.routes(devices: [airPods, usb], systemDefault: airPods, pin: nil)
        XCTAssertEqual(routes.base, usb)
        XCTAssertEqual(routes.preferred, usb)
    }

    func testHeadphoneJackDoesNotBeatTheInternalMicByListOrder() {
        let routes = MicrophoneCaptureCoordinator.routes(devices: [jack, builtIn], systemDefault: jack, pin: nil)
        XCTAssertEqual(routes.base, builtIn)
        XCTAssertEqual(routes.preferred, builtIn)
    }

    func testHeadsetOnlyMacOpensTheHeadsetPerDictationNotForPrelistening() {
        var time = 0.0
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {}, now: { time })
        router.configure(devices: [airPods], systemDefault: airPods, pin: nil, prelisten: true)
        router.start(); router.queue.sync {}
        XCTAssertTrue(sessions.isEmpty, "a headset-only Mac must not hold the headset open for pre-listening")
        router.queue.sync { router.setRecording(true) }
        XCTAssertEqual(sessions.map { $0.device?.uid }, [airPods.uid])
        router.queue.sync { router.setRecording(false); time = 31 }
        sessions[0].deliver?(CapturePacket(start: 31, samples: [1]))
        router.recover(); router.queue.sync {}
        XCTAssertTrue(sessions[0].stopped, "the headset rests after the idle window")
        router.stop(); router.queue.sync {}
    }

    // MARK: - Stay on routing

    func testStayOnRoutesTheChosenHeadsetOverPinAndDefault() {
        let jabra = AudioInputDevice(id: 6, uid: "jabra", name: "Jabra", isBuiltIn: false, isBluetooth: true, nominalSampleRate: 16_000, inputChannels: 1)
        XCTAssertEqual(MicrophoneCaptureCoordinator.routes(devices: [builtIn, airPods, jabra], systemDefault: airPods, pin: nil, stayOn: jabra.uid).preferred, jabra)
        XCTAssertEqual(MicrophoneCaptureCoordinator.routes(devices: [builtIn, usb, airPods], systemDefault: airPods, pin: usb.uid, stayOn: airPods.uid).preferred, airPods)
        // Headset gone: the pin or the Mac mic takes over, and base never becomes the headset.
        let gone = MicrophoneCaptureCoordinator.routes(devices: [builtIn], systemDefault: builtIn, pin: nil, stayOn: airPods.uid)
        XCTAssertEqual(gone.preferred, builtIn)
        XCTAssertEqual(MicrophoneCaptureCoordinator.routes(devices: [builtIn, airPods], systemDefault: airPods, pin: nil, stayOn: airPods.uid).base, builtIn)
    }

    func testStayOnHoldsTheHeadsetOpenBetweenTakesAndMacMicKeepsListening() {
        var time = 0.0
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {}, now: { time })
        router.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: airPods.uid)
        router.start(); router.queue.sync {}
        XCTAssertEqual(Set(sessions.map { $0.device?.uid }), [builtIn.uid, airPods.uid], "held open before the first take")
        router.queue.sync { router.setRecording(true); router.setRecording(false); time = 600 }
        sessions[0].deliver?(CapturePacket(start: 600, samples: [1]))
        sessions[1].deliver?(CapturePacket(start: 600, samples: [1]))
        router.recover(); router.queue.sync {}
        XCTAssertFalse(sessions[1].stopped, "no 30 second rest while Stay on is on")
        XCTAssertFalse(sessions[0].stopped)
        router.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: nil)
        router.queue.sync {}
        XCTAssertTrue(sessions[1].stopped, "ending Stay on releases the headset")
        router.stop(); router.queue.sync {}
    }

    func testStayOnOnAHeadsetOnlyMacHoldsIt() {
        var sessions: [ScriptedCapture] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {})
        router.configure(devices: [airPods], systemDefault: airPods, pin: nil, prelisten: true, stayOn: airPods.uid)
        router.start(); router.queue.sync {}
        XCTAssertEqual(sessions.map { $0.device?.uid }, [airPods.uid])
        router.stop(); router.queue.sync {}
    }

    func testHeadsetHealthIsReportedForTheStayOnHeadset() {
        var time = 0.0
        var sessions: [ScriptedCapture] = []
        var health: [(String, Bool)] = []
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {}, now: { time })
        router.onHeadsetHealth = { health.append(($0, $1)) }
        router.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: airPods.uid)
        router.start(); router.queue.sync {}
        sessions[1].deliver?(CapturePacket(start: 0, samples: [0.1]))
        router.queue.sync { time = 6 }
        sessions[1].deliver?(CapturePacket(start: 6, samples: [0.1]))
        sessions[1].deliver?(CapturePacket(start: 6.1, samples: [0.1]))
        router.queue.sync {}
        XCTAssertEqual(health.map { $0.1 }, [true], "reported once per stream")
        // Now the headset fails four times in a row.
        for _ in 0..<4 {
            let current = sessions.last!
            current.fail?("route lost")
            router.queue.sync { time += 5 }
            // Same routing again: runs reconcile (as the 1 Hz health timer does) without resetting retries.
            router.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: airPods.uid)
            router.queue.sync {}
        }
        XCTAssertEqual(health.last?.0, airPods.uid)
        XCTAssertEqual(health.last?.1, false)
        router.stop(); router.queue.sync {}
    }

    func testNoHealthReportsWithoutStayOn() {
        var sessions: [ScriptedCapture] = []
        var health = 0
        let router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); sessions.append(s); return s }, samples: { _, _ in }, status: { _ in }, refresh: {})
        router.onHeadsetHealth = { _, _ in health += 1 }
        router.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: airPods.uid, prelisten: true)
        router.start(); router.queue.sync { router.setRecording(true) }
        for _ in 0..<4 { sessions.last?.fail?("x"); router.queue.sync {} }
        XCTAssertEqual(health, 0)
        router.stop(); router.queue.sync {}
    }
}
