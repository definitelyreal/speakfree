// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import XCTest
@testable import SpeakFreeLib

final class BackgroundDisposalTests: XCTestCase {
    private final class Resource {
        let onDeinit: () -> Void
        init(onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }

    func testLastReferenceIsReleasedOffMainEvenWhenWorkerIsFast() {
        XCTAssertTrue(Thread.isMainThread)
        let released = expectation(description: "all resources released")
        released.expectedFulfillmentCount = 1_000
        for _ in 0..<1_000 {
            var resource: Resource? = Resource {
                XCTAssertFalse(Thread.isMainThread)
                released.fulfill()
            }
            BackgroundDisposal.retire(&resource)
            XCTAssertNil(resource)
        }
        wait(for: [released], timeout: 5)
    }

    func testBlockedDestructorDoesNotBlockCallerOrOtherDisposals() {
        let destructorStarted = expectation(description: "destructor started")
        let destructorFinished = expectation(description: "destructor finished")
        let unblock = DispatchSemaphore(value: 0)
        var resource: Resource? = Resource {
            XCTAssertFalse(Thread.isMainThread)
            destructorStarted.fulfill()
            _ = unblock.wait(timeout: .now() + 5)
            destructorFinished.fulfill()
        }
        BackgroundDisposal.retire(&resource)
        wait(for: [destructorStarted], timeout: 2)
        let otherReleased = expectation(description: "another disposal can finish")
        var other: Resource? = Resource { otherReleased.fulfill() }
        BackgroundDisposal.retire(&other)
        wait(for: [otherReleased], timeout: 2)
        unblock.signal()
        wait(for: [destructorFinished], timeout: 2)
    }

    func testTeardownFinishesBeforeCompletionAndLingerKeepsResourceAlive() {
        let prepared = expectation(description: "prepared off main")
        let completed = expectation(description: "completion before disposal")
        let released = expectation(description: "released after linger")
        var resource: Resource? = Resource {
            XCTAssertFalse(Thread.isMainThread)
            released.fulfill()
        }
        weak var weakResource = resource
        BackgroundDisposal.retire(&resource, linger: 0.2, prepare: { _ in
            XCTAssertFalse(Thread.isMainThread)
            prepared.fulfill()
        }, completion: {
            XCTAssertNotNil(weakResource)
            completed.fulfill()
        })
        wait(for: [prepared, completed, released], timeout: 3, enforceOrder: true)
        XCTAssertNil(weakResource)
    }

    func testMissingResourceStillCompletesRecovery() {
        let completed = expectation(description: "recovery callback")
        var resource: Resource?
        BackgroundDisposal.retire(&resource, prepare: { _ in
            XCTFail("nil resource must not invoke teardown")
        }, completion: { completed.fulfill() })
        wait(for: [completed], timeout: 2)
    }
}
