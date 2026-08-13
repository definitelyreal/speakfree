// Claude · 2026-07-28 · Session: 6277a78f-7ff9-4d99-b9d1-f9ee9afe952a
//
// Claude for Desktop silently dropped every dictation: it is Electron, but was absent from the
// hand-maintained `clipboardPasteApps` set, so insertion fell through to `insertViaAccessibility`,
// whose `AXUIElementSetAttributeValue` returned .success into a contenteditable that rendered
// nothing. Two defenses are pinned here:
//
//   1. Generic detection — probe the live bundle for an embedded Chromium runtime instead of
//      relying on someone remembering to add each new Electron app to a list.
//   2. Read-back verification — a reported success is confirmed against the field's character
//      count, because `AXSelectedText settable` is true in Claude, Signal AND VS Code alike
//      (measured 2026-07-28) and therefore predicts nothing.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class ElectronDetectionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree.electron.\(UUID().uuidString)")
        TextInserter.resetChromiumProbeCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        TextInserter.resetChromiumProbeCache()
        super.tearDown()
    }

    /// Build a synthetic .app that ships `frameworkName`, so bundle probing is tested without
    /// depending on which real apps happen to be installed on the machine running the suite.
    private func makeBundle(named appName: String, framework frameworkName: String?) -> URL {
        let app = tempDir.appendingPathComponent("\(appName).app")
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        try? FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        if let frameworkName {
            try? FileManager.default.createDirectory(
                at: frameworks.appendingPathComponent(frameworkName), withIntermediateDirectories: true)
        }
        return app
    }

    // MARK: - Generic Electron / CEF detection

    func test_electronBundleIsDetected() {
        let bundle = makeBundle(named: "SomeNewChatApp", framework: "Electron Framework.framework")
        XCTAssertTrue(TextInserter.bundleEmbedsChromium(at: bundle))
    }

    func test_chromiumEmbeddedFrameworkIsDetected() {
        let bundle = makeBundle(named: "CEFApp", framework: "Chromium Embedded Framework.framework")
        XCTAssertTrue(TextInserter.bundleEmbedsChromium(at: bundle))
    }

    func test_nativeBundleIsNotDetected() {
        let bundle = makeBundle(named: "NativeApp", framework: "Sparkle.framework")
        XCTAssertFalse(TextInserter.bundleEmbedsChromium(at: bundle))
    }

    func test_bundleWithNoFrameworksDirIsNotDetected() {
        let bundle = makeBundle(named: "BareApp", framework: nil)
        XCTAssertFalse(TextInserter.bundleEmbedsChromium(at: bundle))
    }

    /// The regression that started this: an Electron app nobody added to the list must still be
    /// routed to clipboard paste on first contact.
    func test_unlistedElectronAppIsCaughtByProbe() {
        let bundle = makeBundle(named: "TotallyNewApp", framework: "Electron Framework.framework")
        XCTAssertFalse(TextInserter.prefersClipboardPaste(bundleID: "com.example.totallynew"),
                       "precondition: not in the hand-maintained list")
        XCTAssertTrue(TextInserter.isChromiumEmbedded(bundleID: "com.example.totallynew",
                                                      bundleURL: bundle))
    }

    func test_probeResultIsCachedPerBundleID() {
        let bundle = makeBundle(named: "CachedApp", framework: "Electron Framework.framework")
        XCTAssertTrue(TextInserter.isChromiumEmbedded(bundleID: "com.example.cached", bundleURL: bundle))
        // Delete the bundle: a cached true must survive, proving the probe is not re-stat'd.
        try? FileManager.default.removeItem(at: bundle)
        XCTAssertTrue(TextInserter.isChromiumEmbedded(bundleID: "com.example.cached", bundleURL: bundle))
    }

    func test_missingBundleURLIsNotElectron() {
        XCTAssertFalse(TextInserter.isChromiumEmbedded(bundleID: "com.example.nourl", bundleURL: nil))
    }

    // MARK: - Read-back verification of a "successful" AX write

    /// The Claude failure: field held 17 chars, we inserted 42, field still held 17.
    func test_fieldThatDidNotGrow_isDetectedAsDropped() {
        XCTAssertEqual(
            TextInserter.verifyInsertion(charsBefore: 17, charsAfter: 17,
                                         selectionLengthBefore: 0, insertedCount: 42),
            .didNotLand)
    }

    func test_fieldThatGrew_isLanded() {
        XCTAssertEqual(
            TextInserter.verifyInsertion(charsBefore: 17, charsAfter: 59,
                                         selectionLengthBefore: 0, insertedCount: 42),
            .landed)
    }

    /// A blind field must never be accused — this is the honest "can't see" outcome, and it is
    /// what keeps the verifier from firing on fields that expose no character count.
    func test_unreadableFieldIsInconclusive() {
        XCTAssertEqual(
            TextInserter.verifyInsertion(charsBefore: nil, charsAfter: nil,
                                         selectionLengthBefore: 0, insertedCount: 42),
            .inconclusive)
        XCTAssertEqual(
            TextInserter.verifyInsertion(charsBefore: 17, charsAfter: nil,
                                         selectionLengthBefore: 0, insertedCount: 42),
            .inconclusive)
    }

    /// THE false-positive guard. Replacing a 42-char selection with 42 chars leaves the count
    /// unchanged even though the write worked. Without this, dictation-over-a-selection would be
    /// declared dropped every time.
    func test_replacedSelectionOfEqualLengthIsInconclusive_notDropped() {
        XCTAssertEqual(
            TextInserter.verifyInsertion(charsBefore: 100, charsAfter: 100,
                                         selectionLengthBefore: 42, insertedCount: 42),
            .inconclusive)
    }

    func test_unknownSelectionLengthIsInconclusive() {
        XCTAssertEqual(
            TextInserter.verifyInsertion(charsBefore: 100, charsAfter: 100,
                                         selectionLengthBefore: nil, insertedCount: 42),
            .inconclusive)
    }

    func test_emptyInsertionIsInconclusive() {
        XCTAssertEqual(
            TextInserter.verifyInsertion(charsBefore: 17, charsAfter: 17,
                                         selectionLengthBefore: 0, insertedCount: 0),
            .inconclusive)
    }

    // MARK: - Verdict → outcome routing (2026-08-12 Chrome silent-drop bug)
    //
    // The bug: a web contenteditable (Chrome) accepted the AX SelectedText write, reported success,
    // applied nothing, and the field verifiably did not grow. The verdict `.didNotLand` was mapped
    // to `.concealClipboard`, which copies WITHOUT pasting — so the text landed on the clipboard and
    // never on the page. Correct mapping: a provable non-insertion must PASTE, distinct from the
    // genuine 0.5s-cap timeout (which "may have committed" and must stay conceal-only, no duplicate).

    /// THE fix, as a mutation test: field-did-not-grow must route to PASTE, never conceal.
    func test_didNotLand_routesToPaste_notConceal() {
        XCTAssertEqual(TextInserter.outcomeForVerification(.didNotLand), .retryViaPaste)
        XCTAssertNotEqual(TextInserter.outcomeForVerification(.didNotLand), .concealClipboard,
                          "provable non-insertion must paste, not conceal-without-paste (the Chrome bug)")
    }

    /// A field that grew, and the honest can't-see field, are both treated as success — never retried.
    func test_landedAndInconclusive_areInserted() {
        XCTAssertEqual(TextInserter.outcomeForVerification(.landed), .inserted)
        XCTAssertEqual(TextInserter.outcomeForVerification(.inconclusive), .inserted)
    }

    /// The two AX-failure signals must stay DISTINCT: provable-drop (paste) vs may-have-committed
    /// timeout (conceal). Collapsing them either re-drops Chrome (conceal) or duplicates on timeout.
    func test_retryViaPaste_isDistinctFrom_concealClipboard() {
        XCTAssertNotEqual(TextInserter.AXSetOutcome.retryViaPaste, .concealClipboard)
    }

    /// The genuine-timeout guard is PRESERVED: a 0.5s-cap `.cannotComplete` still conceals (may have
    /// committed), and is NOT rerouted to the new paste path — that would risk a double insertion.
    func test_cannotCompleteTimeout_stillConceals_notPaste() {
        XCTAssertEqual(TextInserter.axSetOutcome(.cannotComplete), .concealClipboard)
        XCTAssertNotEqual(TextInserter.axSetOutcome(.cannotComplete), .retryViaPaste)
    }

    // MARK: - Browsers route to clipboard paste (proactive fix)
    //
    // Chrome/Safari/etc. web content drops AX writes the same way, and Chrome is not caught by the
    // embedded-Chromium probe (it ships "Google Chrome Framework", not the frameworks the probe
    // looks for). So a known browser bundle must prefer clipboard paste up front.

    func test_knownBrowsers_areRoutedToClipboardPaste() {
        for bundle in ["com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
                       "company.thebrowser.browser", "com.brave.browser", "com.microsoft.edgemac",
                       "com.operasoftware.opera", "com.vivaldi.vivaldi", "com.kagi.kagimacos"] {
            XCTAssertTrue(TextInserter.isBrowser(bundleID: bundle),
                          "\(bundle) should be recognised as a browser and prefer clipboard paste")
        }
    }

    func test_browserMatchIsCaseInsensitive() {
        XCTAssertTrue(TextInserter.isBrowser(bundleID: "COM.GOOGLE.CHROME"))
    }

    func test_nonBrowsersAreNotRoutedByBrowserRule() {
        for bundle in ["com.apple.finder", "com.example.totallynew", "com.anthropic.claudefordesktop"] {
            XCTAssertFalse(TextInserter.isBrowser(bundleID: bundle),
                           "\(bundle) is not a browser")
        }
    }
}
