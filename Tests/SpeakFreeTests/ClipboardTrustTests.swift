// ai-suggestion:unverified · Claude · 2026-09-25 · feat/fast-clipboard
//
// Clipboard trust (table + canary) and the Accessibility outcome check. Every test uses a
// uniquely named scratch NSPasteboard (never `.general`), an in-memory trust store (never the
// real ~/.config/speakfree), fake clocks/input, and a fake AX reader. No real keystrokes.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class ClipboardTrustTests: XCTestCase {

    // MARK: - Helpers

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("speakfree.test.cliptrust.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private let typeA = NSPasteboard.PasteboardType("com.example.private-a")
    private let typeB = NSPasteboard.PasteboardType("com.example.private-b")

    /// Two items, several types each, including binary data.
    private func writeRichClipboard(_ pb: NSPasteboard) -> [[(String, Data)]] {
        pb.clearContents()
        let first = NSPasteboardItem()
        first.setString("first plain", forType: .string)
        first.setData(Data("<b>first</b>".utf8), forType: .html)
        first.setData(Data([0x00, 0xFF, 0x10, 0x20]), forType: typeA)
        let second = NSPasteboardItem()
        second.setString("second plain", forType: .string)
        second.setData(Data([0x01, 0x02, 0x03]), forType: typeB)
        pb.writeObjects([first, second])
        return dump(pb)
    }

    private func dump(_ pb: NSPasteboard) -> [[(String, Data)]] {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } }
        }
    }

    private func assertSameClipboard(_ lhs: [[(String, Data)]], _ rhs: [[(String, Data)]],
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, "item count", file: file, line: line)
        for (a, b) in zip(lhs, rhs) {
            XCTAssertEqual(a.map(\.0), b.map(\.0), "types", file: file, line: line)
            XCTAssertEqual(a.map(\.1), b.map(\.1), "data", file: file, line: line)
        }
    }

    private final class FakeClock {
        var uptime: TimeInterval = 1000
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        /// Uptime of the last user input.
        var lastInputAt: TimeInterval = 0
        var busy = false
        /// What the login session reports (lock mode requires true).
        var locked = true
        var running: [String?] = ["com.raycast.macos", "com.apple.finder"]
    }

    private func makeCanary(_ pb: NSPasteboard, store: ClipboardTrustStore, clock: FakeClock,
                            hold: TimeInterval = 0.3) -> ClipboardCanary {
        var env = ClipboardCanary.Environment(pasteboard: pb, store: store)
        env.now = { clock.date }
        env.uptime = { clock.uptime }
        env.secondsSinceUserInput = { clock.uptime - clock.lastInputAt }
        env.runningBundleIDs = { clock.running }
        env.isBusy = { clock.busy }
        env.holdOverride = hold
        env.pasteGate = nil
        env.isScreenLocked = { clock.locked }
        env.inputPollInterval = 0.02
        env.writeGate = { $0() }
        env.quietClipboardInterval = 0
        return ClipboardCanary(environment: env)
    }

    private func waitForCanary(_ canary: ClipboardCanary, timeout: TimeInterval = 3) -> ClipboardCanaryResult? {
        var result: ClipboardCanaryResult?
        let exp = expectation(description: "canary finished")
        canary.onFinish = { result = $0; exp.fulfill() }
        wait(for: [exp], timeout: timeout)
        canary.onFinish = nil
        return result
    }

    // MARK: - Canary: restore

    func test_canary_noReader_isClean_andRestoresMultiItemMultiTypeClipboardExactly() {
        let pb = makePasteboard()
        let original = writeRichClipboard(pb)
        let store = ClipboardTrustStore(fileURL: nil)
        let clock = FakeClock()
        let canary = makeCanary(pb, store: store, clock: clock)

        XCTAssertEqual(canary.startIfDue(mode: .lock), .started)
        // While it runs, the clipboard holds the canary, marked exactly like a dictation.
        let types = pb.types ?? []
        for marker in DictationPasteProvider.markerTypes { XCTAssertTrue(types.contains(marker)) }
        XCTAssertTrue(canary.isRunning)

        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertEqual(result.outcome, .clean)
        XCTAssertTrue(result.restored)
        XCTAssertNil(result.readAfterMs)
        XCTAssertEqual(result.readers, ["com.raycast.macos"])
        assertSameClipboard(dump(pb), original)
        XCTAssertEqual(store.state.results, [result])
        XCTAssertEqual(store.state.verdict, .trusted(coveredReaders: []), "one clean run vouches for nobody yet")
    }

    func test_canary_emptyClipboard_isRestoredEmpty() {
        let pb = makePasteboard()
        pb.clearContents()
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock())
        canary.startIfDue(mode: .lock)
        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertTrue(result.restored)
        XCTAssertEqual(pb.pasteboardItems?.count ?? 0, 0)
    }

    func test_canary_managerThatReads_isRecordedAsRead_andTurnsFastRestoreOff() {
        let pb = makePasteboard()
        let original = writeRichClipboard(pb)
        let store = ClipboardTrustStore(fileURL: nil)
        let clock = FakeClock()
        let canary = makeCanary(pb, store: store, clock: clock)
        canary.startIfDue(mode: .lock)
        var seen: String?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            clock.uptime += 0.012
            seen = pb.string(forType: .string)  // a poller that ignores the markers
        }

        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertEqual(seen, ClipboardCanary.canaryText)
        XCTAssertEqual(result.outcome, .read)
        XCTAssertEqual(result.readAfterMs, 12)
        XCTAssertTrue(result.restored)
        assertSameClipboard(dump(pb), original)
        XCTAssertEqual(store.state.verdict, .untrusted)
        // The canary overrides the table: Raycast respects the markers, yet the fast path is off.
        XCTAssertEqual(ClipboardTrust.untrustedReason(
            running: ClipboardReaderCatalog.running(in: ["com.raycast.macos"]), verdict: store.state.verdict),
            "canary-read")
    }

    func test_canary_managerThatChecksTypesOnly_isClean() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock())
        canary.startIfDue(mode: .lock)
        var sawMarkers = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // A compliant manager: sees a marker in the type list and skips the item.
            sawMarkers = (pb.types ?? []).contains(DictationPasteProvider.markerTypes[0])
        }
        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertTrue(sawMarkers)
        XCTAssertEqual(result.outcome, .clean)
    }

    func test_canary_userCopiesDuringRun_isNeverOverwritten() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let store = ClipboardTrustStore(fileURL: nil)
        let canary = makeCanary(pb, store: store, clock: FakeClock())
        canary.startIfDue(mode: .lock)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pb.clearContents()
            pb.setString("USER NEW COPY", forType: .string)
        }
        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertFalse(result.restored)
        XCTAssertEqual(result.outcome, .inconclusive)
        XCTAssertEqual(result.note, "clipboard-changed")
        XCTAssertEqual(pb.string(forType: .string), "USER NEW COPY")
        XCTAssertEqual(store.state.verdict, .none, "an inconclusive run decides nothing")
    }

    // MARK: - Canary: scheduling

    func test_lockThenUnlock_startsOnLock_endsAtOnceOnUnlock_restoring() {
        let pb = makePasteboard()
        let original = writeRichClipboard(pb)
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock(), hold: 5)
        let scheduler = ClipboardCanaryScheduler(canary: canary)
        scheduler.lockDelay = 0.01

        scheduler.screenDidLock()
        spin(0.1)
        XCTAssertTrue(canary.isRunning, "a lock starts the canary")
        var result: ClipboardCanaryResult?
        canary.onFinish = { result = $0 }
        scheduler.screenDidUnlock()

        XCTAssertFalse(canary.isRunning, "unlock ends it synchronously, before the user can paste")
        XCTAssertEqual(result?.outcome, .inconclusive)
        XCTAssertEqual(result?.note, "unlocked")
        XCTAssertEqual(result?.restored, true)
        assertSameClipboard(dump(pb), original)
    }

    func test_unlockBeforeLockDelay_neverStarts() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock())
        let scheduler = ClipboardCanaryScheduler(canary: canary)
        scheduler.lockDelay = 0.1
        scheduler.screenDidLock()
        scheduler.screenDidUnlock()
        spin(0.2)
        XCTAssertFalse(canary.isRunning)
    }

    func test_readBeforeUnlock_stillCountsAsRead() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let store = ClipboardTrustStore(fileURL: nil)
        let canary = makeCanary(pb, store: store, clock: FakeClock(), hold: 5)
        canary.startIfDue(mode: .lock)
        _ = pb.string(forType: .string)
        var result: ClipboardCanaryResult?
        canary.onFinish = { result = $0 }
        canary.screenUnlocked()
        XCTAssertEqual(result?.outcome, .read)
        XCTAssertEqual(store.state.verdict, .untrusted)
    }

    func test_atMostOncePerDay_andNeverWhileBusy() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let store = ClipboardTrustStore(fileURL: nil)
        let clock = FakeClock()
        let canary = makeCanary(pb, store: store, clock: clock, hold: 0.05)

        clock.busy = true
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("busy"))
        XCTAssertNil(store.state.lastAttemptAt, "a skipped run is not an attempt")
        clock.busy = false
        XCTAssertEqual(canary.startIfDue(mode: .lock), .started)
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("running"))
        _ = waitForCanary(canary)
        clock.date += 23 * 3600
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("ran-today"))
        clock.date += 1 * 3600 + 1
        XCTAssertEqual(canary.startIfDue(mode: .lock), .started)
        _ = waitForCanary(canary)
    }

    func test_idleMode_requiresIdle_andUserReturnEndsRunAtOnce() {
        let pb = makePasteboard()
        let original = writeRichClipboard(pb)
        let clock = FakeClock()
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: clock, hold: 5)

        clock.lastInputAt = clock.uptime - 60
        XCTAssertEqual(canary.startIfDue(mode: .idle), .skipped("not-idle"))
        clock.lastInputAt = clock.uptime - ClipboardCanary.idleThreshold - 1
        XCTAssertEqual(canary.startIfDue(mode: .idle), .started)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            clock.uptime += 0.5
            clock.lastInputAt = clock.uptime  // the user pressed Command
        }
        let started = Date()
        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "ended by input, not the 5 s hold")
        XCTAssertEqual(result.outcome, .inconclusive)
        XCTAssertEqual(result.note, "user-returned")
        assertSameClipboard(dump(pb), original)
    }

    func test_idleMode_readAfterUserReturned_doesNotCount() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let clock = FakeClock()
        clock.lastInputAt = clock.uptime - ClipboardCanary.idleThreshold - 1
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: clock, hold: 5)
        canary.env.inputPollInterval = 10  // keep the poll from ending it first
        canary.startIfDue(mode: .idle)
        clock.uptime += 1
        clock.lastInputAt = clock.uptime  // user came back
        clock.uptime += 0.1
        _ = pb.string(forType: .string)  // ... and pasted
        var result: ClipboardCanaryResult?
        canary.onFinish = { result = $0 }
        canary.abort(reason: "test")
        XCTAssertEqual(result?.outcome, .inconclusive, "maybe the user's own paste")
    }

    /// A clipboard borrow starting mid-canary gives the canary's clipboard back first, so the
    /// user's real clipboard (never the canary) is what the paste saves and restores.
    func test_pasteDuringCanary_abortsIt_andSavesTheUsersClipboardNotTheCanary() {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER ORIGINAL", forType: .string)
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock(), hold: 5)
        canary.startIfDue(mode: .lock)

        let inserter = makeInserter(pasteboard: pb) { pb in _ = pb.string(forType: .string) }
        inserter.clipboardCanary = canary
        var records: [TextInserter.ClipboardRestoreRecord] = []
        let exp = expectation(description: "restore")
        inserter.onClipboardRestore = { records.append($0); exp.fulfill() }
        inserter.pasteViaClipboard("dictated words")
        XCTAssertFalse(canary.isRunning)
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    func test_defaultInputClockIsReadable() {
        let env = ClipboardCanary.Environment(pasteboard: makePasteboard(), store: ClipboardTrustStore(fileURL: nil))
        XCTAssertGreaterThanOrEqual(env.secondsSinceUserInput(), 0)
        _ = env.isScreenLocked()  // the real session query runs without crashing (value depends on the machine)
    }

    // MARK: - Table and decision

    func test_table_isSortedThreeWays() {
        let respects = ClipboardReaderCatalog.sorted(.respectsMarkers).map(\.bundleID)
        let ignores = ClipboardReaderCatalog.sorted(.ignoresMarkers).map(\.bundleID)
        let unknown = ClipboardReaderCatalog.sorted(.unknown).map(\.bundleID)
        for id in ["org.p0deje.Maccy", "com.clipy-app.Clipy", "com.raycast.macos"] {
            XCTAssertTrue(respects.contains(id), id)
        }
        // Documented as not storing marked items, but whether they READ first is unmeasured.
        for id in ["com.runningwithcrayons.Alfred", "com.wiheads.paste"] {
            XCTAssertTrue(unknown.contains(id), id)
        }
        XCTAssertTrue(ignores.contains("com.vmware.fusion"))
        XCTAssertTrue(unknown.contains("com.tapbots.Pastebot2Mac"))
        XCTAssertEqual(Set(respects).intersection(ignores), [])
        XCTAssertEqual(Set(respects).intersection(unknown), [])
        XCTAssertEqual(ClipboardReaderCatalog.all.count, respects.count + ignores.count + unknown.count)
        XCTAssertEqual(ClipboardReaderCatalog.reader(bundleID: "COM.RAYCAST.MACOS")?.compliance, .respectsMarkers)
        XCTAssertNil(ClipboardReaderCatalog.reader(bundleID: "com.apple.finder"))
    }

    func test_decision_tableThenCanaryOverride() {
        let respecting = ClipboardReaderCatalog.running(in: ["com.raycast.macos", "com.clipy-app.Clipy"])
        let withUnknown = ClipboardReaderCatalog.running(in: ["com.raycast.macos", "com.tapbots.Pastebot2Mac"])
        let withSyncer = ClipboardReaderCatalog.running(in: ["com.vmware.fusion"])
        XCTAssertNil(ClipboardTrust.untrustedReason(running: [], verdict: .none))
        XCTAssertNil(ClipboardTrust.untrustedReason(running: respecting, verdict: .none))
        XCTAssertEqual(ClipboardTrust.untrustedReason(running: withUnknown, verdict: .none),
                       "unknown-reader:com.tapbots.Pastebot2Mac")
        XCTAssertEqual(ClipboardTrust.untrustedReason(running: withSyncer, verdict: .none), "syncer:com.vmware.fusion")
        // A clean canary with the unknown manager running vouches for it...
        XCTAssertNil(ClipboardTrust.untrustedReason(
            running: withUnknown, verdict: .trusted(coveredReaders: ["com.tapbots.pastebot2mac"])))
        // ...but not for one that appeared after it.
        XCTAssertEqual(ClipboardTrust.untrustedReason(
            running: withUnknown, verdict: .trusted(coveredReaders: [])), "unknown-reader:com.tapbots.Pastebot2Mac")
        XCTAssertEqual(ClipboardTrust.untrustedReason(running: respecting, verdict: .untrusted), "canary-read")
        // Clean runs never vouch for an eager syncer (a suspended VM reads nothing while locked).
        XCTAssertEqual(ClipboardTrust.untrustedReason(
            running: withSyncer, verdict: .trusted(coveredReaders: ["com.vmware.fusion"])), "syncer:com.vmware.fusion")
    }

    func test_verdict_readNeedsThreeCleanRunsToRecover_coverageNeedsTwoRecentCleanRuns() {
        func result(_ outcome: ClipboardCanaryResult.Outcome, daysAgo: Double = 0,
                    holdMs: Int = 20_000) -> ClipboardCanaryResult {
            ClipboardCanaryResult(date: Date().addingTimeInterval(-daysAgo * 86_400), mode: .lock, outcome: outcome,
                                  readAfterMs: nil, restored: true, readers: ["com.raycast.macos"], note: nil,
                                  holdMs: holdMs)
        }
        var short = ClipboardTrustState()
        short.append(result(.clean, holdMs: 2_000)); short.append(result(.clean, holdMs: 2_000))
        XCTAssertEqual(short.verdict, .trusted(coveredReaders: []), "short holds never vouch")
        var legacy = ClipboardTrustState()
        legacy.append(ClipboardCanaryResult(date: Date(), mode: .lock, outcome: .clean, readAfterMs: nil,
                                            restored: true, readers: ["com.raycast.macos"], note: nil))
        legacy.append(legacy.results[0])
        XCTAssertEqual(legacy.verdict, .trusted(coveredReaders: []), "results without a hold length never vouch")
        var state = ClipboardTrustState()
        XCTAssertEqual(state.verdict, .none)
        state.append(result(.inconclusive))
        XCTAssertEqual(state.verdict, .none)
        state.append(result(.clean))
        XCTAssertEqual(state.verdict, .trusted(coveredReaders: []), "one clean run covers nobody")
        state.append(result(.clean))
        XCTAssertEqual(state.verdict, .trusted(coveredReaders: ["com.raycast.macos"]))
        state.append(result(.read))
        XCTAssertEqual(state.verdict, .untrusted)
        state.append(result(.clean)); state.append(result(.inconclusive)); state.append(result(.clean))
        XCTAssertEqual(state.verdict, .untrusted)
        state.append(result(.clean))
        XCTAssertEqual(state.verdict, .trusted(coveredReaders: ["com.raycast.macos"]))
        for _ in 0..<30 { state.append(result(.clean)) }
        XCTAssertEqual(state.results.count, ClipboardTrustState.maxResults)

        var old = ClipboardTrustState()
        old.append(result(.clean, daysAgo: 40)); old.append(result(.clean, daysAgo: 35))
        XCTAssertEqual(old.verdict, .trusted(coveredReaders: []), "coverage expires")
    }

    func test_append_dropsInconclusiveBeforeARead() {
        func result(_ outcome: ClipboardCanaryResult.Outcome) -> ClipboardCanaryResult {
            ClipboardCanaryResult(date: Date(), mode: .lock, outcome: outcome, readAfterMs: nil,
                                  restored: true, readers: [], note: nil)
        }
        var state = ClipboardTrustState()
        state.append(result(.read))
        for _ in 0..<40 { state.append(result(.inconclusive)) }
        XCTAssertEqual(state.results.count, ClipboardTrustState.maxResults)
        XCTAssertEqual(state.verdict, .untrusted, "the read is never pushed out by runs that decided nothing")
    }

    func test_store_roundTripsThroughItsOwnFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-cliptrust-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clipboard-trust.json")
        let store = ClipboardTrustStore(fileURL: url)
        let result = ClipboardCanaryResult(date: Date(timeIntervalSince1970: 1_800_000_000), mode: .idle,
                                           outcome: .read, readAfterMs: 7, restored: true,
                                           readers: [], note: nil)
        store.update { $0.append(result); $0.lastAttemptAt = result.date }
        let reloaded = ClipboardTrustStore(fileURL: url)
        XCTAssertEqual(reloaded.state, store.state)
        XCTAssertEqual(reloaded.state.verdict, .untrusted)
    }

    func test_sharedStore_underTest_neverResolvesTheRealConfigDir() {
        if Config.configDirOverride == nil {
            XCTAssertNil(ClipboardTrustStore.defaultFileURL())
        }
    }

    func test_diagnostic_listsReadersAndCanary_withNoClipboardContent() {
        var state = ClipboardTrustState()
        state.append(ClipboardCanaryResult(date: Date(timeIntervalSince1970: 1_800_000_000), mode: .lock,
                                           outcome: .read, readAfterMs: 12, restored: true,
                                           readers: ["com.tapbots.pastebot2mac"], note: nil))
        let text = ClipboardTrust.diagnosticText(
            running: ClipboardReaderCatalog.running(in: ["com.tapbots.Pastebot2Mac", "com.raycast.macos"]),
            state: state)
        XCTAssertTrue(text.contains("com.tapbots.Pastebot2Mac"))
        XCTAssertTrue(text.contains("com.raycast.macos"))
        XCTAssertTrue(text.contains("read after 12 ms"))
        XCTAssertTrue(text.contains("off (canary-read)"))
        XCTAssertFalse(text.contains(ClipboardCanary.canaryText))

        let session = ProblemSession(
            target: ProblemTarget(bundleID: "com.example.app", appName: "Example", appVersion: nil,
                                  classification: AppCompatibility.classify(bundleID: "com.example.app", bundleURL: nil)),
            setting: .automatic)
        let body = session.issueBody(speakfreeVersion: "1.0", macOSVersion: "26", clipboardDiagnostic: text)
        XCTAssertTrue(body.contains("**Clipboard**"))
        XCTAssertFalse(session.issueBody(speakfreeVersion: "1.0", macOSVersion: "26").contains("**Clipboard**"))
    }

    func test_canaryLogLines_areClassifiedForTheUpdateGuard() {
        for line in [
            "Clipboard trust: canary mode=lock outcome=read readAfter=12ms restored=true readers=none",
            "Clipboard trust: canary skipped, clipboard too large to hold",
            "TextInserter: clipboard restore route=native trigger=ax read=none pasteToRestore=40ms restored=true early=off(unknown-reader:com.x) ax=confirmed",
        ] {
            XCTAssertNotEqual(UpdateLogEvent.classify("[00:00:00] " + line), .unsupported, line)
        }
    }

    // MARK: - Accessibility outcome check: pure verdict

    private func snap(_ id: Int, count: Int, loc: Int, len: Int = 0, before: String? = nil) -> PasteFieldSnapshot {
        PasteFieldSnapshot(elementID: AnyHashable(id), characterCount: count, selectionLocation: loc,
                           selectionLength: len, textBeforeCaret: before)
    }

    func test_verdict_confirmDenyUnreadable() {
        let text = "okay"
        let before = snap(1, count: 10, loc: 10)
        XCTAssertEqual(PasteOutcome.verdict(before: before, after: snap(1, count: 14, loc: 14, before: "okay"), text: text),
                       .confirmed)
        // Text already before the caret, but the field did not grow: the paste has not landed.
        XCTAssertEqual(PasteOutcome.verdict(before: snap(1, count: 10, loc: 10), after: snap(1, count: 10, loc: 10, before: "okay"),
                                            text: text), .notYet)
        // Grew by the right amount but the text differs (the old clipboard was pasted, or it was rewritten).
        XCTAssertEqual(PasteOutcome.verdict(before: before, after: snap(1, count: 14, loc: 14, before: "OLD!"), text: text),
                       .notYet)
        XCTAssertEqual(PasteOutcome.verdict(before: before, after: snap(1, count: 14, loc: 14, before: nil), text: text),
                       .notYet)
        XCTAssertEqual(PasteOutcome.verdict(before: before, after: snap(2, count: 14, loc: 14, before: "okay"), text: text),
                       .unreadable, "focus moved")
        XCTAssertEqual(PasteOutcome.verdict(before: nil, after: snap(1, count: 14, loc: 14, before: "okay"), text: text),
                       .unreadable)
        XCTAssertEqual(PasteOutcome.verdict(before: before, after: nil, text: text), .unreadable)
        // Replacing a 3-character selection grows the field by 1.
        XCTAssertEqual(PasteOutcome.verdict(before: snap(1, count: 10, loc: 5, len: 3),
                                            after: snap(1, count: 11, loc: 9, before: "okay"), text: text), .confirmed)
        // UTF-16 lengths (emoji is 2 units).
        XCTAssertEqual(PasteOutcome.verdict(before: snap(1, count: 0, loc: 0),
                                            after: snap(1, count: 3, loc: 3, before: "a😀"), text: "a😀"), .confirmed)
    }

    // MARK: - Accessibility outcome check: end to end with a fake reader

    /// Plays the focused field. Thread-safe: read on the check's queue, changed on main.
    private final class FakeField: PasteFieldReading {
        enum Behavior { case pastes, neverChanges, unreadable, pastesOtherText }
        let lock = NSLock()
        let behavior: Behavior
        var pasted = false
        var reads = 0
        var pastedText = ""
        /// Signalled once the "before" read has been served. A real target answers the AX request
        /// queued before the paste first; this makes the fake do the same, so the confirm tests
        /// cannot race (the production race fails safe: before == after never confirms).
        let beforeServed = DispatchSemaphore(value: 0)
        init(_ behavior: Behavior) { self.behavior = behavior }
        func markPasted(_ text: String) {
            _ = beforeServed.wait(timeout: .now() + 2)
            lock.lock(); pasted = true; pastedText = text; lock.unlock()
        }
        func read(pid: pid_t, precedingLength: Int) -> PasteFieldSnapshot? {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            if reads == 1 { beforeServed.signal() }
            if behavior == .unreadable { return nil }
            guard pasted, behavior != .neverChanges else {
                return PasteFieldSnapshot(elementID: AnyHashable(7), characterCount: 20, selectionLocation: 20,
                                          selectionLength: 0, textBeforeCaret: nil)
            }
            let inserted = behavior == .pastesOtherText ? String(repeating: "x", count: (pastedText as NSString).length) : pastedText
            let n = (inserted as NSString).length
            return PasteFieldSnapshot(elementID: AnyHashable(7), characterCount: 20 + n, selectionLocation: 20 + n,
                                      selectionLength: 0,
                                      textBeforeCaret: precedingLength == n ? inserted : nil)
        }
    }

    private func makeInserter(pasteboard: NSPasteboard, trustReason: String? = nil,
                              field: FakeField? = nil, backstop: TimeInterval = 0.8,
                              target: @escaping (NSPasteboard) -> Void) -> TextInserter {
        let inserter = TextInserter()
        inserter.pasteboard = pasteboard
        inserter.frontmostBundleIDProvider = { "com.microsoft.VSCode" }
        inserter.frontmostBundleURLProvider = { nil }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.executeAppleScript = { _ in XCTFail("Unexpected AppleScript"); return nil }
        inserter.restoreTiming = { _ in TextInserter.ClipboardRestoreTiming(backstop: backstop, afterRead: 0.05) }
        inserter.clipboardTrustReason = { trustReason }
        inserter.pasteFieldReader = field
        inserter.pasteCheckDelays = [0.01, 0.03, 0.06]
        inserter.userPasteGate = UserPasteRestoreGate()
        inserter.layoutVKeyCodeProvider = { 9 }
        inserter.postPasteShortcut = { target(pasteboard) }
        return inserter
    }

    private func pasteAndWait(_ inserter: TextInserter, _ text: String) -> TextInserter.ClipboardRestoreRecord? {
        var record: TextInserter.ClipboardRestoreRecord?
        let exp = expectation(description: "restore")
        inserter.onClipboardRestore = { record = $0; exp.fulfill() }
        inserter.pasteViaClipboard(text)
        wait(for: [exp], timeout: 3)
        return record
    }

    /// An untrusted reader is running (read timer off), but the field shows the pasted text:
    /// the clipboard comes back at once instead of at the backstop.
    func test_ax_confirms_untrustedMac_restoresEarly() {
        let pb = makePasteboard()
        pb.clearContents(); pb.setString("USER ORIGINAL", forType: .string)
        let field = FakeField(.pastes)
        let text = "dictated words"
        let inserter = makeInserter(pasteboard: pb, trustReason: "unknown-reader:com.tapbots.Pastebot2Mac",
                                    field: field) { pb in
            if let got = pb.string(forType: .string) { field.markPasted(got) }
        }
        let record = try! XCTUnwrap(pasteAndWait(inserter, text))
        XCTAssertEqual(record.trigger, "ax")
        XCTAssertEqual(record.pasteCheck, "confirmed")
        XCTAssertTrue(record.restored)
        XCTAssertLessThan(record.pasteToRestore, 0.4, "long before the 0.8 s backstop")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
        XCTAssertTrue(record.logLine.hasSuffix("ax=confirmed"))
        XCTAssertFalse(record.logLine.contains(text), "field text is never logged")
    }

    /// The field never shows the text (a slow target, or a manager read first and the target
    /// has not pasted): the timer decides.
    func test_ax_deny_keepsTheTimer() {
        let pb = makePasteboard()
        pb.clearContents(); pb.setString("USER ORIGINAL", forType: .string)
        let field = FakeField(.neverChanges)
        let inserter = makeInserter(pasteboard: pb, trustReason: "canary-read", field: field) { pb in
            _ = pb.string(forType: .string)
        }
        let record = try! XCTUnwrap(pasteAndWait(inserter, "dictated words"))
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertEqual(record.pasteCheck, "unconfirmed")
        XCTAssertGreaterThanOrEqual(record.pasteToRestore, 0.7)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// Something of the right length landed, but it is not the dictation: never confirmed.
    func test_ax_wrongText_neverConfirms() {
        let pb = makePasteboard()
        pb.clearContents(); pb.setString("USER ORIGINAL", forType: .string)
        let field = FakeField(.pastesOtherText)
        let inserter = makeInserter(pasteboard: pb, trustReason: "canary-read", field: field) { pb in
            if let got = pb.string(forType: .string) { field.markPasted(got) }
        }
        let record = try! XCTUnwrap(pasteAndWait(inserter, "dictated words"))
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertEqual(record.pasteCheck, "unconfirmed")
    }

    func test_ax_unreadable_keepsTheTimer() {
        let pb = makePasteboard()
        pb.clearContents(); pb.setString("USER ORIGINAL", forType: .string)
        let field = FakeField(.unreadable)
        let inserter = makeInserter(pasteboard: pb, trustReason: "canary-read", field: field) { pb in
            _ = pb.string(forType: .string)
        }
        let record = try! XCTUnwrap(pasteAndWait(inserter, "dictated words"))
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertEqual(record.pasteCheck, "unreadable")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// A trusted Mac: whichever comes first (read timer or AX) restores, exactly once.
    func test_ax_andReadTimer_restoreOnce() {
        let pb = makePasteboard()
        pb.clearContents(); pb.setString("USER ORIGINAL", forType: .string)
        let field = FakeField(.pastes)
        let inserter = makeInserter(pasteboard: pb, field: field) { pb in
            if let got = pb.string(forType: .string) { field.markPasted(got) }
        }
        var records: [TextInserter.ClipboardRestoreRecord] = []
        let exp = expectation(description: "restore")
        inserter.onClipboardRestore = { records.append($0); exp.fulfill() }
        inserter.pasteViaClipboard("dictated words")
        wait(for: [exp], timeout: 3)
        spin(1.0)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(["ax", "read"].contains(records[0].trigger))
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// The main-thread work this change adds per paste: create the check, queue the "before"
    /// read, start the looks (all AX work happens on the queue), and the trust decision.
    func test_mainThreadCostPerPaste_isWellUnderAMillisecond() {
        struct InstantReader: PasteFieldReading {
            func read(pid: pid_t, precedingLength: Int) -> PasteFieldSnapshot? { nil }
        }
        let queue = DispatchQueue(label: "test.paste-check.cost")
        queue.suspend()  // measure main's share only; nothing runs on the queue meanwhile
        var checks: [PasteOutcomeCheck] = []
        let iterations = 500
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let check = PasteOutcomeCheck(text: "dictated words", pid: 1, reader: InstantReader(), queue: queue)
            check.captureBefore()
            check.start(delays: PasteOutcome.defaultDelays) { _ in }
            checks.append(check)
        }
        let axSetupMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(iterations)
        checks.forEach { $0.cancel() }
        queue.resume()

        let manyApps: [String?] = (0..<400).map { "com.example.app\($0)" } + ["com.raycast.macos", "com.clipy-app.Clipy"]
        // The first paste after launch classifies every app once (memoized after that).
        let coldStart = DispatchTime.now().uptimeNanoseconds
        _ = ClipboardReaderCatalog.running(in: manyApps)
        let coldMs = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000
        print("trust decision, first paste after launch (402 apps): \(String(format: "%.3f", coldMs)) ms")
        let decisionStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            _ = ClipboardTrust.untrustedReason(running: ClipboardReaderCatalog.running(in: manyApps), verdict: .none)
        }
        let decisionMs = Double(DispatchTime.now().uptimeNanoseconds - decisionStart) / 1_000_000 / Double(iterations)

        print("main-thread cost per paste: AX setup \(String(format: "%.4f", axSetupMs)) ms, "
              + "trust decision over 402 apps \(String(format: "%.4f", decisionMs)) ms")
        XCTAssertLessThan(axSetupMs, 0.1)
        XCTAssertLessThan(decisionMs, 0.5)
    }

    /// Two borrows back to back (the second paste starts before the first is restored): the
    /// second gets no Accessibility check, since the first paste landing late with the same text
    /// would look exactly like the second one.
    func test_ax_skippedForAPasteThatOverlapsAnEarlierBorrow() {
        let pb = makePasteboard()
        pb.clearContents(); pb.setString("USER ORIGINAL", forType: .string)
        let field = FakeField(.neverChanges)
        let inserter = makeInserter(pasteboard: pb, trustReason: "canary-read", field: field, backstop: 0.4) { pb in
            _ = pb.string(forType: .string)
        }
        var records: [TextInserter.ClipboardRestoreRecord] = []
        let exp = expectation(description: "restore")
        inserter.onClipboardRestore = { records.append($0); exp.fulfill() }
        inserter.pasteViaClipboard("okay.")
        inserter.pasteViaClipboard("okay.")
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].pasteCheck, "no AX check on the overlapping paste")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    // MARK: - Canary: clipboards it must never touch

    func test_canary_skipsAMarkedClipboard() {
        let pb = makePasteboard()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pb.writeObjects([item])
        let before = pb.changeCount
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock())
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("marked-clipboard"))
        XCTAssertEqual(pb.changeCount, before, "never touched")
        XCTAssertEqual(pb.string(forType: .string), "secret")
    }

    func test_canary_skipsARecentlyChangedClipboard_untilQuiet() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let clock = FakeClock()
        let store = ClipboardTrustStore(fileURL: nil)
        let canary = makeCanary(pb, store: store, clock: clock, hold: 0.05)
        canary.env.quietClipboardInterval = 60
        canary.noteClipboard()
        clock.uptime += 30
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("clipboard-recent"))
        pb.clearContents(); pb.setString("new copy", forType: .string)
        clock.uptime += 45
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("clipboard-recent"), "the change restarted the wait")
        clock.uptime += 61
        XCTAssertEqual(canary.startIfDue(mode: .lock), .started)
        _ = waitForCanary(canary)
        XCTAssertEqual(pb.string(forType: .string), "new copy")
    }

    private final class SilentProvider: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {}
    }

    func test_canary_skipsAClipboardItCannotCopyBackExactly() {
        let pb = makePasteboard()
        pb.clearContents()
        let provider = SilentProvider()
        let item = NSPasteboardItem()
        item.setString("visible", forType: .string)
        item.setDataProvider(provider, forTypes: [typeA])  // a promise that yields nothing
        pb.writeObjects([item])
        let before = pb.changeCount
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock())
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("lossy-clipboard"))
        XCTAssertEqual(pb.changeCount, before, "never touched")
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("unsuitable-clipboard"),
                       "the same clipboard is not copied again every tick")
    }

    /// The user comes back mid-run and presses Cmd+V: the paste-watch tap puts their clipboard
    /// back inside the keystroke, so they never paste the canary text.
    func test_userCmdVDuringCanary_restoresTheirClipboardInsideTheKeystroke() {
        let pb = makePasteboard()
        let original = writeRichClipboard(pb)
        let gate = UserPasteRestoreGate()
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock(), hold: 5)
        canary.env.pasteGate = gate
        XCTAssertEqual(canary.startIfDue(mode: .lock), .started)
        XCTAssertTrue(gate.isWatching)

        let outcome = gate.handleKeyDown(type: .keyDown, keyCode: PasteKeystroke.ansiVKeyCode,
                                         flags: .maskCommand, userData: 0, sourcePID: 1, isAutorepeat: false)
        guard case .restored = outcome else { return XCTFail("expected a restore, got \(outcome)") }
        assertSameClipboard(dump(pb), original)  // already back when the target reads

        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertEqual(result.note, "user-paste")
        XCTAssertEqual(result.outcome, .inconclusive)
        XCTAssertTrue(result.restored)
        assertSameClipboard(dump(pb), original)
        XCTAssertFalse(gate.isWatching)
    }

    func test_canaryEnd_stopsTheGateWatching() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let gate = UserPasteRestoreGate()
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock(), hold: 0.05)
        canary.env.pasteGate = gate
        canary.startIfDue(mode: .lock)
        _ = waitForCanary(canary)
        XCTAssertFalse(gate.isWatching)
        XCTAssertEqual(gate.handleKeyDown(type: .keyDown, keyCode: PasteKeystroke.ansiVKeyCode, flags: .maskCommand,
                                          userData: 0, sourcePID: 1, isAutorepeat: false), .idle)
    }

    /// A missed unlock notification must never start a lock run while the user works.
    func test_lockMode_requiresSessionLocked_andNoRecentInput() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let clock = FakeClock()
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: clock, hold: 0.05)
        clock.locked = false
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("not-locked"))
        clock.locked = true
        clock.lastInputAt = clock.uptime - 1
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("recent-input"))
        clock.lastInputAt = clock.uptime - ClipboardCanary.lockQuietInput - 1
        XCTAssertEqual(canary.startIfDue(mode: .lock), .started)
        _ = waitForCanary(canary)
    }

    /// A missed unlock notification: ticks find the session unlocked and fall back to idle mode
    /// instead of silently never checking again.
    func test_scheduler_missedUnlock_fallsBackToIdleMode() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let clock = FakeClock()
        clock.locked = false  // the session is actually unlocked
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: clock, hold: 5)
        let scheduler = ClipboardCanaryScheduler(canary: canary)
        scheduler.lockDelay = 0.01
        scheduler.screenDidLock()
        spin(0.1)
        XCTAssertFalse(canary.isRunning)
        scheduler.idleTick()
        XCTAssertFalse(scheduler.screenLocked)
        XCTAssertTrue(canary.isRunning)
        var result: ClipboardCanaryResult?
        canary.onFinish = { result = $0 }
        canary.abort(reason: "test")
        XCTAssertEqual(result?.mode, .idle)
    }

    /// After a read, short idle runs never count toward trusting the Mac again.
    func test_afterARead_shortIdleCleanRunsDoNotRecover() {
        func result(_ outcome: ClipboardCanaryResult.Outcome, holdMs: Int) -> ClipboardCanaryResult {
            ClipboardCanaryResult(date: Date(), mode: holdMs >= 15_000 ? .lock : .idle, outcome: outcome,
                                  readAfterMs: nil, restored: true, readers: [], note: nil, holdMs: holdMs)
        }
        var state = ClipboardTrustState()
        state.append(result(.read, holdMs: 20_000))
        for _ in 0..<5 { state.append(result(.clean, holdMs: 2_000)) }
        XCTAssertEqual(state.verdict, .untrusted)
        state.append(result(.clean, holdMs: 20_000)); state.append(result(.clean, holdMs: 20_000))
        XCTAssertEqual(state.verdict, .untrusted)
        state.append(result(.clean, holdMs: 20_000))
        XCTAssertNotEqual(state.verdict, .untrusted)
        // A short idle run still CATCHES a reader.
        state.append(result(.read, holdMs: 2_000))
        XCTAssertEqual(state.verdict, .untrusted)
    }

    /// On a non-QWERTY layout the gate recognizes the layout's own "v" key during a canary.
    func test_canaryGate_usesTheLayoutVKey() {
        let pb = makePasteboard()
        let original = writeRichClipboard(pb)
        let gate = UserPasteRestoreGate()
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: FakeClock(), hold: 5)
        canary.env.pasteGate = gate
        canary.env.layoutVKeyCode = { 47 }  // Dvorak's "v" position
        canary.startIfDue(mode: .lock)
        let outcome = gate.handleKeyDown(type: .keyDown, keyCode: 47, flags: .maskCommand,
                                         userData: 0, sourcePID: 1, isAutorepeat: false)
        guard case .restored = outcome else { return XCTFail("expected a restore, got \(outcome)") }
        assertSameClipboard(dump(pb), original)
        _ = waitForCanary(canary)
    }

    func test_holds_lockLongIdleShort() {
        XCTAssertGreaterThanOrEqual(ClipboardCanary.lockHold * 1000, Double(ClipboardTrustState.minimumCoveringHoldMs))
        XCTAssertLessThan(ClipboardCanary.idleHold * 1000, Double(ClipboardTrustState.minimumCoveringHoldMs))
    }

    func test_scheduler_whileLocked_ticksRetryInLockMode() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let clock = FakeClock()
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: clock, hold: 5)
        let scheduler = ClipboardCanaryScheduler(canary: canary)
        scheduler.lockDelay = 0.05
        scheduler.screenDidLock()
        scheduler.idleTick()
        XCTAssertFalse(canary.isRunning, "a tick never runs before the lock screen settles")
        clock.busy = true
        spin(0.15)
        XCTAssertFalse(canary.isRunning, "the settle-time attempt was skipped (busy)")
        clock.busy = false
        scheduler.idleTick()
        XCTAssertTrue(canary.isRunning, "a later tick retries in lock mode")
        var result: ClipboardCanaryResult?
        canary.onFinish = { result = $0 }
        scheduler.screenDidUnlock()
        XCTAssertEqual(result?.mode, .lock)
    }

    /// A paste right after the previous borrow was restored gets no AX check: that paste may
    /// still be landing in an Electron target.
    func test_ax_skippedRightAfterAnEarlierBorrowEnded() {
        let pb = makePasteboard()
        pb.clearContents(); pb.setString("USER ORIGINAL", forType: .string)
        let field = FakeField(.pastes)
        let inserter = makeInserter(pasteboard: pb, field: field) { pb in
            if let got = pb.string(forType: .string) { field.markPasted(got) }
        }
        let first = try! XCTUnwrap(pasteAndWait(inserter, "okay."))
        XCTAssertNotNil(first.pasteCheck)
        inserter.pasteFieldReader = FakeField(.neverChanges)
        inserter.postPasteShortcut = { _ = pb.string(forType: .string) }
        let second = try! XCTUnwrap(pasteAndWait(inserter, "okay."))
        XCTAssertNil(second.pasteCheck, "no AX check within 1.5 s of the last borrow")
    }

    /// The hold ends before the input poll notices the user came back: never recorded as clean.
    func test_idleMode_inputDuringHold_isNeverClean() {
        let pb = makePasteboard()
        _ = writeRichClipboard(pb)
        let clock = FakeClock()
        clock.lastInputAt = clock.uptime - ClipboardCanary.idleThreshold - 1
        let canary = makeCanary(pb, store: ClipboardTrustStore(fileURL: nil), clock: clock, hold: 0.1)
        canary.env.inputPollInterval = 10
        canary.startIfDue(mode: .idle)
        clock.uptime += 0.05
        clock.lastInputAt = clock.uptime
        let result = try! XCTUnwrap(waitForCanary(canary))
        XCTAssertEqual(result.outcome, .inconclusive)
        XCTAssertEqual(result.note, "user-returned")
    }
}
