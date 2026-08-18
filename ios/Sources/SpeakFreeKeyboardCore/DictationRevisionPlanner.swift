// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation

/// The document facts needed to prove that a streaming dictation suffix is still ours to edit.
public struct DictationDocumentContext: Equatable, Sendable {
    public let documentIdentifier: String
    public let contextBeforeInput: String?
    public let selectedText: String?
    public let contextAfterInput: String?

    public init(
        documentIdentifier: String,
        contextBeforeInput: String?,
        selectedText: String?,
        contextAfterInput: String?
    ) {
        self.documentIdentifier = documentIdentifier
        self.contextBeforeInput = contextBeforeInput
        self.selectedText = selectedText
        self.contextAfterInput = contextAfterInput
    }
}

/// Proof retained after applying a revision.
///
/// `insertedText` is the exact text this keyboard currently owns in the host document — already
/// formatted, so later revisions diff against what the user can actually see. `anchorSuffix` is the
/// bounded host-owned text immediately *before* that region and is captured once, at claim time: it
/// never absorbs dictated text, which keeps sentence detection stable for the whole session.
public struct DictationRevisionState: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let appliedRevision: UInt64
    public let finalizedSegments: [DictationSegment]
    public let volatileText: String
    public let insertedText: String
    public let anchorSuffix: String
    public let documentIdentifier: String
    public let contextAfterInput: String?

    public init(
        sessionID: UUID,
        appliedRevision: UInt64,
        finalizedSegments: [DictationSegment],
        volatileText: String,
        insertedText: String,
        anchorSuffix: String,
        documentIdentifier: String,
        contextAfterInput: String?
    ) {
        self.sessionID = sessionID
        self.appliedRevision = appliedRevision
        self.finalizedSegments = finalizedSegments
        self.volatileText = volatileText
        self.insertedText = insertedText
        self.anchorSuffix = anchorSuffix
        self.documentIdentifier = documentIdentifier
        self.contextAfterInput = contextAfterInput
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, appliedRevision, finalizedSegments, volatileText
        case insertedText, anchorSuffix, documentIdentifier, contextAfterInput
    }

    /// Receipts written by builds before formatted ownership recorded no `insertedText`; those
    /// builds always inserted the raw rendered text, so it is reconstructible. Their `anchorSuffix`
    /// also absorbed finalized text, so the ownership proof below simply fails closed and the user
    /// re-taps the relay instead of the keyboard editing text it can no longer prove it owns.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        appliedRevision = try values.decode(UInt64.self, forKey: .appliedRevision)
        finalizedSegments = try values.decode([DictationSegment].self, forKey: .finalizedSegments)
        volatileText = try values.decode(String.self, forKey: .volatileText)
        anchorSuffix = try values.decode(String.self, forKey: .anchorSuffix)
        documentIdentifier = try values.decode(String.self, forKey: .documentIdentifier)
        contextAfterInput = try values.decodeIfPresent(String.self, forKey: .contextAfterInput)
        insertedText = try values.decodeIfPresent(String.self, forKey: .insertedText)
            ?? (finalizedSegments.map(\.text).joined() + volatileText)
    }
}

public enum DictationRevisionRejection: Equatable, Sendable {
    case unavailableContext
    case selectedTextChanged
    case documentChanged
    case cursorOrSurroundingTextChanged
    case sessionChanged
    case staleRevision
    case finalizedHistoryChanged
    case editExceedsProvenOwnership
}

public enum DictationRevisionDecision: Equatable, Sendable {
    case apply(edit: TypingEdit, nextState: DictationRevisionState)
    case advanceWithoutEdit(nextState: DictationRevisionState)
    case reject(DictationRevisionRejection)
}

/// Builds conservative, cursor-local edits for progressively improving speech recognition.
/// Any lost proof fails closed, leaving host-owned text untouched.
public enum DictationRevisionPlanner {
    public static let maximumAnchorLength = 64
    /// Only the tail of the owned region is proven against the host's before-context. UIKit
    /// truncates `documentContextBeforeInput` for long documents, and a whole-utterance proof
    /// would reject every revision of a long dictation.
    public static let maximumOwnedProofLength = 128

    public static func plan(
        snapshot: DictationSnapshot,
        in context: DictationDocumentContext,
        from previousState: DictationRevisionState?,
        capitalization: DictationCapitalizationPolicy = .none
    ) throws -> DictationRevisionDecision {
        try snapshot.validate()
        guard context.selectedText?.isEmpty != false else {
            return .reject(.selectedTextChanged)
        }
        guard let contextBeforeInput = context.contextBeforeInput else {
            return .reject(.unavailableContext)
        }

        let hostPrefix: String
        let previouslyInserted: String

        if let previousState {
            guard snapshot.sessionID == previousState.sessionID else {
                return .reject(.sessionChanged)
            }
            guard snapshot.revision > previousState.appliedRevision else {
                return .reject(.staleRevision)
            }
            guard context.documentIdentifier == previousState.documentIdentifier else {
                return .reject(.documentChanged)
            }
            guard context.contextAfterInput == previousState.contextAfterInput else {
                return .reject(.cursorOrSurroundingTextChanged)
            }

            let oldFinalized = previousState.finalizedSegments
            guard snapshot.finalizedSegments.count >= oldFinalized.count,
                  Array(snapshot.finalizedSegments.prefix(oldFinalized.count)) == oldFinalized else {
                return .reject(.finalizedHistoryChanged)
            }
            guard contextBeforeInput.hasSuffix(ownershipProof(for: previousState)) else {
                return .reject(.cursorOrSurroundingTextChanged)
            }
            hostPrefix = previousState.anchorSuffix
            previouslyInserted = previousState.insertedText
        } else {
            hostPrefix = anchor(of: contextBeforeInput)
            previouslyInserted = ""
        }

        let desiredText = DictationTextFormatter.format(
            snapshot.renderedText,
            contextBeforeInput: hostPrefix,
            capitalization: capitalization
        )
        let nextState = DictationRevisionState(
            sessionID: snapshot.sessionID,
            appliedRevision: snapshot.revision,
            finalizedSegments: snapshot.finalizedSegments,
            volatileText: snapshot.volatileText,
            insertedText: desiredText,
            anchorSuffix: hostPrefix,
            documentIdentifier: context.documentIdentifier,
            contextAfterInput: context.contextAfterInput
        )
        let edit = minimalEdit(from: previouslyInserted, to: desiredText)
        // Only the tail of the owned region was proven against the host document. A deeper
        // rewrite than that would delete characters we cannot prove are ours, so fail closed.
        guard edit.deleteBackwardCount <= provenOwnedTailLength(of: previouslyInserted) else {
            return .reject(.editExceedsProvenOwnership)
        }
        return edit == .none
            ? .advanceWithoutEdit(nextState: nextState)
            : .apply(edit: edit, nextState: nextState)
    }

    /// The revised hypothesis usually shares a long prefix with the text already on screen.
    /// Rewriting only the divergent tail keeps the host's caret — and therefore its scroll
    /// position and autolayout — from being torn down and rebuilt on every revision.
    public static func minimalEdit(from current: String, to desired: String) -> TypingEdit {
        let shared = commonPrefixCount(current, desired)
        return TypingEdit(
            deleteBackwardCount: current.count - shared,
            insertion: String(desired.dropFirst(shared))
        )
    }

    /// Counts shared leading extended grapheme clusters, so an edit never splits a cluster and a
    /// combining mark is never inserted on its own.
    public static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        while lhsIndex < lhs.endIndex, rhsIndex < rhs.endIndex, lhs[lhsIndex] == rhs[rhsIndex] {
            count += 1
            lhs.formIndex(after: &lhsIndex)
            rhs.formIndex(after: &rhsIndex)
        }
        return count
    }

    static func provenOwnedTailLength(of insertedText: String) -> Int {
        min(insertedText.count, maximumAnchorLength + maximumOwnedProofLength)
    }

    public static func ownershipProof(for state: DictationRevisionState) -> String {
        String((state.anchorSuffix + state.insertedText).suffix(
            maximumAnchorLength + maximumOwnedProofLength
        ))
    }

    private static func anchor(of text: String) -> String {
        String(text.suffix(maximumAnchorLength))
    }
}
