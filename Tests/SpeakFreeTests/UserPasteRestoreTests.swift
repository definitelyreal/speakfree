// ai-suggestion:unverified · Claude · 2026-09-24 · feat/fast-clipboard (Cmd+V during the restore window)
//
// The user's own Cmd+V during a clipboard borrow restores his clipboard before the keystroke is
// delivered. Pure logic only: keystrokes are CGEvent objects that are built but NEVER posted, or
// plain field values; every pasteboard is uniquely named (never `.general`); the target app is
// played through `postPasteShortcut`; each test uses its own gate (never `.shared`).

import XCTest
import AppKit
import CoreGraphics
@testable import SpeakFreeLib

final class UserPasteRestoreTests: XCTestCase {

    private let vKey: Int64 = 9           // kVK_ANSI_V
    private let dvorakVKey: Int64 = 47    // "v" on Dvorak sits on the QWERTY "." key
    private let foreignPID: Int64 = 0     // hardware events carry no posting process

    // MARK: - Keystroke classification

    private func kind(_ flags: CGEventFlags, key: Int64 = 9, type: CGEventType = .keyDown,
                      userData: Int64 = 0, pid: Int64 = 0, repeatKey: Bool = false,
                      layout: Int64? = 9) -> PasteKeystroke.Kind {
        PasteKeystroke.classify(type: type, keyCode: key, flags: flags, userData: userData,
                                sourcePID: pid, isAutorepeat: repeatKey, layoutVKeyCode: layout,
                                ownPID: 4242)
    }

    func test_classify_plainCommandV_isUserPaste() {
        XCTAssertEqual(kind(.maskCommand), .userPaste)
        XCTAssertEqual(kind([.maskCommand, .maskAlphaShift]), .userPaste, "Caps Lock is a state, not a chord")
        XCTAssertEqual(kind([.maskCommand, .maskNonCoalesced]), .userPaste)
    }

    func test_classify_otherModifiersOrKeys_areNotPaste() {
        XCTAssertEqual(kind([.maskCommand, .maskShift]), .other, "Cmd+Shift+V is paste-and-match-style")
        XCTAssertEqual(kind([.maskCommand, .maskAlternate]), .other)
        XCTAssertEqual(kind([.maskCommand, .maskControl]), .other)
        XCTAssertEqual(kind([.maskCommand, .maskSecondaryFn]), .other)
        XCTAssertEqual(kind([]), .other, "a bare v is typing")
        XCTAssertEqual(kind(.maskControl), .other)
        XCTAssertEqual(kind(.maskCommand, key: 8), .other, "Cmd+C")
        XCTAssertEqual(kind(.maskCommand, type: .keyUp), .other)
        XCTAssertEqual(kind(.maskCommand, type: .flagsChanged), .other)
        XCTAssertEqual(kind(.maskCommand, repeatKey: true), .other)
    }

    func test_classify_layoutVKey_andAnsiV_bothCount() {
        XCTAssertEqual(kind(.maskCommand, key: dvorakVKey, layout: dvorakVKey), .userPaste)
        XCTAssertEqual(kind(.maskCommand, key: vKey, layout: dvorakVKey), .userPaste,
                       "Dvorak - QWERTY Command sends shortcuts by QWERTY position")
        XCTAssertEqual(kind(.maskCommand, key: dvorakVKey, layout: nil), .other)
    }

    func test_classify_speakfreesOwnEvents_areNeverTheUsers() {
        XCTAssertEqual(kind(.maskCommand, userData: SyntheticEventMarker.userData), .ownSynthetic)
        XCTAssertEqual(kind(.maskCommand, pid: 4242), .ownSynthetic, "posted by this process")
        XCTAssertEqual(kind(.maskCommand, pid: 777), .userPaste, "another app's synthetic Cmd+V is the user's intent")
    }

    /// The production Cmd+V factory marks its events, and the marker survives the CGEvent API
    /// the tap reads it through. Built, never posted.
    func test_productionSyntheticPaste_isMarked_andClassifiedAsOwn() throws {
        let source = CGEventSource(stateID: .privateState)
        let (down, up) = try XCTUnwrap(TextInserter.makeSyntheticPasteEvents(vKey: 9, source: source))
        XCTAssertEqual(down.getIntegerValueField(.eventSourceUserData), SyntheticEventMarker.userData)
        XCTAssertEqual(up.getIntegerValueField(.eventSourceUserData), SyntheticEventMarker.userData)
        XCTAssertEqual(PasteKeystroke.classify(down, type: .keyDown, layoutVKeyCode: 9), .ownSynthetic)

        // Same keystroke without the marker (what a physical press looks like to the tap).
        let physical = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true))
        physical.flags = .maskCommand
        physical.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertEqual(PasteKeystroke.classify(physical, type: .keyDown, layoutVKeyCode: 9), .userPaste)
    }

    // MARK: - Gate on a scratch pasteboard

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("speakfree.test.userpaste.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private func setUserClipboard(_ pb: NSPasteboard, _ text: String) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func saved(_ pb: NSPasteboard) -> UserPasteRestoreGate.SavedItems {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Arms `gate` with the user's clipboard saved and "dictation" written in its place.
    private func armBorrow(_ gate: UserPasteRestoreGate, _ pb: NSPasteboard,
                           outcomes: @escaping (UserPasteRestoreGate.Outcome) -> Void = { _ in }) -> Int {
        setUserClipboard(pb, "USER COPY")
        let items = saved(pb)
        setUserClipboard(pb, "dictation")
        return gate.arm(pasteboard: pb, savedItems: items, writtenChangeCount: pb.changeCount,
                        layoutVKeyCode: 9,
                        restore: { pb, items in TextInserter.writeBack(items, to: pb) },
                        onOutcome: outcomes)
    }

    /// Calls the gate from a background thread (the tap thread's situation) WHILE main is
    /// blocked waiting for it. If the gate ever needed main, this would time out.
    private func pressOnTapThread(_ gate: UserPasteRestoreGate, flags: CGEventFlags = .maskCommand,
                                  userData: Int64 = 0,
                                  file: StaticString = #filePath, line: UInt = #line)
        -> (UserPasteRestoreGate.Outcome?, Void) {
        var outcome: UserPasteRestoreGate.Outcome?
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            outcome = gate.handleKeyDown(type: .keyDown, keyCode: 9, flags: flags, userData: userData,
                                         sourcePID: 0, isAutorepeat: false)
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(finished, "the tap-thread call must not wait for main", file: file, line: line)
        return (outcome, ())
    }

    func test_trustedRead_userCmdV_restoresBeforeReturning_withoutMain() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markTrustedRead(token: token)

        let (outcome, _) = pressOnTapThread(gate)  // main is blocked for the whole call

        XCTAssertEqual(outcome, .restored(token: token))
        XCTAssertEqual(pb.string(forType: .string), "USER COPY",
                       "restored synchronously, before the keystroke would be delivered")
        XCTAssertFalse(gate.isWatching)
        XCTAssertFalse(gate.claim(token: token), "the owner must not restore a second time")
    }

    func test_beforeFirstRead_userCmdV_leavesTheDictation() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)

        let (outcome, _) = pressOnTapThread(gate)

        XCTAssertEqual(outcome, .skipped(token: token, reason: "before-read"))
        XCTAssertEqual(pb.string(forType: .string), "dictation", "the target has not read it yet")
        XCTAssertTrue(gate.isWatching, "a later Cmd+V after the read can still restore")
        XCTAssertTrue(gate.claim(token: token), "the normal restore still owns it")
    }

    func test_untrustedRead_userCmdV_leavesTheDictation_andSaysWhy() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markUntrustedRead(token: token, reason: "syncer:com.vmware.fusion")

        let (outcome, _) = pressOnTapThread(gate)

        XCTAssertEqual(outcome, .skipped(token: token, reason: "early-off(syncer:com.vmware.fusion)"))
        XCTAssertEqual(pb.string(forType: .string), "dictation")
    }

    func test_speakfreesOwnCmdV_neverRestores() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markTrustedRead(token: token)

        let (outcome, _) = pressOnTapThread(gate, userData: SyntheticEventMarker.userData)

        XCTAssertEqual(outcome, .ownSynthetic)
        XCTAssertEqual(pb.string(forType: .string), "dictation")
        XCTAssertTrue(gate.isWatching)
    }

    func test_cmdShiftV_neverRestores() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markTrustedRead(token: token)

        let (outcome, _) = pressOnTapThread(gate, flags: [.maskCommand, .maskShift])

        XCTAssertEqual(outcome, .notPaste)
        XCTAssertEqual(pb.string(forType: .string), "dictation")
    }

    func test_userCopiedSince_isLeftAlone() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markTrustedRead(token: token)
        setUserClipboard(pb, "NEWER COPY")

        let (outcome, _) = pressOnTapThread(gate)

        XCTAssertEqual(outcome, .clipboardChanged(token: token))
        XCTAssertEqual(pb.string(forType: .string), "NEWER COPY")
        XCTAssertTrue(gate.claim(token: token), "not restored by the tap")
    }

    func test_nothingPending_isIdle() {
        let gate = UserPasteRestoreGate()
        let (outcome, _) = pressOnTapThread(gate)
        XCTAssertEqual(outcome, .idle)
    }

    func test_claimedBorrow_isNoLongerActedOn() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markTrustedRead(token: token)
        XCTAssertTrue(gate.claim(token: nil), "a new paste takes the gate first")

        let (outcome, _) = pressOnTapThread(gate)

        XCTAssertEqual(outcome, .idle)
        XCTAssertEqual(pb.string(forType: .string), "dictation")
    }

    func test_lockHeldByMain_tapNeverWaits_andLeavesItAlone() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markTrustedRead(token: token)

        var outcome: UserPasteRestoreGate.Outcome?
        gate.excludingTapRestore {
            (outcome, _) = pressOnTapThread(gate)
        }

        XCTAssertEqual(outcome, .notPaste, "busy: skipped rather than waiting")
        XCTAssertEqual(pb.string(forType: .string), "dictation")
        XCTAssertTrue(gate.isWatching, "a later Cmd+V can still restore")
    }

    func test_watchingSignal_onWhileArmed_offAfterRestoreOrClaim() {
        let gate = UserPasteRestoreGate()
        var signals: [Bool] = []
        gate.onWatchingChanged = { signals.append($0) }
        let pb = makePasteboard()

        let first = armBorrow(gate, pb)
        XCTAssertEqual(signals, [true])
        gate.claim(token: first)
        XCTAssertEqual(signals, [true, false])

        let second = armBorrow(gate, pb)
        gate.markTrustedRead(token: second)
        _ = pressOnTapThread(gate)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(signals, [true, false, true, false])
    }

    /// Edit Mode copies may run off main: the borrow ends, and the tap-off signal arrives on main,
    /// unless a newer borrow was armed before main got to it.
    func test_writeOutsideBorrow_offMain_signalsOnMain_unlessRearmed() {
        let gate = UserPasteRestoreGate()
        var signals: [(Bool, Bool)] = []
        gate.onWatchingChanged = { signals.append(($0, Thread.isMainThread)) }
        let pb = makePasteboard()

        _ = armBorrow(gate, pb)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.writeOutsideBorrow { pb.clearContents(); pb.setString("EDIT COPY", forType: .string) }
            done.signal()
        }
        done.wait()
        XCTAssertFalse(gate.isWatching)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(signals.map(\.0), [true, false])
        XCTAssertTrue(signals.allSatisfy(\.1), "always delivered on main")

        // Re-armed before main runs the deferred signal: the tap must stay on.
        signals.removeAll()
        _ = armBorrow(gate, pb)
        let done2 = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.writeOutsideBorrow { pb.clearContents() }
            done2.signal()
        }
        done2.wait()
        _ = armBorrow(gate, pb)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(signals.map(\.0), [true, true], "the stale off signal is suppressed")
        XCTAssertTrue(gate.isWatching)
    }

    func test_skipIsReportedOncePerBorrow() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        var outcomes: [UserPasteRestoreGate.Outcome] = []
        _ = armBorrow(gate, pb) { outcomes.append($0) }
        _ = pressOnTapThread(gate)
        _ = pressOnTapThread(gate)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(outcomes.count, 1)
    }

    // MARK: - Through TextInserter (scratch pasteboard, simulated target)

    private final class Sink {
        var records: [TextInserter.ClipboardRestoreRecord] = []
        var reads: [String?] = []
    }

    private func makeInserter(pasteboard: NSPasteboard, gate: UserPasteRestoreGate, sink: Sink,
                              afterRead: TimeInterval = 0.8, backstop: TimeInterval = 1.2,
                              syncer: String? = nil,
                              target: @escaping (NSPasteboard) -> Void) -> TextInserter {
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
        inserter.clipboardTrustReason = { syncer.map { "syncer:\($0)" } }
        inserter.pasteFieldReader = nil
        inserter.postPasteShortcut = { target(pasteboard) }
        inserter.onClipboardRestore = { sink.records.append($0) }
        return inserter
    }

    /// The maintainer's pattern: copy, dictate, Cmd+V while the dictation is still on the clipboard.
    func test_dictateThenCmdV_pastesHisCopy_andRestoresExactlyOnce() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))  // the target reads during the paste
        }

        inserter.pasteViaClipboard("dictated words")
        XCTAssertEqual(sink.reads, ["dictated words"])
        XCTAssertTrue(gate.isWatching)

        let (outcome, _) = pressOnTapThread(gate)
        guard case .restored = outcome else { return XCTFail("expected a restore, got \(String(describing: outcome))") }
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY", "his Cmd+V now pastes his copy")

        RunLoop.main.run(until: Date().addingTimeInterval(1.6))  // past the after-read timer and backstop
        XCTAssertEqual(sink.records.count, 1, "restored once; the timers did not run a second restore")
        let record = sink.records.first
        XCTAssertEqual(record?.trigger, "user-paste")
        XCTAssertEqual(record?.restored, true)
        XCTAssertNotNil(record?.pasteToRead)
        XCTAssertLessThan(record?.pasteToRestore ?? 99, 0.8, "sooner than the after-read timer")
        XCTAssertEqual(record?.userPasteLogLine.hasPrefix("Clipboard restore: trigger=user-paste route=electron"), true)
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
    }

    /// His Cmd+V arrives before the target read the dictation: nothing is swapped, and the normal
    /// restore after the read still happens.
    func test_cmdVBeforeTargetRead_leavesIt_thenNormalRestore() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink, afterRead: 0.05) { _ in }

        inserter.pasteViaClipboard("dictated words")
        let (outcome, _) = pressOnTapThread(gate)
        guard case .skipped(_, "before-read") = outcome else { return XCTFail("got \(String(describing: outcome))") }

        // The target reads now (late): it still gets the dictation.
        XCTAssertEqual(pb.string(forType: .string), "dictated words")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(sink.records.map(\.trigger), ["read"])
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
    }

    /// A too-early Cmd+V is left alone, and a second one after the target's read restores.
    func test_cmdVBeforeRead_thenAfterRead_secondOneRestores() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink) { _ in }

        inserter.pasteViaClipboard("dictated words")
        guard case .skipped(_, "before-read") = pressOnTapThread(gate).0 else { return XCTFail("expected skip") }
        XCTAssertEqual(pb.string(forType: .string), "dictated words")  // the target's (late) read
        guard case .restored = pressOnTapThread(gate).0 else { return XCTFail("expected restore") }
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        XCTAssertEqual(sink.records.map(\.trigger), ["user-paste"])
    }

    /// speakfree's own post-Cmd+V read is skipped while nobody has read the promise, because
    /// that read would be served and cached, and the target's real read would then never reach
    /// the provider (no receipt for the rest of the borrow).
    func test_dictationPromiseUnread_tracksTheFirstRead() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink) { _ in }
        XCTAssertFalse(inserter.dictationPromiseUnread, "no borrow")

        inserter.pasteViaClipboard("dictated words")
        XCTAssertTrue(inserter.dictationPromiseUnread)
        XCTAssertEqual(pb.string(forType: .string), "dictated words")  // the target reads
        XCTAssertFalse(inserter.dictationPromiseUnread)
        guard case .restored = pressOnTapThread(gate).0 else { return XCTFail("the receipt was kept") }
    }

    /// A read while another app is frontmost is not the target's: the tap leaves it.
    func test_readWithOtherAppFrontmost_cmdVLeavesIt() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        var front: pid_t = 999_999
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink, backstop: 0.3) { _ in }
        inserter.frontmostPIDProvider = { front }

        inserter.pasteViaClipboard("dictated words")
        front = 123
        XCTAssertEqual(pb.string(forType: .string), "dictated words")
        guard case .skipped(_, "early-off(read-while-other-app-frontmost)") = pressOnTapThread(gate).0 else {
            return XCTFail("expected skip")
        }
        XCTAssertEqual(pb.string(forType: .string), "dictated words")
    }

    /// speakfree's other clipboard writes end the borrow: the tap can no longer restore over them.
    func test_otherSpeakfreeWrite_endsTheBorrow() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        let token = armBorrow(gate, pb)
        gate.markTrustedRead(token: token)
        gate.writeOutsideBorrow { setUserClipboard(pb, "COPIED LAST DICTATION") }

        XCTAssertEqual(pressOnTapThread(gate).0, .idle)
        XCTAssertEqual(pb.string(forType: .string), "COPIED LAST DICTATION")
    }

    /// A clipboard syncer is running: the read may not be the target's, so the tap leaves it.
    func test_syncerRunning_cmdVDoesNotRestoreEarly() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink, backstop: 0.3,
                                    syncer: "com.vmware.fusion") { pb in
            sink.reads.append(pb.string(forType: .string))
        }

        inserter.pasteViaClipboard("dictated words")
        let (outcome, _) = pressOnTapThread(gate)
        guard case .skipped(_, let reason) = outcome else { return XCTFail("got \(String(describing: outcome))") }
        XCTAssertEqual(reason, "early-off(syncer:com.vmware.fusion)")
        XCTAssertEqual(pb.string(forType: .string), "dictated words")

        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(sink.records.map(\.trigger), ["backstop"])
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
    }

    /// A second dictation starts right after the tap restored the first: it snapshots his
    /// restored copy (not the old dictation), and the late outcome does not disturb it.
    func test_nextDictationAfterTapRestore_savesHisCopy() {
        let gate = UserPasteRestoreGate()
        let pb = makePasteboard()
        setUserClipboard(pb, "HIS COPY")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, gate: gate, sink: sink, afterRead: 0.05, backstop: 0.3) { pb in
            sink.reads.append(pb.string(forType: .string))
        }

        inserter.pasteViaClipboard("first")
        _ = pressOnTapThread(gate)
        inserter.pasteViaClipboard("second")  // before the tap's outcome reaches main
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(sink.reads, ["first", "second"])
        XCTAssertEqual(pb.string(forType: .string), "HIS COPY")
        XCTAssertEqual(sink.records.map(\.trigger), ["read"], "the second borrow restored normally")
    }
}
