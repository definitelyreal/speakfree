// ai-suggestion:unverified · Claude · 2026-10-04 · fix/continuity-fast-restore
//
// Field logs from the maintainer's daily Mac, 2026-10-02..04: 137 of 137 clipboard restores ran
// on the backstop with `early=off(syncer:com.apple.ScreenContinuity)`. iPhone Mirroring's
// background process was classified as an eager clipboard syncer, which also kept the Cmd+V
// paste-watch tap from ever restoring (its one logged Cmd+V was skipped as early-off). Apple's
// Continuity readers sync through Universal Clipboard, which skips "this Mac only" writes, so
// they are trusted while every dictation write is host-only, and the canary still overrides.
//
// Every test uses a uniquely named scratch NSPasteboard (never `.general`), an in-memory trust
// store (never the real ~/.config/speakfree), and synthetic CGEvents that are built and handed
// to the gate, never posted. No real keystrokes.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class ContinuityFastRestoreTests: XCTestCase {

    /// What was running on the maintainer's Mac in the field logs (canary line `readers=`).
    private let fieldRunning: [String?] = ["com.apple.ScreenContinuity", "com.raycast.macos", "com.apple.finder", nil]

    private func reason(_ running: [String?], _ verdict: ClipboardCanaryVerdict = .none,
                        hostOnlyWrites: Bool = TextInserter.localDictationWritesAreHostOnly) -> String? {
        ClipboardTrust.untrustedReason(running: ClipboardReaderCatalog.running(in: running), verdict: verdict,
                                       hostOnlyWrites: hostOnlyWrites)
    }

    private func canaryResult(_ outcome: ClipboardCanaryResult.Outcome, readers: [String],
                              hoursAgo: Double) -> ClipboardCanaryResult {
        ClipboardCanaryResult(date: Date().addingTimeInterval(-hoursAgo * 3_600), mode: .lock, outcome: outcome,
                              readAfterMs: outcome == .read ? 120 : nil, restored: true, readers: readers,
                              note: nil, holdMs: 20_000)
    }

    // MARK: - Classification and decision

    func test_continuityReaders_matchCaseInsensitively_asHostOnlyRespecting() {
        for id in ["com.apple.ScreenContinuity", "com.apple.screencontinuity", "COM.APPLE.SCREENCONTINUITY",
                   "com.apple.universalcontrol", "com.apple.UniversalControl"] {
            XCTAssertEqual(ClipboardReaderCatalog.reader(bundleID: id)?.compliance, .respectsHostOnly, id)
            XCTAssertEqual(ClipboardReaderCatalog.cachedReader(bundleID: id)?.compliance, .respectsHostOnly, id)
        }
        // Both spellings from the field log collapse to one running reader.
        let running = ClipboardReaderCatalog.running(in: ["com.apple.ScreenContinuity", "com.apple.screencontinuity"])
        XCTAssertEqual(running.count, 1)
        // Insertion routing is unchanged: iPhone Mirroring as the TARGET still takes the remote route.
        XCTAssertTrue(AppCompatibility.isRemoteDesktop(bundleID: "com.apple.ScreenContinuity"))
    }

    func test_screenContinuityRunning_withHostOnlyWrites_allowsEarlyRestore() {
        XCTAssertTrue(TextInserter.localDictationWritesAreHostOnly)
        XCTAssertNil(reason(fieldRunning))
        XCTAssertNil(reason(["com.apple.universalcontrol", "com.apple.ScreenContinuity"]))
        // The field canary history (two clean lock runs with both readers running).
        let clean: ClipboardCanaryVerdict = .trusted(coveredReaders: ["com.apple.screencontinuity", "com.raycast.macos"])
        XCTAssertNil(reason(fieldRunning, clean))
        XCTAssertNil(reason(fieldRunning, .trusted(coveredReaders: [])))
    }

    func test_screenContinuity_isAnEagerSyncer_ifAWriteIsNotHostOnly() {
        XCTAssertEqual(reason(fieldRunning, hostOnlyWrites: false), "syncer:com.apple.ScreenContinuity")
        XCTAssertEqual(reason(["com.apple.universalcontrol"], .trusted(coveredReaders: ["com.apple.universalcontrol"]),
                              hostOnlyWrites: false), "syncer:com.apple.universalcontrol")
    }

    /// The constant the trust check reads is the one the real lazy write uses.
    func test_lazyDictationWrite_isActuallyHostOnly() {
        let pb = NSPasteboard(name: .init("speakfree.test.continuity.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        var clears: [Bool] = []
        var writer = PasteboardWriter()
        let realClear = writer.clear
        writer.clear = { pb, hostOnly in clears.append(hostOnly); return realClear(pb, hostOnly) }
        let provider = DictationPasteProvider(text: "dictated words")
        let result = TextInserter.writeLazyDictation(provider: provider, to: pb, writer: writer)
        XCTAssertNotNil(result.generation)
        XCTAssertEqual(clears, [TextInserter.localDictationWritesAreHostOnly])
        XCTAssertEqual(clears, [true])
    }

    func test_canaryCaughtReadingWithContinuityRunning_turnsEarlyOff() {
        var state = ClipboardTrustState()
        state.append(canaryResult(.clean, readers: ["com.apple.screencontinuity"], hoursAgo: 48))
        state.append(canaryResult(.read, readers: ["com.apple.screencontinuity", "com.raycast.macos"], hoursAgo: 1))
        XCTAssertEqual(state.verdict, .untrusted)
        XCTAssertEqual(reason(fieldRunning, state.verdict), "canary-read")
        let store = ClipboardTrustStore(fileURL: nil, initial: state)
        XCTAssertEqual(store.currentUntrustedReason(runningBundleIDs: fieldRunning), "canary-read")
    }

    func test_screenSharingVMsAndKVMs_stillTurnEarlyOff_evenWithContinuityRunning() {
        let clean: ClipboardCanaryVerdict = .trusted(coveredReaders: [
            "com.apple.screencontinuity", "com.apple.screensharing", "com.vmware.fusion", "com.symless.synergy"])
        XCTAssertEqual(reason(["com.apple.ScreenContinuity", "com.apple.ScreenSharing"], clean),
                       "syncer:com.apple.ScreenSharing")
        XCTAssertEqual(reason(["com.apple.ScreenSharing", "com.apple.ScreenContinuity"]), "syncer:com.apple.ScreenSharing")
        XCTAssertEqual(reason(["com.apple.screensharing"]), "syncer:com.apple.screensharing")
        XCTAssertEqual(reason(["com.apple.ScreenContinuity", "com.vmware.fusion"], clean), "syncer:com.vmware.fusion")
        XCTAssertEqual(reason(["com.apple.ScreenContinuity", "com.symless.synergy"], clean), "syncer:com.symless.synergy")
        XCTAssertEqual(reason(["com.apple.ScreenContinuity", "com.p5sys.jump.mac.viewer"]),
                       "syncer:com.p5sys.jump.mac.viewer")
    }

    func test_diagnosticSaysFastRestoreOn_withContinuityRunning() {
        let text = ClipboardTrust.diagnosticText(running: ClipboardReaderCatalog.running(in: fieldRunning),
                                                 state: ClipboardTrustState())
        XCTAssertTrue(text.contains("iPhone Mirroring (com.apple.ScreenContinuity): respects this-Mac-only"), text)
        XCTAssertTrue(text.contains("- Fast clipboard restore on first read: on"), text)
    }

    // MARK: - Through TextInserter and the Cmd+V gate (scratch pasteboard, simulated target)

    private final class Sink {
        var records: [TextInserter.ClipboardRestoreRecord] = []
    }

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("speakfree.test.continuity.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private func setUserClipboard(_ pb: NSPasteboard, _ text: String) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// The production trust check (an in-memory store with the given canary history) against the
    /// given running apps, on an Electron-class target that reads during the paste.
    private func makeInserter(pasteboard: NSPasteboard, gate: UserPasteRestoreGate, sink: Sink,
                              running: [String?], state: ClipboardTrustState = ClipboardTrustState(),
                              afterRead: TimeInterval = 0.6, backstop: TimeInterval = 1.0) -> TextInserter {
        let store = ClipboardTrustStore(fileURL: nil, initial: state)
        let inserter = TextInserter()
        inserter.pasteboard = pasteboard
        inserter.userPasteGate = gate
        inserter.layoutVKeyCodeProvider = { 9 }
        inserter.frontmostBundleIDProvider = { "com.microsoft.VSCode" }
        inserter.frontmostBundleURLProvider = { nil }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.executeAppleScript = { _ in XCTFail("Unexpected AppleScript"); return nil }
        inserter.restoreTiming = { route in
            TextInserter.ClipboardRestoreTiming(backstop: backstop, afterRead: route == .remote ? nil : afterRead)
        }
        inserter.clipboardTrustReason = { store.currentUntrustedReason(runningBundleIDs: running) }
        inserter.pasteFieldReader = nil
        inserter.postPasteShortcut = { _ = pasteboard.string(forType: .string) }  // the target reads
        inserter.onClipboardRestore = { sink.records.append($0) }
        return inserter
    }

    /// A physical-looking Cmd+V keyDown: built, never posted.
    private func syntheticUserCmdV(flags: CGEventFlags = .maskCommand) throws -> CGEvent {
        let source = CGEventSource(stateID: .privateState)
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true))
        event.flags = flags
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    /// Hands the event to the gate from a background thread (the tap thread's situation).
    private func deliverOnTapThread(_ gate: UserPasteRestoreGate, _ event: CGEvent) -> UserPasteRestoreGate.Outcome? {
        var outcome: UserPasteRestoreGate.Outcome?
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            outcome = gate.handleKeyDown(event, type: .keyDown)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "the tap-thread call must not wait for main")
        return outcome
    }

    func test_continuityRunning_restoresOnTheFirstRead() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink, running: fieldRunning, afterRead: 0.05)

        inserter.pasteViaClipboard("dictated words")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(sink.records.map(\.trigger), ["read"])
        XCTAssertNil(sink.records.first?.earlyOffReason)
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
        if let line = sink.records.first?.logLine {
            XCTAssertFalse(line.contains("early=off"), line)
            XCTAssertNotEqual(UpdateLogEvent.classify("[00:00:00] " + line), .unsupported, line)
        }
    }

    /// The maintainer's pattern with iPhone Mirroring running: copy, dictate, Cmd+V. His Cmd+V
    /// (a synthetic event through the tap's own entry point) pastes his copy, restored once.
    func test_continuityRunning_syntheticCmdV_restoresHisCopy() throws {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink, running: fieldRunning)

        inserter.pasteViaClipboard("dictated words")
        XCTAssertTrue(gate.isWatching)
        // Cmd+Shift+V is a different shortcut and is left alone.
        XCTAssertEqual(deliverOnTapThread(gate, try syntheticUserCmdV(flags: [.maskCommand, .maskShift])), .notPaste)
        guard case .restored = deliverOnTapThread(gate, try syntheticUserCmdV()) else {
            return XCTFail("expected the tap to restore his clipboard")
        }
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")

        RunLoop.main.run(until: Date().addingTimeInterval(1.4))  // past both timers
        XCTAssertEqual(sink.records.map(\.trigger), ["user-paste"], "restored once")
        XCTAssertNil(sink.records.first?.earlyOffReason)
        let line = sink.records.first?.userPasteLogLine ?? ""
        XCTAssertTrue(line.hasPrefix("Clipboard restore: trigger=user-paste route=electron"), line)
        XCTAssertEqual(UpdateLogEvent.classify("[00:00:00] " + line), .unrelated, line)
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
    }

    func test_canaryCaught_syntheticCmdV_leavesTheDictation_backstopRestores() throws {
        var state = ClipboardTrustState()
        state.append(canaryResult(.read, readers: ["com.apple.screencontinuity"], hoursAgo: 1))
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink, running: fieldRunning,
                                    state: state, backstop: 0.3)

        inserter.pasteViaClipboard("dictated words")
        guard case .skipped(_, "early-off(canary-read)") = deliverOnTapThread(gate, try syntheticUserCmdV()) else {
            return XCTFail("expected an early-off skip")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(sink.records.map(\.trigger), ["backstop"])
        XCTAssertEqual(sink.records.first?.earlyOffReason, "canary-read")
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
    }

    func test_screenSharingRunning_syntheticCmdV_leavesTheDictation_backstopRestores() throws {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink,
                                    running: ["com.apple.ScreenContinuity", "com.apple.ScreenSharing"], backstop: 0.3)

        inserter.pasteViaClipboard("dictated words")
        guard case .skipped(_, "early-off(syncer:com.apple.ScreenSharing)") =
                deliverOnTapThread(gate, try syntheticUserCmdV()) else {
            return XCTFail("expected an early-off skip")
        }
        XCTAssertEqual(pb.string(forType: .string), "dictated words")
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(sink.records.map(\.trigger), ["backstop"])
        XCTAssertEqual(sink.records.first?.earlyOffReason, "syncer:com.apple.ScreenSharing")
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
    }
}
