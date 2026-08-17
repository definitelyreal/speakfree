// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

/// A committed candidate that SpeakFree may replace only while its exact text still owns the
/// document suffix. `UITextDocumentProxy` does not provide transactional edits, so a mismatch
/// deliberately fails closed instead of deleting a character count from unrelated host text.
public struct CommittedCandidate: Equatable, Sendable {
    public let text: String
    public let trailingSeparator: String

    public init(text: String, trailingSeparator: String = " ") {
        self.text = text
        self.trailingSeparator = trailingSeparator
    }

    public var ownedSuffix: String { text + trailingSeparator }

    public func replacementEdit(
        with candidate: String,
        before contextBeforeInput: String?
    ) -> TypingEdit? {
        guard !candidate.isEmpty,
              let contextBeforeInput,
              contextBeforeInput.hasSuffix(ownedSuffix) else { return nil }
        if candidate == text { return TypingEdit.none }
        return TypingEdit(
            deleteBackwardCount: ownedSuffix.count,
            insertion: candidate + trailingSeparator
        )
    }

    public func removalEdit(before contextBeforeInput: String?) -> TypingEdit? {
        guard let contextBeforeInput,
              contextBeforeInput.hasSuffix(ownedSuffix) else { return nil }
        return TypingEdit(deleteBackwardCount: ownedSuffix.count)
    }
}
