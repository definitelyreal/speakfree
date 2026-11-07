import Foundation

/// Finds the separate times something was said in one recording, by loudness alone.
/// Used when teaching a replacement: the user says a word several times with a pause
/// between each, and every repeat is transcribed on its own.
enum UtteranceSplitter {
    static let sampleRate = 16_000
    private static let frame = 320                 // 20 ms
    /// Quieter than this is silence whatever the recording's level.
    private static let floor: Float = 0.006
    /// Speech must reach this fraction of the loudest moment.
    private static let relativeThreshold: Float = 0.12
    /// Quiet shorter than this is a gap between the words of one utterance.
    private static let joinGap = 0.35
    /// Sound shorter than this is a click, not a word.
    private static let minimumLength = 0.12
    /// An utterance is finished once this much quiet has followed it.
    static let closingSilence = 0.6

    /// The sample ranges that hold speech, in order.
    static func utterances(in samples: [Float]) -> [Range<Int>] {
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return [] }
        var levels = [Float](repeating: 0, count: frameCount)
        var loudest: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<frameCount {
                var sum: Float = 0
                for sample in buffer[(index * frame)..<((index + 1) * frame)] { sum += sample * sample }
                let level = (sum / Float(frame)).squareRoot()
                levels[index] = level
                loudest = max(loudest, level)
            }
        }
        let threshold = max(floor, loudest * relativeThreshold)
        let joinFrames = Int(joinGap * Double(sampleRate)) / frame
        let minimumFrames = Int(minimumLength * Double(sampleRate)) / frame

        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0...frameCount {
            let speaking = index < frameCount && levels[index] >= threshold
            if speaking {
                if start == nil { start = index }
            } else if let runStart = start {
                if let last = runs.last, runStart - last.upperBound < joinFrames {
                    runs[runs.count - 1] = last.lowerBound..<index
                } else {
                    runs.append(runStart..<index)
                }
                start = nil
            }
        }
        return runs
            .filter { $0.count >= minimumFrames }
            .map { ($0.lowerBound * frame)..<($0.upperBound * frame) }
    }

    /// How many utterances are already finished: followed by enough quiet that the
    /// speaker has clearly moved on.
    static func finishedCount(in samples: [Float]) -> Int {
        let needed = Int(closingSilence * Double(sampleRate))
        return utterances(in: samples).filter { samples.count - $0.upperBound >= needed }.count
    }

    /// An utterance with a little quiet on each side, which the engine hears better
    /// than a clip cut tight to the word.
    static func clip(_ range: Range<Int>, from samples: [Float], padding: Double = 0.3) -> [Float] {
        let pad = Int(padding * Double(sampleRate))
        let lower = max(0, range.lowerBound - pad / 2)
        let upper = min(samples.count, range.upperBound + pad / 2)
        let silence = [Float](repeating: 0, count: pad)
        return silence + samples[lower..<upper] + silence
    }
}
