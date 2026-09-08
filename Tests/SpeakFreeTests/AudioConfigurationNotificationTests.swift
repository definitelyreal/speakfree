// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import AVFoundation
import XCTest
@testable import SpeakFreeLib

final class AudioConfigurationNotificationTests: XCTestCase {
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
