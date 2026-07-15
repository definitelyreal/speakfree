// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
import Foundation

/// Testable extraction of `AppDelegate.buildStableDisplayText` + its `committedStreamingText`
/// state. Builds stable streaming display text: once a sentence ends in `.!?` it is *committed*
/// (frozen, never reflows) and subsequent partials append after it on a new line.
///
/// The logic here is byte-identical to the inline version it replaces; AppDelegate keeps a
/// single `StreamingTextAssembler` and forwards `buildStableDisplayText` to `append(_:)`.
public struct StreamingTextAssembler {
    /// Text already committed (sentences that have ended). Frozen across partials.
    public private(set) var committedStreamingText: String = ""

    public init() {}

    /// Reset committed state (mirrors the two `committedStreamingText = ""` resets in the
    /// streaming start/stop paths).
    public mutating func reset() {
        committedStreamingText = ""
    }

    /// Feed a fresh partial transcription; returns the display string and updates committed state.
    @discardableResult
    public mutating func append(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return committedStreamingText }

        // If the new text is shorter than committed, keep committed (prevents regression)
        guard trimmed.count >= committedStreamingText.replacingOccurrences(of: "\n", with: " ").count else {
            return committedStreamingText
        }

        // Find the portion of text beyond what we've committed
        let committedFlat = committedStreamingText.replacingOccurrences(of: "\n", with: " ")
        let newPortion: String
        if trimmed.hasPrefix(committedFlat) {
            newPortion = String(trimmed.dropFirst(committedFlat.count)).trimmingCharacters(in: .whitespaces)
        } else {
            // The new partial does NOT start with what we committed — whisper re-transcribed the
            // audio and the earlier text changed under us. Positionally dropping `committedFlat.count`
            // chars here would slice mid-word and garble the overlay. Instead, discard the stale
            // commit and adopt the fresh partial wholesale; it self-corrects to the re-transcription.
            committedStreamingText = ""
            if let lastPunct = trimmed.lastIndex(where: { ".!?".contains($0) }) {
                committedStreamingText = String(trimmed[...lastPunct])
            }
            return trimmed
        }

        if newPortion.isEmpty { return committedStreamingText }

        // Check if the new portion contains complete sentences (ends with .!?)
        // If so, commit everything up to the last sentence end
        var result = committedStreamingText
        if !result.isEmpty && !newPortion.isEmpty {
            result += "\n"
        }
        result += newPortion

        // Commit text through the last sentence-ending punctuation
        if let lastPunct = newPortion.lastIndex(where: { ".!?".contains($0) }) {
            let throughPunct = String(newPortion[...lastPunct])
            if committedStreamingText.isEmpty {
                committedStreamingText = throughPunct
            } else {
                committedStreamingText += "\n" + throughPunct
            }
        }

        return result
    }
}
