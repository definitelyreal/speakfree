// ai-suggestion:unverified · session:unknown · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class SwipeDecoderTests: XCTestCase {
    func testOrchestratesPreprocessingRuntimeAndDecoding() throws {
        let runtime = DeterministicSwipeModelRuntime(
            labels: ["h", "i"],
            blankIndex: 2,
            output: deterministicEmissions(classCount: 3, dominantClasses: [0, 2, 1])
        )
        let decoder = SwipeDecoder(
            runtime: runtime,
            vocabulary: VocabularyTrie(words: ["hi"])
        )

        let candidates = try decoder.decode(
            points: [
                TrajectoryPoint(x: 10, y: 10),
                TrajectoryPoint(x: 90, y: 10),
            ],
            keyboardSize: KeyboardSize(width: 100, height: 50)
        )

        XCTAssertEqual(candidates.first?.word, "hi")
        XCTAssertEqual(runtime.receivedInputs.count, 1)
        XCTAssertEqual(runtime.receivedInputs[0].shape, [1, 2, 64])
    }
}

private final class DeterministicSwipeModelRuntime: SwipeModelRuntime {
    let labels: [Character]
    let blankIndex: Int
    let output: [[Float]]
    private(set) var receivedInputs: [SwipeTensor] = []

    init(labels: [Character], blankIndex: Int, output: [[Float]]) {
        self.labels = labels
        self.blankIndex = blankIndex
        self.output = output
    }

    func predict(input: SwipeTensor) throws -> [[Float]] {
        receivedInputs.append(input)
        return output
    }
}

private func deterministicEmissions(classCount: Int, dominantClasses: [Int]) -> [[Float]] {
    dominantClasses.map { dominant in
        (0..<classCount).map { index in
            index == dominant ? log(0.97) : log(0.03 / Float(classCount - 1))
        }
    }
}
