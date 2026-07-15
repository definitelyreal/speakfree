// Claude · 2026-07-15 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
//
// Round-1 adversarial-review fixes for the insertion / AX / UI surface (Agent-1):
//   AX-C  refocus fallback re-verifies focus before pasting (no blind Cmd+V into the wrong app)
//   AX-D  copyToClipboard focus-lost fallback writes Concealed/Transient markers
//   AX-E  UTF-16 offset conversion for AX cursor ranges (textBeforeUTF16Offset)
//   UI-A  WelcomeController routes a suggested model into the slot matching the engine
//   UI-B  reloadConfig's Parakeet branch keeps the current transcriber when the model isn't downloaded
//
// All tests use the existing TextInserter seams (performInsertion / focusedElementProvider /
// refocusElement / directAXInsert / a named pasteboard) so the suite NEVER posts real keystrokes,
// touches the developer's clipboard, or performs AX WindowServer IPC.

import XCTest
import ApplicationServices
@testable import SpeakFreeLib

final class AdversarialR1InsertionTests: XCTestCase {

    private func makeTestPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("speakfree-r1-test-" + UUID().uuidString))
    }

    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    // MARK: - AX-C: refocus fallback re-verifies focus before pasting

    /// If focus MOVED during the 150ms settle, the closure must NOT blind-paste into the frontmost
    /// app. It must conceal-copy the text and fire onFocusLost instead.
    ///
    /// I2 refinement: "moved" now means the re-query affirmatively returns a DIFFERENT element (nil
    /// no longer counts as moved — see test_i2_nilRequeryProceedsToPaste). So this simulates a real
    /// move by returning an element that is not the refocus target.
    func test_axC_focusMovedDuringSettle_concealsInsteadOfBlindPaste() {
        let exp = expectation(description: "async fallback fires onFocusLost")
        let inserter = TextInserter()
        inserter.pasteboard = makeTestPasteboard()
        inserter.pasteboard.clearContents()
        inserter.secureInputClipboardClearDelay = 60  // don't auto-clear during assertions
        inserter.isSecureInputActive = { false }
        let target = AXUIElementCreateSystemWide()
        // Focus is a DIFFERENT element (an application element, never CFEqual to the system-wide
        // target) on both the sync check and the closure re-check, so the sync path schedules the
        // closure and the closure affirmatively sees "focus moved to a different element".
        let other = AXUIElementCreateApplication(getpid())
        XCTAssertFalse(CFEqual(other, target), "precondition: the two elements must be distinct")
        inserter.focusedElementProvider = { other }
        inserter.refocusElement = { _ in true }        // force the async closure to be scheduled
        inserter.directAXInsert = { _, _ in false }    // force the post-AX fallback branch, no real AX IPC

        // Blind-paste sentinel: if the OLD behavior ran, performInsertion would be called with the text.
        var blindPasted: String?
        inserter.performInsertion = { blindPasted = $0 }

        var focusLostFired = false
        let scheduled = inserter.insert(text: "secret text", refocusing: target, onFocusLost: {
            focusLostFired = true
            exp.fulfill()
        })

        XCTAssertTrue(scheduled, "refocus path must schedule the async closure")
        wait(for: [exp], timeout: 2.0)

        XCTAssertNil(blindPasted, "must NOT blind-paste into the frontmost app when focus moved")
        XCTAssertTrue(focusLostFired, "must notify the caller via onFocusLost when focus moved")
        let types = inserter.pasteboard.pasteboardItems?.first?.types ?? []
        XCTAssertTrue(types.contains(concealed), "focus-moved fallback must conceal the clipboard write")
        XCTAssertEqual(inserter.pasteboard.string(forType: .string), "secret text")
        inserter.pasteboard.clearContents()
    }

    /// If focus is STILL the refocused element when the closure runs, the normal paste path proceeds
    /// (performInsertion is called) and onFocusLost does NOT fire.
    func test_axC_focusStillSame_proceedsWithPaste() {
        let exp = expectation(description: "async paste path runs")
        let inserter = TextInserter()
        inserter.pasteboard = makeTestPasteboard()
        inserter.isSecureInputActive = { false }
        inserter.refocusElement = { _ in true }
        inserter.directAXInsert = { _, _ in false }

        let target = AXUIElementCreateSystemWide()
        // Sync check returns nil (so sameElement is false → schedule the closure); the closure's
        // re-check returns the target (so focus is "still the same element").
        var call = 0
        inserter.focusedElementProvider = {
            call += 1
            return call == 1 ? nil : target
        }

        var pasted: String?
        inserter.performInsertion = {
            pasted = $0
            exp.fulfill()
        }
        var focusLostFired = false
        _ = inserter.insert(text: "hello world", refocusing: target, onFocusLost: { focusLostFired = true })

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(pasted, "hello world", "focus unchanged → the paste path must run")
        XCTAssertFalse(focusLostFired, "onFocusLost must not fire when focus is unchanged")
    }

    // MARK: - AX-D: copyToClipboard focus-lost fallback is concealed

    /// When refocus FAILS outright, insert() falls back to copyToClipboard — which must now write the
    /// Concealed + Transient markers (parity with the two sibling clipboard paths).
    func test_axD_refocusFailedFallback_writesConcealedMarkers() {
        let inserter = TextInserter()
        inserter.pasteboard = makeTestPasteboard()
        inserter.pasteboard.clearContents()
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }    // sync sameElement == false
        inserter.refocusElement = { _ in false }     // refocus fails → copyToClipboard path (synchronous)

        var focusLostFired = false
        let target = AXUIElementCreateSystemWide()
        let result = inserter.insert(text: "dictated words", refocusing: target, onFocusLost: { focusLostFired = true })

        XCTAssertFalse(result, "refocus-failed path returns false")
        XCTAssertTrue(focusLostFired, "onFocusLost must fire when refocus fails")
        let types = inserter.pasteboard.pasteboardItems?.first?.types ?? []
        XCTAssertTrue(types.contains(concealed), "copyToClipboard must add the Concealed marker (AX-D)")
        XCTAssertTrue(types.contains(transient), "copyToClipboard must add the Transient marker (AX-D)")
        XCTAssertEqual(inserter.pasteboard.string(forType: .string), "dictated words")
        inserter.pasteboard.clearContents()
    }

    // MARK: - AX-E: UTF-16 offset conversion

    /// A UTF-16 cursor offset must be converted through the utf16 view. The classic bug: a string with
    /// an emoji (2 UTF-16 units, 1 Character) mis-slices when the offset is used as a Character offset.
    func test_axE_utf16OffsetSlicesEmojiStringCorrectly() {
        // "a😀b" — utf16 units: a(0) hi(1) lo(2) b(3); Characters: [a, 😀, b]
        let s = "a😀b"
        XCTAssertEqual(TextInserter.textBeforeUTF16Offset(s, 4), "a😀b", "offset at end returns whole string")
        XCTAssertEqual(TextInserter.textBeforeUTF16Offset(s, 3), "a😀", "offset after the emoji keeps the emoji")
        XCTAssertEqual(TextInserter.textBeforeUTF16Offset(s, 1), "a", "offset between 'a' and emoji")
        XCTAssertEqual(TextInserter.textBeforeUTF16Offset(s, 0), "", "offset 0 returns empty prefix")

        // The naive Character-offset slice diverges here: index(offsetBy: 3) would run to endIndex and
        // return the whole "a😀b", where the UTF-16-correct answer is "a😀".
        let naive = s.index(s.startIndex, offsetBy: 3, limitedBy: s.endIndex).map { String(s[..<$0]) }
        XCTAssertEqual(naive, "a😀b", "sanity: the buggy Character-offset slice really does diverge")
        XCTAssertNotEqual(TextInserter.textBeforeUTF16Offset(s, 3), naive, "the fix must differ from the buggy slice")
    }

    /// An offset landing INSIDE a surrogate pair must round back to the nearest Character boundary
    /// rather than crash or return nil.
    func test_axE_offsetInsideSurrogatePairRoundsSafely() {
        // offset 2 lands on the emoji's low surrogate — round back to the 'a'|'😀' boundary (offset 1).
        XCTAssertEqual(TextInserter.textBeforeUTF16Offset("a😀b", 2), "a", "mid-surrogate offset rounds down safely")
    }

    /// Plain ASCII behaves identically to a Character slice, and out-of-range returns nil.
    func test_axE_asciiAndOutOfRange() {
        XCTAssertEqual(TextInserter.textBeforeUTF16Offset("abc", 2), "ab")
        XCTAssertEqual(TextInserter.textBeforeUTF16Offset("abc", 3), "abc")
        XCTAssertNil(TextInserter.textBeforeUTF16Offset("abc", 10), "offset past the end returns nil")
    }

    // MARK: - UI-A: WelcomeController routes suggested model to the engine's slot

    func test_uiA_suggestionRoutedToParakeetSlot() {
        let controller = WelcomeController()
        controller.applySuggestion(engine: "parakeet", model: "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(controller.currentSelection.engine, "parakeet")
        XCTAssertEqual(controller.currentSelection.model, "parakeet-tdt-0.6b-v3",
                       "a parakeet suggestion must land in the parakeet slot, not the whisper slot")
    }

    func test_uiA_suggestionRoutedToWhisperSlot() {
        let controller = WelcomeController()
        controller.applySuggestion(engine: "whisper", model: "small.en")
        XCTAssertEqual(controller.currentSelection.engine, "whisper")
        XCTAssertEqual(controller.currentSelection.model, "small.en")
    }

    // MARK: - UI-B: reloadConfig Parakeet branch gates on isModelDownloaded

    func test_uiB_undownloadedParakeetModelKeepsCurrentEngine() {
        XCTAssertEqual(
            AppDelegate.parakeetReloadDecision(modelID: "parakeet-tdt-0.6b-v2", isModelDownloaded: false),
            .keepCurrent,
            "an undownloaded Parakeet model must NOT swap the live transcriber")
    }

    func test_uiB_downloadedParakeetModelRebuilds() {
        XCTAssertEqual(
            AppDelegate.parakeetReloadDecision(modelID: "parakeet-tdt-0.6b-v2", isModelDownloaded: true),
            .rebuild(modelID: "parakeet-tdt-0.6b-v2"),
            "a downloaded Parakeet model rebuilds the transcriber onto it")
    }
}
