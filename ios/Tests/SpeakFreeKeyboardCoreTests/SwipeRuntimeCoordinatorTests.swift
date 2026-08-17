// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class SwipeRuntimeCoordinatorTests: XCTestCase {
    func testFirstDecodeWaitsForVocabularyAndModelBeforePredicting() {
        let events = LockedEvents()
        let coordinator = makeCoordinator(
            events: events,
            vocabularyLoader: {
                events.append("vocabulary")
                return [VocabularyEntry(word: "a")]
            },
            runtimeLoader: {
                events.append("model")
                return PredictingRuntime(events: events)
            }
        )

        let result = decode(coordinator)
        guard case .success = result else {
            return XCTFail("first swipe should wait for initialization, not report unavailable")
        }
        XCTAssertEqual(events.values, ["vocabulary", "model", "predict"])
    }

    func testModelFailureRetriesAndVocabularyFailureRetries() {
        let modelEvents = LockedEvents()
        var modelAttempts = 0
        let modelCoordinator = makeCoordinator(
            events: modelEvents,
            vocabularyLoader: {
                modelEvents.append("vocabulary")
                return [VocabularyEntry(word: "a")]
            },
            runtimeLoader: {
                modelAttempts += 1
                modelEvents.append("model-\(modelAttempts)")
                if modelAttempts == 1 { throw TestError.failed }
                return PredictingRuntime(events: modelEvents)
            }
        )
        guard case .unavailable = decode(modelCoordinator) else {
            return XCTFail("failed model load must be surfaced")
        }
        guard case .success = decode(modelCoordinator) else {
            return XCTFail("the next decode should retry a failed model load")
        }
        XCTAssertEqual(modelEvents.values, [
            "vocabulary", "model-1", "vocabulary", "model-2", "predict"
        ])

        let vocabularyEvents = LockedEvents()
        var vocabularyAttempts = 0
        let vocabularyCoordinator = makeCoordinator(
            events: vocabularyEvents,
            vocabularyLoader: {
                vocabularyAttempts += 1
                vocabularyEvents.append("vocabulary-\(vocabularyAttempts)")
                if vocabularyAttempts == 1 { throw TestError.failed }
                return [VocabularyEntry(word: "a")]
            },
            runtimeLoader: {
                vocabularyEvents.append("model")
                return PredictingRuntime(events: vocabularyEvents)
            }
        )
        guard case .unavailable = decode(vocabularyCoordinator) else {
            return XCTFail("failed vocabulary load must be surfaced")
        }
        guard case .success = decode(vocabularyCoordinator) else {
            return XCTFail("the next decode should retry a failed vocabulary load")
        }
        XCTAssertEqual(vocabularyEvents.values, [
            "vocabulary-1", "vocabulary-2", "model", "predict"
        ])
    }

    func testFreshCoordinatorReloadsAfterProcessRecreation() {
        let events = LockedEvents()
        let makeFreshCoordinator = {
            self.makeCoordinator(
                events: events,
                vocabularyLoader: {
                    events.append("vocabulary")
                    return [VocabularyEntry(word: "a")]
                },
                runtimeLoader: {
                    events.append("model")
                    return PredictingRuntime(events: events)
                }
            )
        }

        guard case .success = decode(makeFreshCoordinator()) else {
            return XCTFail("first process should decode")
        }
        guard case .success = decode(makeFreshCoordinator()) else {
            return XCTFail("recreated process should initialize and decode independently")
        }
        XCTAssertEqual(events.values, [
            "vocabulary", "model", "predict", "vocabulary", "model", "predict"
        ])
    }

    func testEmptyVocabularyFailsClosedBeforeLoadingTheModelAndRetries() {
        let events = LockedEvents()
        var attempts = 0
        let coordinator = makeCoordinator(
            events: events,
            vocabularyLoader: {
                attempts += 1
                events.append("vocabulary-\(attempts)")
                return attempts == 1 ? [] : [VocabularyEntry(word: "a")]
            },
            runtimeLoader: {
                events.append("model")
                return PredictingRuntime(events: events)
            }
        )

        guard case .unavailable(let reason) = decode(coordinator) else {
            return XCTFail("an empty vocabulary must fail closed")
        }
        XCTAssertTrue(reason.contains("empty or invalid"))
        guard case .success = decode(coordinator) else {
            return XCTFail("a later decode should retry the invalid vocabulary")
        }
        XCTAssertEqual(events.values, ["vocabulary-1", "vocabulary-2", "model", "predict"])
    }

    private func makeCoordinator(
        events: LockedEvents,
        vocabularyLoader: @escaping () throws -> [VocabularyEntry],
        runtimeLoader: @escaping () throws -> any SwipeModelRuntime
    ) -> SwipeRuntimeCoordinator {
        SwipeRuntimeCoordinator(
            vocabularyLoader: vocabularyLoader,
            runtimeLoader: runtimeLoader,
            loadQueue: DispatchQueue(label: "SwipeRuntimeCoordinatorTests.load.\(UUID())"),
            inferenceQueue: DispatchQueue(label: "SwipeRuntimeCoordinatorTests.inference.\(UUID())"),
            completionQueue: DispatchQueue(label: "SwipeRuntimeCoordinatorTests.completion.\(UUID())")
        )
    }

    private func decode(_ coordinator: SwipeRuntimeCoordinator) -> SwipeRuntimeDecodeResult {
        let expectation = expectation(description: "decode")
        var received: SwipeRuntimeDecodeResult?
        coordinator.decode(
            points: [
                TrajectoryPoint(x: 20, y: 20, timestamp: 0),
                TrajectoryPoint(x: 80, y: 20, timestamp: 0.1)
            ],
            keyboardSize: KeyboardSize(width: 320, height: 180),
            candidateLimit: 1
        ) {
            received = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return received!
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? { "fixture failure" }
}

private final class PredictingRuntime: SwipeModelRuntime {
    let labels: [Character] = ["a"]
    let blankIndex = 1
    private let events: LockedEvents

    init(events: LockedEvents) {
        self.events = events
    }

    func predict(input: SwipeTensor) throws -> [[Float]] {
        events.append("predict")
        return (0..<32).map { index in
            index == 0 ? [0, -20] : [-20, 0]
        }
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
