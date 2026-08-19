// ai-suggestion:unverified · session:9bb7d552-ac60-4aeb-b987-841018c752be · 2026-08-12
import CoreAudio
import XCTest
@testable import SpeakFreeLib

/// Capture resilience against device churn, sleep/wake, and AirPods handoffs
/// (2026-08-12). Every rule below is a pure function precisely so the "what should
/// happen when the AirPods leave mid-take" decisions can be pinned without hardware.
final class AudioResilienceTests: XCTestCase {

    private func device(
        _ uid: String, id: AudioDeviceID, name: String? = nil,
        builtIn: Bool = false, bluetooth: Bool = false,
        rate: Double = 48000, channels: Int = 1
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: id, uid: uid, name: name ?? uid, isBuiltIn: builtIn, isBluetooth: bluetooth,
            nominalSampleRate: rate, inputChannels: channels)
    }

    // MARK: - Cold-start heal (adversarial VERIFY 2026-08-12, blocker 2)
    //
    // The first engine build can beat the catalog's async first scan: the engine binds
    // nothing and follows the system default (AirPods) while the metadata claims the
    // built-in mic. When the first scan lands, the device-list delta must repair the
    // orphan — a live engine with no binding whose pin target is now enumerable.

    func testColdStartOrphanIsHealedWhenPinTargetAppears() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: nil, boundID: nil,
            effectivePinTarget: "built-in", engineExists: true,
            devices: [device("built-in", id: 41, builtIn: true)])
        XCTAssertNotNil(reason, "an unbound live engine with an enumerable pin target is an orphan")
    }

    func testNoEngineMeansNoHeal() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: nil, boundID: nil,
            effectivePinTarget: "built-in", engineExists: false,
            devices: [device("built-in", id: 41, builtIn: true)])
        XCTAssertNil(reason, "pre-buffer-off idle has no engine — the heal must not spawn one")
    }

    func testHealWaitsForThePinTargetToBeEnumerable() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: nil, boundID: nil,
            effectivePinTarget: "built-in", engineExists: true,
            devices: [device("airpods", id: 77, bluetooth: true)])
        XCTAssertNil(reason, "rebuilding before the target exists would orphan again")
    }

    func testTrueSystemDefaultFollowerIsStillLeftAlone() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: nil, boundID: nil,
            effectivePinTarget: nil, engineExists: true,
            devices: [device("usb-mic", id: 12)])
        XCTAssertNil(reason, "a Mac with no built-in input legitimately follows the system default")
    }

    func testExhaustedBindRetriesStopReactingToDeviceEvents() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: "built-in", boundID: nil,
            bindRetryExhausted: true,
            devices: [device("built-in", id: 41, builtIn: true)])
        XCTAssertNil(reason, "a bind that keeps failing while the device is present must "
                     + "stop storming a rebuild per device event once the cap is hit")
    }

    func testUnexhaustedBindStillRetriesWhenDevicePresent() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: "built-in", boundID: nil,
            bindRetryExhausted: false,
            devices: [device("built-in", id: 41, builtIn: true)])
        XCTAssertNotNil(reason, "under the cap, a present device with no live bind retries")
    }

    // MARK: - Device-list delta (the authoritative churn signal)

    func testIdenticalDeviceListIsNotAChange() {
        let list = [device("built-in", id: 41), device("airpods", id: 77)]
        XCTAssertFalse(AudioDeviceCatalog.deviceListChanged(from: list, to: list))
    }

    func testJoinAndLeaveAreChanges() {
        let before = [device("built-in", id: 41)]
        let after = [device("built-in", id: 41), device("airpods", id: 77)]
        XCTAssertTrue(AudioDeviceCatalog.deviceListChanged(from: before, to: after),
                      "AirPods joining is the event AVFoundation is unreliable about")
        XCTAssertTrue(AudioDeviceCatalog.deviceListChanged(from: after, to: before))
    }

    func testRenumberingTheSameUIDIsAChange() {
        // The ghost-pepper case: the UID resolves fine, the engine is bound to the OLD
        // numeric ID, and nothing looks wrong until no audio arrives.
        let before = [device("built-in", id: 41)]
        let after = [device("built-in", id: 92)]
        XCTAssertTrue(AudioDeviceCatalog.deviceListChanged(from: before, to: after),
                      "a UID that came back on a new AudioDeviceID is a dead binding")
    }

    func testDeviceOrderIsNotAChange() {
        let before = [device("built-in", id: 41), device("airpods", id: 77)]
        let after = [device("airpods", id: 77), device("built-in", id: 41)]
        XCTAssertFalse(AudioDeviceCatalog.deviceListChanged(from: before, to: after),
                       "enumeration order churn must not trigger engine rebuilds")
    }

    // MARK: - Does a device-list change invalidate OUR binding?

    func testSystemDefaultEngineIgnoresDeviceListChanges() {
        // Reacting here as well as in the default-input listener re-creates the
        // 2026-07-20 self-induced rebuild loop.
        XCTAssertNil(AudioRecorder.deviceListRebuildReason(
            boundUID: nil, boundID: nil, devices: [device("airpods", id: 77)]))
    }

    func testUnchangedBindingNeedsNoRebuild() {
        XCTAssertNil(AudioRecorder.deviceListRebuildReason(
            boundUID: "built-in", boundID: 41,
            devices: [device("built-in", id: 41), device("airpods", id: 77)]))
    }

    func testDepartedBoundDeviceRebuilds() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: "usb-mic", boundID: 55, devices: [device("built-in", id: 41)])
        XCTAssertNotNil(reason, "capturing from a device that no longer exists is dead air")
        XCTAssertTrue(reason?.contains("departed") ?? false)
    }

    func testRenumberedBoundDeviceRebuilds() {
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: "built-in", boundID: 41, devices: [device("built-in", id: 92)])
        XCTAssertNotNil(reason, "same mic, new AudioDeviceID — the engine is talking to nothing")
        XCTAssertTrue(reason?.contains("renumbered") ?? false)
    }

    func testPinnedDeviceReturningRebuilds() {
        // Pin was absent at build time (engine fell back to the system default). Without
        // this branch, reconnecting the microphone the user chose never takes effect.
        let reason = AudioRecorder.deviceListRebuildReason(
            boundUID: "usb-mic", boundID: nil,
            devices: [device("built-in", id: 41), device("usb-mic", id: 55, name: "Studio Mic")])
        XCTAssertEqual(reason, "pinned device Studio Mic is present again")
    }

    func testStillAbsentPinDoesNotRebuild() {
        XCTAssertNil(AudioRecorder.deviceListRebuildReason(
            boundUID: "usb-mic", boundID: nil, devices: [device("built-in", id: 41)]),
            "a pin that is still absent must not rebuild on every unrelated list change")
    }

    // MARK: - Per-device alerts on the bound capture device

    private let settled = AudioRecorder.selfInducedConfigWindowSeconds + 1

    func testDepartedDeviceRebuildsEvenWhileClaimingToBeAlive() {
        // Documented caution: a departed device (AirPlay was the reported case) can keep
        // reporting alive with a valid ID. The device LIST is the authority.
        XCTAssertTrue(AudioRecorder.shouldRebuildForDeviceAlert(
            selector: kAudioDevicePropertyDeviceIsAlive, isAlive: true,
            presentInDeviceList: false, secondsSinceEngineBuilt: settled))
    }

    func testDepartureIsNeverTreatedAsSelfInduced() {
        // A departure inside the settle window is real — our own bind cannot remove a
        // device from the system's list.
        XCTAssertTrue(AudioRecorder.shouldRebuildForDeviceAlert(
            selector: kAudioDevicePropertyDeviceHasChanged, isAlive: nil,
            presentInDeviceList: false, secondsSinceEngineBuilt: 0.1))
    }

    func testAlertsInsideTheSettleWindowAreIgnored() {
        // Binding the unit moves the device's own rate/stream properties; treating that
        // as an external change is the 2026-07-20 self-induced rebuild loop.
        for selector in [kAudioDevicePropertyDeviceHasChanged,
                         kAudioDevicePropertyStreamConfiguration,
                         kAudioDevicePropertyNominalSampleRate] {
            XCTAssertFalse(AudioRecorder.shouldRebuildForDeviceAlert(
                selector: selector, isAlive: true, presentInDeviceList: true,
                secondsSinceEngineBuilt: 0.1),
                "\(AudioRecorder.selectorLabel(selector)) right after a bind is our own doing")
        }
    }

    func testHealthyAliveAlertDoesNotRebuild() {
        // IsAlive fires on both edges; rebuilding on the "alive" edge is a rebuild storm.
        XCTAssertFalse(AudioRecorder.shouldRebuildForDeviceAlert(
            selector: kAudioDevicePropertyDeviceIsAlive, isAlive: true,
            presentInDeviceList: true, secondsSinceEngineBuilt: settled))
    }

    func testDyingDeviceRebuilds() {
        XCTAssertTrue(AudioRecorder.shouldRebuildForDeviceAlert(
            selector: kAudioDevicePropertyDeviceIsAlive, isAlive: false,
            presentInDeviceList: true, secondsSinceEngineBuilt: settled))
    }

    func testFormatAlertsAfterSettleRebuild() {
        // A tap installed on the old format receives nothing — the dead-air shape.
        for selector in [kAudioDevicePropertyStreamConfiguration,
                         kAudioDevicePropertyNominalSampleRate,
                         kAudioDevicePropertyDeviceHasChanged] {
            XCTAssertTrue(AudioRecorder.shouldRebuildForDeviceAlert(
                selector: selector, isAlive: true, presentInDeviceList: true,
                secondsSinceEngineBuilt: settled),
                "\(AudioRecorder.selectorLabel(selector)) after settle means the format moved")
        }
    }

    func testUnreadableAliveStateOnAPresentDeviceDoesNotRebuild() {
        // Unreadable is not evidence of death, and the device is still in the list.
        XCTAssertFalse(AudioRecorder.shouldRebuildForDeviceAlert(
            selector: kAudioDevicePropertyDeviceIsAlive, isAlive: nil,
            presentInDeviceList: true, secondsSinceEngineBuilt: settled))
    }

    // MARK: - Sleep / wake

    func testWakeAlwaysDiscardsAnExistingEngine() {
        // Sleep is a blind window: IDs can be renumbered and the unit's stream
        // description can go stale with no surviving notification.
        XCTAssertEqual(
            AudioRecorder.resumeAction(preBufferEnabled: true, engineExists: true), .rebuild)
        XCTAssertEqual(
            AudioRecorder.resumeAction(preBufferEnabled: false, engineExists: true), .rebuild,
            "an engine left running with the pre-buffer off is still stale after sleep")
    }

    func testWakeStartsTheEngineWhenThePreBufferWantsOne() {
        XCTAssertEqual(
            AudioRecorder.resumeAction(preBufferEnabled: true, engineExists: false), .startEngine)
    }

    func testWakeDoesNothingWhenNoEngineIsWanted() {
        XCTAssertEqual(
            AudioRecorder.resumeAction(preBufferEnabled: false, engineExists: false), .none)
    }

    // MARK: - Stale-format guard

    func testZeroFormatIsNeverUsable() {
        // The AirPods SCO-negotiation race: installTap on this throws, and libggml's
        // terminate hook turns that into SIGABRT.
        XCTAssertFalse(AudioRecorder.isCaptureFormatUsable(
            engineRate: 0, engineChannels: 1, deviceRate: 48000, deviceChannels: 1))
        XCTAssertFalse(AudioRecorder.isCaptureFormatUsable(
            engineRate: 48000, engineChannels: 0, deviceRate: 48000, deviceChannels: 1))
    }

    func testMatchingFormatIsUsable() {
        XCTAssertTrue(AudioRecorder.isCaptureFormatUsable(
            engineRate: 48000, engineChannels: 1, deviceRate: 48000, deviceChannels: 1))
    }

    func testStaleUnitFormatIsRejected() {
        // The 2026-07-22 dead-air shape: unit still answering with the old device's
        // 24 kHz SCO description after being re-bound to the 48 kHz built-in mic.
        XCTAssertFalse(AudioRecorder.isCaptureFormatUsable(
            engineRate: 24000, engineChannels: 1, deviceRate: 48000, deviceChannels: 1))
    }

    func testBluetoothInputRateBelowNominalIsUsable() {
        // AirPods Pro mic runs at 24 kHz while the device's nominal rate (the A2DP
        // output side) reads 48 kHz. Rejecting that split as "stale" made every
        // pin-to-AirPods start fail (2026-08-19 airplane logs: "the microphone
        // couldn't be used", recovering only after the retry budget ran out).
        XCTAssertTrue(AudioRecorder.isCaptureFormatUsable(
            engineRate: 24000, engineChannels: 1, deviceRate: 48000, deviceChannels: 1,
            deviceIsBluetooth: true))
        // SCO narrowband/wideband variants are equally legitimate on BT.
        XCTAssertTrue(AudioRecorder.isCaptureFormatUsable(
            engineRate: 16000, engineChannels: 1, deviceRate: 48000, deviceChannels: 1,
            deviceIsBluetooth: true))
    }

    func testBluetoothZeroFormatIsStillRejected() {
        // The SCO-negotiation race (zero rate/channels) must stay fatal even on BT —
        // installTap on it throws and libggml's terminate hook turns that into SIGABRT.
        XCTAssertFalse(AudioRecorder.isCaptureFormatUsable(
            engineRate: 0, engineChannels: 1, deviceRate: 48000, deviceChannels: 1,
            deviceIsBluetooth: true))
        XCTAssertFalse(AudioRecorder.isCaptureFormatUsable(
            engineRate: 24000, engineChannels: 0, deviceRate: 48000, deviceChannels: 1,
            deviceIsBluetooth: true))
    }

    func testNonBluetoothStaleFormatIsStillRejected() {
        // The original 2026-07-22 dead-air trap: built-in mic re-bound but the unit
        // still answers with the previous AirPods 24 kHz description. The Bluetooth
        // exemption must not weaken this.
        XCTAssertFalse(AudioRecorder.isCaptureFormatUsable(
            engineRate: 24000, engineChannels: 1, deviceRate: 48000, deviceChannels: 1,
            deviceIsBluetooth: false))
    }

    func testEngineAskingForMoreChannelsThanTheDeviceHasIsRejected() {
        XCTAssertFalse(AudioRecorder.isCaptureFormatUsable(
            engineRate: 48000, engineChannels: 2, deviceRate: 48000, deviceChannels: 1))
        XCTAssertTrue(AudioRecorder.isCaptureFormatUsable(
            engineRate: 48000, engineChannels: 1, deviceRate: 48000, deviceChannels: 2),
            "capturing fewer channels than the device offers is normal")
    }

    func testUnreadableHardwareNeverVetoesCapture() {
        // An unreadable device must not be able to block recording entirely.
        XCTAssertTrue(AudioRecorder.isCaptureFormatUsable(
            engineRate: 44100, engineChannels: 1, deviceRate: nil, deviceChannels: nil))
        XCTAssertTrue(AudioRecorder.isCaptureFormatUsable(
            engineRate: 44100, engineChannels: 1, deviceRate: 0, deviceChannels: 0))
    }

    func testSubHertzRateDifferenceIsTolerated() {
        XCTAssertTrue(AudioRecorder.isCaptureFormatUsable(
            engineRate: 48000.4, engineChannels: 1, deviceRate: 48000, deviceChannels: 1))
    }

    func testUnusableFormatRetriesAreBounded() {
        // Retry so the recorder never sits engineless; bound it so the retry is not
        // itself the storm.
        XCTAssertTrue(AudioRecorder.shouldSkipUnusableFormat(retriesSoFar: 0))
        XCTAssertTrue(AudioRecorder.shouldSkipUnusableFormat(retriesSoFar: 2))
        XCTAssertFalse(AudioRecorder.shouldSkipUnusableFormat(retriesSoFar: 3),
                       "after the budget, a suspect engine beats no engine at all")
        XCTAssertFalse(AudioRecorder.shouldSkipUnusableFormat(retriesSoFar: 99))
    }

    // MARK: - Real CoreAudio plumbing (skips cleanly on a device-less runner)

    func testRefreshNowFillsTheCacheAndCallsBackOnMain() {
        let done = expectation(description: "refresh completed")
        AudioDeviceCatalog.refreshNow {
            XCTAssertTrue(Thread.isMainThread, "the rebuild that chains off this runs on main")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testCapturedDeviceFieldsArePopulatedFromRealHardware() {
        for dev in AudioDeviceCatalog.inputDevices() {
            XCTAssertGreaterThan(dev.inputChannels, 0, "\(dev.name) is listed as an input")
            XCTAssertGreaterThanOrEqual(dev.nominalSampleRate, 0)
        }
    }

    func testCaptureDeviceListenersInstallAndRemoveOnRealHardware() throws {
        AudioDeviceCatalog.refreshNow()
        let deadline = Date().addingTimeInterval(3)
        while AudioDeviceCatalog.cachedInputDevices.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let dev = AudioDeviceCatalog.cachedInputDevices.first else {
            throw XCTSkip("no input devices on this machine")
        }
        let queue = DispatchQueue(label: "test.capturedevicewatch")
        let tokens = AudioDeviceCatalog.addCaptureDeviceListeners(
            deviceID: dev.id, queue: queue) { _ in }
        XCTAssertEqual(tokens.count, AudioDeviceCatalog.captureDeviceWatchProperties.count,
                       "every watched property must actually register")
        AudioDeviceCatalog.removeCaptureDeviceListeners(tokens)
        XCTAssertNotNil(AudioDeviceCatalog.deviceIsAlive(dev.id),
                        "a device in the list answers IsAlive")
    }
}
