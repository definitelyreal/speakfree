// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
import ApplicationServices
import Foundation

/// Insertion seam for the finalize pipeline. `TextInserter` is the production
/// implementation (driving AX → CGEvent → clipboard); test doubles (MockInserter)
/// record what *would* be inserted without touching AX or the pasteboard.
///
/// The conformance for `TextInserter` lives here — NOT in TextInserter.swift — so the
/// pipeline can be integration-tested without entangling TextInserter's own source.
public protocol TextInserting: AnyObject {
    /// Whether a leading space should be prepended (cursor follows a non-whitespace char).
    func shouldPrependSpace(before element: AXUIElement?) -> Bool

    /// Insert `text`, optionally refocusing `element`. Returns true if inserted, false if
    /// focus could not be restored (text copied to clipboard instead, `onFocusLost` fired).
    @discardableResult
    func insert(text: String, refocusing element: AXUIElement?, onFocusLost: (() -> Void)?) -> Bool
}

/// Production conformance. `TextInserter` already exposes these exact signatures
/// (with default args); declaring the conformance here keeps TextInserter.swift untouched.
extension TextInserter: TextInserting {}
