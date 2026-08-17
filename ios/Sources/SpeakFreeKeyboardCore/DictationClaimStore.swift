// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

/// A receipt in the keyboard extension's private container. It prevents extension recreation from
/// duplicating an already-claimed session without requiring Full Access or writing to the App Group.
public enum DictationClaimReceiptPhase: String, Codable, Equatable, Sendable {
    case pending
    case committed
}

public struct DictationClaimReceipt: Codable, Equatable, Sendable {
    public let revisionState: DictationRevisionState
    public let savedAt: Date
    public let phase: DictationClaimReceiptPhase
    public let plannedEdit: TypingEdit?
    public let contextBeforeInput: String?
    public let contextAfterInput: String?

    public init(
        revisionState: DictationRevisionState,
        savedAt: Date = Date(),
        redactingTerminalText: Bool = false
    ) {
        self.revisionState = redactingTerminalText
            ? DictationRevisionState(
                sessionID: revisionState.sessionID,
                appliedRevision: revisionState.appliedRevision,
                finalizedSegments: [],
                volatileText: "",
                anchorSuffix: "",
                documentIdentifier: revisionState.documentIdentifier,
                contextAfterInput: nil
            )
            : revisionState
        self.savedAt = savedAt
        phase = .committed
        plannedEdit = nil
        contextBeforeInput = nil
        contextAfterInput = nil
    }

    public init(
        pending revisionState: DictationRevisionState,
        edit: TypingEdit,
        contextBeforeInput: String,
        contextAfterInput: String?,
        savedAt: Date = Date()
    ) {
        self.revisionState = revisionState
        self.savedAt = savedAt
        phase = .pending
        plannedEdit = edit
        self.contextBeforeInput = contextBeforeInput
        self.contextAfterInput = contextAfterInput
    }

    private enum CodingKeys: String, CodingKey {
        case revisionState, savedAt, phase, plannedEdit, contextBeforeInput, contextAfterInput
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revisionState = try values.decode(DictationRevisionState.self, forKey: .revisionState)
        savedAt = try values.decode(Date.self, forKey: .savedAt)
        // Receipts written by the pre-transaction build represented completed edits.
        phase = try values.decodeIfPresent(DictationClaimReceiptPhase.self, forKey: .phase)
            ?? .committed
        plannedEdit = try values.decodeIfPresent(TypingEdit.self, forKey: .plannedEdit)
        contextBeforeInput = try values.decodeIfPresent(String.self, forKey: .contextBeforeInput)
        contextAfterInput = try values.decodeIfPresent(String.self, forKey: .contextAfterInput)
    }
}

public struct DictationClaimStore: Sendable {
    public let receiptURL: URL

    public init(receiptURL: URL) {
        self.receiptURL = receiptURL
    }

    public func read() throws -> DictationClaimReceipt? {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        return try JSONDecoder().decode(
            DictationClaimReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
    }

    public func write(_ receipt: DictationClaimReceipt) throws {
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: receiptURL.path
        )
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: receiptURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
