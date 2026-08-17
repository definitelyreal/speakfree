// ai-suggestion:unverified · session:unknown · 2026-08-16

import Foundation

public struct SwipeCandidate: Equatable, Sendable {
    public let word: String
    public let score: Float

    public init(word: String, score: Float) {
        self.word = word
        self.score = score
    }
}

public struct CTCPrefixBeamSearchDecoder: Sendable {
    public let labels: [Character]
    public let blankIndex: Int
    public let beamWidth: Int
    public let frequencyWeight: Float

    public init(
        labels: [Character],
        blankIndex: Int,
        beamWidth: Int = 32,
        frequencyWeight: Float = 0.15
    ) throws {
        guard beamWidth > 0 else {
            throw SwipeCoreError.invalidDecoderConfiguration("Beam width must be positive")
        }
        guard blankIndex >= 0, blankIndex <= labels.count else {
            throw SwipeCoreError.invalidDecoderConfiguration("Blank index is outside the class range")
        }
        self.labels = labels
        self.blankIndex = blankIndex
        self.beamWidth = beamWidth
        self.frequencyWeight = frequencyWeight
    }

    public func decode(
        logProbabilities: [[Float]],
        vocabulary: VocabularyTrie,
        candidateLimit: Int = 4
    ) throws -> [SwipeCandidate] {
        guard !vocabulary.isEmpty, candidateLimit > 0 else { return [] }
        let classCount = labels.count + 1
        guard !logProbabilities.isEmpty,
              logProbabilities.allSatisfy({ $0.count == classCount }) else {
            throw SwipeCoreError.invalidModelOutput(
                "Expected non-empty [time][\(classCount)] CTC log probabilities"
            )
        }

        var beams: [PrefixKey: Beam] = [
            PrefixKey(text: "", trieNode: 0): Beam(blank: 0, nonBlank: -.infinity),
        ]

        for timestep in logProbabilities {
            var next: [PrefixKey: Beam] = [:]

            for (key, beam) in beams {
                let total = logAdd(beam.blank, beam.nonBlank)
                update(&next, key: key, blank: total + timestep[blankIndex])

                for (labelIndex, character) in labels.enumerated() {
                    let classIndex = labelIndex < blankIndex ? labelIndex : labelIndex + 1
                    let emission = timestep[classIndex]

                    if key.text.last == character {
                        // Re-emitting a character without an intervening blank stays on
                        // the same CTC prefix.
                        update(&next, key: key, nonBlank: beam.nonBlank + emission)

                        // A repeat following a blank is a real second character.
                        if let child = vocabulary.child(of: key.trieNode, character: character) {
                            let extended = PrefixKey(
                                text: key.text + String(character),
                                trieNode: child
                            )
                            update(&next, key: extended, nonBlank: beam.blank + emission)
                        }
                    } else if let child = vocabulary.child(of: key.trieNode, character: character) {
                        let extended = PrefixKey(
                            text: key.text + String(character),
                            trieNode: child
                        )
                        update(&next, key: extended, nonBlank: total + emission)
                    }
                }
            }

            beams = Dictionary(
                uniqueKeysWithValues: next
                    .sorted { beamScore($0.value) > beamScore($1.value) }
                    .prefix(beamWidth)
                    .map { ($0.key, $0.value) }
            )
        }

        return beams.compactMap { key, beam -> SwipeCandidate? in
            guard let frequency = vocabulary.terminalFrequency(at: key.trieNode) else {
                return nil
            }
            let acousticScore = beamScore(beam)
            let score = acousticScore + frequencyWeight * Float(log(max(frequency, 1)))
            return SwipeCandidate(word: key.text, score: score)
        }
        .sorted {
            if $0.score == $1.score { return $0.word < $1.word }
            return $0.score > $1.score
        }
        .prefix(candidateLimit)
        .map { $0 }
    }
}

private struct PrefixKey: Hashable {
    let text: String
    let trieNode: Int
}

private struct Beam {
    var blank: Float = -.infinity
    var nonBlank: Float = -.infinity
}

private func update(
    _ beams: inout [PrefixKey: Beam],
    key: PrefixKey,
    blank: Float = -.infinity,
    nonBlank: Float = -.infinity
) {
    var beam = beams[key] ?? Beam()
    beam.blank = logAdd(beam.blank, blank)
    beam.nonBlank = logAdd(beam.nonBlank, nonBlank)
    beams[key] = beam
}

private func beamScore(_ beam: Beam) -> Float {
    logAdd(beam.blank, beam.nonBlank)
}

private func logAdd(_ lhs: Float, _ rhs: Float) -> Float {
    if lhs == -.infinity { return rhs }
    if rhs == -.infinity { return lhs }
    let high = max(lhs, rhs)
    let low = min(lhs, rhs)
    return high + log1p(exp(low - high))
}
