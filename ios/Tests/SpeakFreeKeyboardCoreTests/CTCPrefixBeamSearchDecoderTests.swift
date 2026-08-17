// ai-suggestion:unverified · session:unknown · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class CTCPrefixBeamSearchDecoderTests: XCTestCase {
    func testDecodesTrieConstrainedWord() throws {
        let decoder = try CTCPrefixBeamSearchDecoder(
            labels: ["a", "c", "t"],
            blankIndex: 3,
            beamWidth: 16
        )
        let probabilities = emissions(
            classCount: 4,
            dominantClasses: [1, 3, 0, 3, 2]
        )

        let candidates = try decoder.decode(
            logProbabilities: probabilities,
            vocabulary: VocabularyTrie(words: ["cat", "act"])
        )

        XCTAssertEqual(candidates.first?.word, "cat")
    }

    func testBlankAllowsRepeatedCharacters() throws {
        let decoder = try CTCPrefixBeamSearchDecoder(
            labels: ["l", "o"],
            blankIndex: 2,
            beamWidth: 16
        )
        let probabilities = emissions(
            classCount: 3,
            dominantClasses: [0, 2, 0]
        )

        let candidates = try decoder.decode(
            logProbabilities: probabilities,
            vocabulary: VocabularyTrie(words: ["ll", "lo"])
        )

        XCTAssertEqual(candidates.first?.word, "ll")
    }

    func testFrequencyBreaksAcousticTie() throws {
        let decoder = try CTCPrefixBeamSearchDecoder(
            labels: ["a", "c", "r", "t"],
            blankIndex: 4,
            beamWidth: 16,
            frequencyWeight: 1
        )
        var last = [Float](repeating: log(0.001), count: 5)
        last[2] = log(0.49)
        last[3] = log(0.49)
        last[4] = log(0.018)
        let probabilities = emissions(
            classCount: 5,
            dominantClasses: [1, 4, 0, 4]
        ) + [last]

        let candidates = try decoder.decode(
            logProbabilities: probabilities,
            vocabulary: VocabularyTrie(entries: [
                VocabularyEntry(word: "cat", frequency: 1),
                VocabularyEntry(word: "car", frequency: 100),
            ])
        )

        XCTAssertEqual(candidates.first?.word, "car")
        XCTAssertEqual(candidates.map(\.word), ["car", "cat"])
    }
}

private func emissions(classCount: Int, dominantClasses: [Int]) -> [[Float]] {
    dominantClasses.map { dominant in
        (0..<classCount).map { index in
            index == dominant ? log(0.97) : log(0.03 / Float(classCount - 1))
        }
    }
}
