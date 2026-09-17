// ai-suggestion:unverified · session:01a09da8-0424-7b71-a705-10868c5f46e4 · 2026-09-13

import XCTest
@testable import SpeakFreeLib

/// Deliberately ignores cancellation, like a native model constructor already in progress.
private actor AuxiliarySetupBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class AuxiliaryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

final class ParakeetLifecycleTests: XCTestCase {
    func testUnloadDrainsBothNoncooperativeTasksBeforeQueuedReload() async throws {
        let engine = ParakeetEngine()
        let vocabulary = AuxiliarySetupBarrier()
        let endpointing = AuxiliarySetupBarrier()
        let started = expectation(description: "Both old setup tasks started")
        started.expectedFulfillmentCount = 2
        let canceled = expectation(description: "Unload requested cancellation of both tasks")
        canceled.expectedFulfillmentCount = 2
        let events = AuxiliaryEvents()
        try await engine.loadAuxiliarySetupForTesting(vocabulary: {
            await withTaskCancellationHandler {
                started.fulfill()
                await vocabulary.wait()
                events.append("old vocabulary completed")
            } onCancel: { canceled.fulfill() }
        }, endpointing: {
            await withTaskCancellationHandler {
                started.fulfill()
                await endpointing.wait()
                events.append("old endpointing completed")
            } onCancel: { canceled.fulfill() }
        }, onReady: { events.append("stale \($0) ready") })
        await fulfillment(of: [started], timeout: 2)
        let unload = Task { await engine.unloadModel(); events.append("unload returned") }
        await fulfillment(of: [canceled], timeout: 2)

        let reloadAttempted = expectation(description: "Reload reached the occupied lifecycle gate")
        let newSetupStarted = expectation(description: "Both new setup tasks started")
        newSetupStarted.expectedFulfillmentCount = 2
        let reload = Task {
            try await engine.loadAuxiliarySetupForTesting(vocabulary: {
                events.append("new vocabulary started")
                newSetupStarted.fulfill()
            }, endpointing: {
                events.append("new endpointing started")
                newSetupStarted.fulfill()
            }, onAttempt: { reloadAttempted.fulfill() })
        }
        await fulfillment(of: [reloadAttempted], timeout: 2)
        let blocked = await engine.lifecycleStateForTesting
        XCTAssertEqual(blocked.auxiliaryTasks, 2)
        XCTAssertEqual(blocked.queuedOperations, 1)
        XCTAssertTrue(blocked.tearingDown)
        XCTAssertTrue(events.snapshot.isEmpty, "Cancellation alone must not finish setup or unload")

        // Every assertion above is nonthrowing: even a failed XCTest wait reaches these releases.
        await vocabulary.release()
        await endpointing.release()
        await unload.value
        try await reload.value
        await fulfillment(of: [newSetupStarted], timeout: 2)
        await engine.unloadModel()
        let finished = await engine.lifecycleStateForTesting
        XCTAssertEqual(finished.auxiliaryTasks, 0)
        XCTAssertEqual(finished.queuedOperations, 0)
        XCTAssertFalse(finished.tearingDown)
        let trace = events.snapshot
        XCTAssertFalse(trace.contains(where: { $0.hasPrefix("stale") }))
        for old in ["old vocabulary completed", "old endpointing completed"] {
            let oldIndex = try XCTUnwrap(trace.firstIndex(of: old))
            for next in ["new vocabulary started", "new endpointing started", "unload returned"] {
                XCTAssertLessThan(oldIndex, try XCTUnwrap(trace.firstIndex(of: next)))
            }
        }
    }

    func testCanceledQueuedLoadReleasesItsSlotAndCanceledUnloadStillDrains() async throws {
        let engine = ParakeetEngine()
        let barrier = AuxiliarySetupBarrier()
        let started = expectation(description: "Setup started")
        let canceled = expectation(description: "Unload requested cancellation")
        let events = AuxiliaryEvents()
        try await engine.loadAuxiliarySetupForTesting(vocabulary: {
            await withTaskCancellationHandler {
                started.fulfill()
                await barrier.wait()
            } onCancel: { canceled.fulfill() }
        }, endpointing: {})
        await fulfillment(of: [started], timeout: 2)
        let unload = Task { await engine.unloadModel(); events.append("unload returned") }
        await fulfillment(of: [canceled], timeout: 2)
        unload.cancel()
        let attempted = expectation(description: "Canceled load queued behind unload")
        let reload = Task {
            try await engine.loadAuxiliarySetupForTesting(vocabulary: {
                events.append("canceled load started")
            }, endpointing: {}, onAttempt: { attempted.fulfill() })
        }
        await fulfillment(of: [attempted], timeout: 2)
        reload.cancel()
        let blocked = await engine.lifecycleStateForTesting
        XCTAssertEqual(blocked.queuedOperations, 1)
        XCTAssertTrue(events.snapshot.isEmpty)
        await barrier.release()
        await unload.value
        do {
            try await reload.value
            XCTFail("A canceled queued load must throw before setup")
        } catch is CancellationError {}
        await engine.unloadModel()
        XCTAssertEqual(events.snapshot, ["unload returned"])
        let finished = await engine.lifecycleStateForTesting
        XCTAssertEqual(finished.auxiliaryTasks, 0)
        XCTAssertEqual(finished.queuedOperations, 0)
        XCTAssertFalse(finished.tearingDown)
    }
}
