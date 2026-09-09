// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
import AVFoundation
import XCTest
@testable import SpeakFreeLib

final class AudioConfigurationNotificationTests: XCTestCase {
    func testDeviceWorkerReceivesStoppedEngineChangeWithoutBlockingAudioQueue() {
        let center = NotificationCenter()
        let engine = AVAudioEngine() // No inputNode or hardware capture.
        let worker = DispatchQueue(label: "test.capture.configuration")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        worker.async { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let delivered = expectation(description: "stopped engine delivered after worker unblocks")
        let observer = DeviceAudioSession.observeStoppedEngine(engine, center: center, on: worker) {
            dispatchPrecondition(condition: .onQueue(worker))
            delivered.fulfill()
        }
        defer { center.removeObserver(observer) }
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(name: .AVAudioEngineConfigurationChange, object: engine)
            posted.signal()
        }
        let result = posted.wait(timeout: .now() + 1)
        release.signal()
        XCTAssertEqual(result, .success, "audio notification must not wait for the worker")
        wait(for: [delivered], timeout: 2)
    }

    func testDeviceWorkerIgnoresOtherEnginesAndRemovedObserver() {
        let center = NotificationCenter()
        let engine = AVAudioEngine(), otherEngine = AVAudioEngine()
        let worker = DispatchQueue(label: "test.capture.configuration.filter")
        var calls = 0
        let observer = DeviceAudioSession.observeStoppedEngine(engine, center: center, on: worker) { calls += 1 }
        center.post(name: .AVAudioEngineConfigurationChange, object: otherEngine)
        worker.sync {}
        XCTAssertEqual(calls, 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        worker.sync {}
        XCTAssertEqual(calls, 1)
        center.removeObserver(observer)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        worker.sync {}
        XCTAssertEqual(calls, 1)
    }

    func testAudioThreadCanFinishNotificationWhileMainIsBusy() {
        XCTAssertTrue(Thread.isMainThread)
        let center = NotificationCenter()
        let delivered = expectation(description: "main eventually handles change")
        // No inputNode access or engine start: no microphone use in this regression.
        let engine = AVAudioEngine()
        let identity = ObjectIdentifier(engine)
        let observer = AudioRecorder.observeEngineConfigurationChanges(center: center) { changed in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(changed, identity)
            delivered.fulfill()
        }
        defer { center.removeObserver(observer) }
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(name: .AVAudioEngineConfigurationChange, object: engine)
            posted.signal()
        }
        // Deliberately occupy main, like AVAudioEngine start/dealloc waiting on its
        // internal queue. The old queue:.main observer makes this wait time out.
        XCTAssertEqual(posted.wait(timeout: .now() + 1), .success)
        wait(for: [delivered], timeout: 2)
    }

    func testMainThreadNotificationAlsoDefersRebuildUntilPostingReturns() {
        let center = NotificationCenter()
        let delivered = expectation(description: "deferred delivery")
        var isPosting = true
        let observer = AudioRecorder.observeEngineConfigurationChanges(center: center) { _ in
            XCTAssertFalse(isPosting, "never rebuild from inside an engine notification")
            delivered.fulfill()
        }
        defer { center.removeObserver(observer) }
        let engine = AVAudioEngine()
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        isPosting = false
        wait(for: [delivered], timeout: 2)
    }
}
