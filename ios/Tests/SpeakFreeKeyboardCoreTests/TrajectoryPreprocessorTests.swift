// ai-suggestion:unverified · session:unknown · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class TrajectoryPreprocessorTests: XCTestCase {
    func testNormalizesAndResamplesToExpectedModelShape() throws {
        let input = [
            TrajectoryPoint(x: 0, y: 0),
            TrajectoryPoint(x: 50, y: 25),
            TrajectoryPoint(x: 100, y: 50),
        ]

        let tensor = try TrajectoryPreprocessor().prepare(
            points: input,
            keyboardSize: KeyboardSize(width: 100, height: 50)
        )

        XCTAssertEqual(tensor.shape, [1, 2, 64])
        XCTAssertEqual(tensor[channel: 0, time: 0], 0, accuracy: 0.0001)
        XCTAssertEqual(tensor[channel: 1, time: 0], 0, accuracy: 0.0001)
        XCTAssertEqual(tensor[channel: 0, time: 63], 1, accuracy: 0.0001)
        XCTAssertEqual(tensor[channel: 1, time: 63], 1, accuracy: 0.0001)
        XCTAssertEqual(tensor[channel: 0, time: 32], 32.0 / 63.0, accuracy: 0.0001)
    }

    func testStationaryTrajectoryRepeatsThePoint() throws {
        let tensor = try TrajectoryPreprocessor().prepare(
            points: [TrajectoryPoint(x: 25, y: 75)],
            keyboardSize: KeyboardSize(width: 100, height: 100)
        )

        XCTAssertEqual(tensor.shape, [1, 2, 64])
        for time in 0..<64 {
            XCTAssertEqual(tensor[channel: 0, time: time], 0.25, accuracy: 0.0001)
            XCTAssertEqual(tensor[channel: 1, time: time], 0.75, accuracy: 0.0001)
        }
    }

    func testRejectsEmptyTrajectory() {
        XCTAssertThrowsError(
            try TrajectoryPreprocessor().prepare(
                points: [],
                keyboardSize: KeyboardSize(width: 100, height: 100)
            )
        ) { error in
            XCTAssertEqual(error as? SwipeCoreError, .emptyTrajectory)
        }
    }

    func testStandardLayoutFindsNearbyQKey() {
        let key = QWERTYKeyboardLayout().closestKey(
            to: NormalizedPoint(x: 0.05, y: 1.0 / 6.0)
        )
        XCTAssertEqual(key?.character, "q")
    }
}
