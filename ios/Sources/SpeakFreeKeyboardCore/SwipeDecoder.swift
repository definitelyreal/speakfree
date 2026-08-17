// ai-suggestion:unverified · session:unknown · 2026-08-16

import Foundation

/// Abstraction over the separately supplied on-device model runtime.
///
/// Implementations receive channel-first `[1, 2, 64]` coordinates and return
/// log probabilities arranged as `[time][class]`.
public protocol SwipeModelRuntime {
    var labels: [Character] { get }
    var blankIndex: Int { get }
    func predict(input: SwipeTensor) throws -> [[Float]]
}

public struct SwipeDecoder {
    public let runtime: any SwipeModelRuntime
    public let vocabulary: VocabularyTrie
    public let preprocessor: TrajectoryPreprocessor
    public let beamWidth: Int
    public let frequencyWeight: Float

    public init(
        runtime: any SwipeModelRuntime,
        vocabulary: VocabularyTrie,
        preprocessor: TrajectoryPreprocessor = TrajectoryPreprocessor(),
        beamWidth: Int = 32,
        frequencyWeight: Float = 0.15
    ) {
        self.runtime = runtime
        self.vocabulary = vocabulary
        self.preprocessor = preprocessor
        self.beamWidth = beamWidth
        self.frequencyWeight = frequencyWeight
    }

    public func decode(
        points: [TrajectoryPoint],
        keyboardSize: KeyboardSize,
        candidateLimit: Int = 4
    ) throws -> [SwipeCandidate] {
        let input = try preprocessor.prepare(points: points, keyboardSize: keyboardSize)
        let output = try runtime.predict(input: input)
        let decoder = try CTCPrefixBeamSearchDecoder(
            labels: runtime.labels,
            blankIndex: runtime.blankIndex,
            beamWidth: beamWidth,
            frequencyWeight: frequencyWeight
        )
        return try decoder.decode(
            logProbabilities: output,
            vocabulary: vocabulary,
            candidateLimit: candidateLimit
        )
    }
}
