// ai-suggestion:unverified · session:unknown/agent:astra-alpha-review-1 · 2026-10-01
// Adversarial oracles fixed before source inspection. Named clipboard and synthetic AX identities only.
import AppKit
import ApplicationServices
import XCTest
@testable import SpeakFreeLib

final class AstraAlphaReview1Tests: XCTestCase {
    private func subject() -> TextInserter {
        let pb = NSPasteboard(name: .init("speakfree.test.astra-alpha-1.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("original synthetic clipboard", forType: .string)
        addTeardownBlock { pb.releaseGlobally() }
        let s = TextInserter()
        s.pasteboard = pb
        s.userPasteGate = UserPasteRestoreGate()
        s.frontmostBundleIDProvider = { "com.anthropic.claudefordesktop" }
        s.frontmostBundleURLProvider = { nil }
        s.frontmostPIDProvider = { 999_991 }
        s.focusedElementProvider = { nil }
        s.isSecureInputActive = { false }
        s.layoutVKeyCodeProvider = { 9 }
        s.pasteFieldReader = nil
        s.clipboardTrustReason = { nil }
        s.restoreTiming = { _ in .init(backstop: 120, afterRead: 60) }
        s.postPasteShortcut = { XCTFail("Must not send a paste") }
        s.performUnicodeInsertion = { _ in XCTFail("Must not type"); return false }
        s.executeAppleScript = { _ in XCTFail("Must not invoke AppleScript"); return nil }
        return s
    }

    func testFailedPublicationMustTellEditItsDraftWasNotInserted() {
        let s = subject()
        var failed = false
        var uncertain = false
        s.onRemoteInsertionFailure = { _, _ in failed = true }
        s.onSecureInputFallback = { _, _ in uncertain = true }
        s.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        let accepted = s.insert(text: "Synthetic draft", onFocusLost: { uncertain = true })
        XCTAssertTrue(failed, "The publication fault must actually occur")
        // These are precisely the success inputs available to the Edit caller. Its draft must stay open.
        XCTAssertTrue(!accepted || uncertain, "A known delivery failure must not look successful to Edit")
    }

    func testLostFocusIdentityAfterRefocusMustNotBlindPaste() {
        let s = subject()
        let complete = expectation(description: "settle callback")
        let target = AXUIElementCreateApplication(999_991)
        s.refocusElement = { _ in true }
        s.focusedElementProvider = { nil }
        var pasted = false
        s.performInsertion = { _ in pasted = true }
        s.onRemoteInsertionFailure = { _, _ in }
        _ = s.insert(text: "Synthetic draft", refocusing: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { complete.fulfill() }
        wait(for: [complete], timeout: 2)
        XCTAssertFalse(pasted, "An unavailable focus identity cannot authorize a blind paste after refocus")
    }
}
