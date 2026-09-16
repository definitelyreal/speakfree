// ai-suggestion:unverified · session:01a0a336-fe39-7870-bdab-33c820f98955 · 2026-09-16
import AppKit
import XCTest
@testable import SpeakFreeLib

final class ScreenSharingInsertionTests: XCTestCase {
    func testAppleScreenSharingIsARemoteViewer() {
        XCTAssertTrue(TextInserter.isRemoteDesktop(bundleID: "com.apple.ScreenSharing"))
        XCTAssertTrue(TextInserter.isRemoteDesktop(bundleID: "com.apple.screensharing"))
    }

    func testExistingRemoteViewersKeepTheirRoute() {
        for id in ["com.splashtop.PersonalBusiness", "com.microsoft.rdc.macos",
                   "com.teamviewer.TeamViewer", "com.realvnc.vncviewer",
                   "com.citrix.receiver.icaviewer", "example.remotedesktop.beta"] {
            XCTAssertTrue(TextInserter.isRemoteDesktop(bundleID: id), id)
        }
    }

    func testOrdinaryAppsAreNotRemoteViewers() {
        for id in [nil, "", "com.apple.TextEdit", "com.apple.finder", "com.apple.Safari",
                   "com.openai.codex", "com.apple.ScreenSharingExtra"] {
            XCTAssertFalse(TextInserter.isRemoteDesktop(bundleID: id), id ?? "nil")
        }
    }

    /// Both insertion tiers are intercepted so a broken classifier still cannot cause
    /// AX writes, real keyboard events, Apple Events, or use of the system clipboard.
    private func makeInserter() -> TextInserter {
        let inserter = TextInserter()
        inserter.frontmostBundleIDProvider = { "com.apple.ScreenSharing" }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.performRemoteInsertion = { _ in }
        inserter.performLocalInsertion = { _ in XCTFail("Remote text reached local insertion") }
        inserter.performUnicodeInsertion = { _ in XCTFail("Remote text reached Unicode key events"); return false }
        inserter.executeAppleScript = { _ in XCTFail("Unexpected AppleScript"); return nil }
        inserter.onRemoteInsertionFailure = { _, message in XCTFail(message) }
        inserter.pasteboard = NSPasteboard(name: .init("speakfree.test.remote.\(UUID().uuidString)"))
        addTeardownBlock { inserter.pasteboard.releaseGlobally() }
        return inserter
    }

    func testScreenSharingDispatchesUnmodifiedTextToRemoteRoute() {
        let inserter = makeInserter()
        var received: [String] = []
        inserter.performRemoteInsertion = { received.append($0) }
        let phrases = ["Hello World, 123!", "Café costs $12.50 — “yes”.\nNext line: naïve 👋"]
        for phrase in phrases { XCTAssertTrue(inserter.insert(text: phrase)) }
        XCTAssertEqual(received, phrases)
        XCTAssertNil(inserter.pasteboard.string(forType: .string))
    }

    func testRemoteRouteIsRetainedAfterRefocusing() {
        let inserter = makeInserter()
        let target = AXUIElementCreateApplication(999_999)
        inserter.refocusElement = { _ in true }
        inserter.directAXInsert = { _, _ in false }
        let delivered = expectation(description: "Remote insertion after focus settles")
        inserter.performRemoteInsertion = { text in
            XCTAssertEqual(text, "Remote refocus test")
            delivered.fulfill()
        }
        XCTAssertTrue(inserter.insert(text: "Remote refocus test", refocusing: target))
        wait(for: [delivered], timeout: 2)
        XCTAssertNil(inserter.pasteboard.string(forType: .string))
    }

    func testSecureInputStillBlocksRemoteInsertion() {
        let inserter = makeInserter()
        inserter.isSecureInputActive = { true }
        inserter.performRemoteInsertion = { _ in XCTFail("Secure Input must block remote typing") }
        XCTAssertFalse(inserter.insert(text: "private scratch text"))
        XCTAssertEqual(inserter.pasteboard.string(forType: .string), "private scratch text")
    }

    func testNativeAppsKeepTheirLocalRoute() {
        let inserter = makeInserter()
        inserter.frontmostBundleIDProvider = { "com.apple.TextEdit" }
        inserter.performRemoteInsertion = { _ in XCTFail("Local app routed remotely") }
        var received: String?
        inserter.performLocalInsertion = { received = $0 }
        XCTAssertTrue(inserter.insert(text: "Local text"))
        XCTAssertEqual(received, "Local text")
    }

    func testSingleLineUsesTargetedEscapedAppleScriptWithoutClipboard() {
        let inserter = makeInserter()
        inserter.performRemoteInsertion = nil
        var scripts: [String] = []
        inserter.executeAppleScript = { scripts.append($0); return nil }
        inserter.pasteboard.setString("original clipboard", forType: .string)
        XCTAssertTrue(inserter.insert(text: "Say \"hello\" at C:\\scratch"))
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("unix id is 999999"))
        XCTAssertTrue(scripts[0].contains("keystroke \"Say \\\"hello\\\" at C:\\\\scratch\""))
        XCTAssertEqual(inserter.pasteboard.string(forType: .string), "original clipboard")
    }

    func testAutomationDenialOffersRecoveryWithoutRetryOrClipboardOverwrite() {
        let inserter = makeInserter()
        inserter.performRemoteInsertion = nil
        var calls = 0
        inserter.executeAppleScript = { _ in calls += 1; return ["NSAppleScriptErrorNumber": -1743] }
        var recovered: String?
        inserter.onRemoteInsertionFailure = { text, message in
            recovered = text
            XCTAssertTrue(message.contains("Privacy & Security → Automation"))
        }
        inserter.pasteboard.setString("preserved", forType: .string)
        inserter.insert(text: "Recovery text")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(recovered, "Recovery text")
        XCTAssertEqual(inserter.pasteboard.string(forType: .string), "preserved")
    }

    func testLargeRemoteClipboardNeverFallsBackToUnicodeEvents() {
        let inserter = makeInserter()
        inserter.performRemoteInsertion = nil
        let type = NSPasteboard.PasteboardType("speakfree.test.large")
        let data = Data(repeating: 42, count: 17 * 1024 * 1024)
        inserter.pasteboard.setData(data, forType: type)
        let generation = inserter.pasteboard.changeCount
        var recovered: String?
        inserter.onRemoteInsertionFailure = { text, _ in recovered = text }
        inserter.insert(text: "Two\nlines")
        XCTAssertEqual(recovered, "Two\nlines")
        XCTAssertEqual(inserter.pasteboard.changeCount, generation)
        XCTAssertEqual(inserter.pasteboard.data(forType: type), data)
    }

    func testUnchangedRemotePasteDispatchesOneShortcut() {
        let inserter = makeInserter()
        inserter.performRemoteInsertion = nil
        let pasted = expectation(description: "Guarded remote shortcut")
        pasted.assertForOverFulfill = true
        inserter.executeAppleScript = { source in
            XCTAssertTrue(source.contains("keystroke \"v\" using command down"))
            XCTAssertEqual(inserter.pasteboard.string(forType: .string), "Two\nlines")
            pasted.fulfill()
            return nil
        }
        inserter.insert(text: "Two\nlines")
        wait(for: [pasted], timeout: 2)
    }

    func testClipboardChangeCancelsDelayedPaste() {
        checkDelayedPasteCancellation { inserter in
            inserter.pasteboard.clearContents()
            inserter.pasteboard.setString("new user copy", forType: .string)
        }
    }

    func testApplicationChangeCancelsDelayedPaste() {
        checkDelayedPasteCancellation { $0.frontmostPIDProvider = { 888_888 } }
    }

    func testSecureInputChangeCancelsDelayedPaste() {
        checkDelayedPasteCancellation { $0.isSecureInputActive = { true } }
    }

    func testFieldChangeCancelsDelayedPaste() {
        let before = AXUIElementCreateApplication(999_999)
        let after = AXUIElementCreateApplication(888_888)
        checkDelayedPasteCancellation(initialFocus: before) { inserter in
            inserter.focusedElementProvider = { after }
        }
    }

    private func checkDelayedPasteCancellation(
        initialFocus: AXUIElement? = nil, mutate: (TextInserter) -> Void
    ) {
        let inserter = makeInserter()
        inserter.performRemoteInsertion = nil
        inserter.focusedElementProvider = { initialFocus }
        let cancelled = expectation(description: "Changed destination is not pasted into")
        inserter.onRemoteInsertionFailure = { text, _ in
            XCTAssertEqual(text, "Two\nlines")
            cancelled.fulfill()
        }
        inserter.insert(text: "Two\nlines")
        mutate(inserter)
        wait(for: [cancelled], timeout: 2)
    }
}
