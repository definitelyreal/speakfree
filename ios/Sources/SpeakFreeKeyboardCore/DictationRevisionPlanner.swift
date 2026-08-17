// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

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

/// Proof retained after applying a revision. Only `volatileText` is rewritten; finalized segments
/// remain immutable and become part of the nearby anchor.
public struct DictationRevisionState: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let appliedRevision: UInt64
    public let finalizedSegments: [DictationSegment]
    public let volatileText: String
    public let anchorSuffix: String
    public let documentIdentifier: String
    public let contextAfterInput: String?

    public init(
        sessionID: UUID,
        appliedRevision: UInt64,
        finalizedSegments: [DictationSegment],
        volatileText: String,
        anchorSuffix: String,
        documentIdentifier: String,
        contextAfterInput: String?
    ) {
        self.sessionID = sessionID
        self.appliedRevision = appliedRevision
        self.finalizedSegments = finalizedSegments
        self.volatileText = volatileText
        self.anchorSuffix = anchorSuffix
        self.documentIdentifier = documentIdentifier
        self.contextAfterInput = contextAfterInput
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

    public static func plan(
        snapshot: DictationSnapshot,
        in context: DictationDocumentContext,
        from previousState: DictationRevisionState?
    ) throws -> DictationRevisionDecision {
        try snapshot.validate()
        guard context.selectedText?.isEmpty != false else {
            return .reject(.selectedTextChanged)
        }
        guard let contextBeforeInput = context.contextBeforeInput else {
            return .reject(.unavailableContext)
        }

        guard let previousState else {
            let nextState = DictationRevisionState(
                sessionID: snapshot.sessionID,
                appliedRevision: snapshot.revision,
                finalizedSegments: snapshot.finalizedSegments,
                volatileText: snapshot.volatileText,
                anchorSuffix: anchor(of: contextBeforeInput + snapshot.finalizedText),
                documentIdentifier: context.documentIdentifier,
                contextAfterInput: context.contextAfterInput
            )
            let edit = TypingEdit(insertion: snapshot.renderedText)
            return edit == .none
                ? .advanceWithoutEdit(nextState: nextState)
                : .apply(edit: edit, nextState: nextState)
        }

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

        let proofSuffix = previousState.anchorSuffix + previousState.volatileText
        guard contextBeforeInput.hasSuffix(proofSuffix) else {
            return .reject(.cursorOrSurroundingTextChanged)
        }

        let newlyFinalized = snapshot.finalizedSegments
            .dropFirst(oldFinalized.count)
            .map(\.text)
            .joined()
        let insertion = newlyFinalized + snapshot.volatileText
        let edit = TypingEdit(
            deleteBackwardCount: previousState.volatileText.count,
            insertion: insertion
        )

        var textBeforeOwnedSuffix = contextBeforeInput
        for _ in 0..<previousState.volatileText.count {
            textBeforeOwnedSuffix.removeLast()
        }
        let nextState = DictationRevisionState(
            sessionID: snapshot.sessionID,
            appliedRevision: snapshot.revision,
            finalizedSegments: snapshot.finalizedSegments,
            volatileText: snapshot.volatileText,
            anchorSuffix: anchor(of: textBeforeOwnedSuffix + newlyFinalized),
            documentIdentifier: context.documentIdentifier,
            contextAfterInput: context.contextAfterInput
        )

        return edit == .none
            ? .advanceWithoutEdit(nextState: nextState)
            : .apply(edit: edit, nextState: nextState)
    }

    private static func anchor(of text: String) -> String {
        String(text.suffix(maximumAnchorLength))
    }
}
