// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import XCTest
@testable import SpeakFreeLib

final class SetupGateTests: XCTestCase {
    func testConcurrentRequestsCoalesceIntoOneReload() {
        let gate = SetupGate()
        XCTAssertTrue(gate.begin())
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertFalse(gate.begin())
            XCTAssertTrue(gate.deferReloadIfRunning())
        }
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.deferReloadIfRunning())
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.finish(), "pending work is consumed only once")
    }

    func testUncontendedSetupDoesNotScheduleAnotherSetup() {
        let gate = SetupGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.finish())
    }
}
