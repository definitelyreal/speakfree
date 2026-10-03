// ai-suggestion:unverified · session:unknown · 2026-10-02
import XCTest
@testable import SpeakFreeLib

final class CaptureDeviceBindingTests: XCTestCase {
    private let requested = AudioInputDevice(id: 42, uid: "requested-input", name: "Test input", isBuiltIn: false,
                                             isBluetooth: true, nominalSampleRate: 24_000, inputChannels: 1)

    func testReadbackIdentifiesRequestedAndObservedDevicesWithStageAndGeneration() {
        let observed = CaptureDeviceBinding.Snapshot(status: 0, byteCount: 4, deviceID: 42, uid: "requested-input", uidStatus: 0)
        let text = CaptureDeviceBinding.diagnostic(requested: requested, observed: observed, stage: "after-start", generation: "test-generation")
        XCTAssertTrue(text.contains("test-generation, after-start"))
        XCTAssertTrue(text.contains("requested id=42 uid=requested-input"))
        XCTAssertTrue(text.contains("current id=42 uid=requested-input"))
        XCTAssertTrue(text.contains("current-device ID matches"))
    }

    func testDifferentAggregateReadbackDoesNotClaimWrongPhysicalInput() {
        let observed = CaptureDeviceBinding.Snapshot(status: 0, byteCount: 4, deviceID: 99, uid: "CADefaultDeviceAggregate-test", uidStatus: 0)
        let text = CaptureDeviceBinding.diagnostic(requested: requested, observed: observed, stage: "after-bind", generation: "test-generation")
        XCTAssertTrue(text.contains("current id=99 uid=CADefaultDeviceAggregate-test"))
        XCTAssertTrue(text.contains("aggregate membership/input routing unqualified"))
        XCTAssertFalse(text.contains("wrong input"))
    }

    func testFailedReadbackCannotAppearAsMatchingDeviceOrMissingUIDAsKnown() {
        let failed = CaptureDeviceBinding.Snapshot(status: -1, byteCount: 4, deviceID: nil, uid: nil, uidStatus: nil)
        let text = CaptureDeviceBinding.diagnostic(requested: requested, observed: failed, stage: "format-confirmation", generation: "test-generation")
        XCTAssertTrue(text.contains("current-device unreadable (status=-1, bytes=4)"))
        XCTAssertTrue(text.contains("routing unqualified"))
        let missingUID = CaptureDeviceBinding.Snapshot(status: 0, byteCount: 4, deviceID: 99, uid: nil, uidStatus: -2)
        XCTAssertTrue(CaptureDeviceBinding.diagnostic(requested: requested, observed: missingUID, stage: "recheck", generation: "test-generation")
            .contains("uid=unreadable(status=-2)"))
    }
}
