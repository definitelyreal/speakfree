// ai-suggestion:unverified · Claude · 2026-09-24 · feat/fast-clipboard
//
// Fast clipboard restore: the dictated text is a lazy pasteboard promise, the first read is the
// receipt, and the user's clipboard comes back shortly after it instead of after a fixed 3 s.
// Every test runs on a uniquely named NSPasteboard (never `.general`) and plays the target app
// through `postPasteShortcut`, so no real keystroke is ever posted.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class FastClipboardRestoreTests: XCTestCase {

    // Scaled-down timing so the suite stays fast but early vs backstop is unmistakable.
    private let afterRead: TimeInterval = 0.05
    private let backstop: TimeInterval = 0.6

    private final class Sink {
        var records: [TextInserter.ClipboardRestoreRecord] = []
        var expectation: XCTestExpectation?
        var reads: [String?] = []
    }

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("speakfree.test.fastclip.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private func makeInserter(bundleID: String = "com.microsoft.VSCode",
                              pasteboard: NSPasteboard,
                              afterRead: TimeInterval? = nil,
                              syncer: String? = nil,
                              sink: Sink,
                              target: @escaping (NSPasteboard) -> Void) -> TextInserter {
        let inserter = TextInserter()
        inserter.pasteboard = pasteboard
        inserter.frontmostBundleIDProvider = { bundleID }
        inserter.frontmostBundleURLProvider = { nil }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.executeAppleScript = { _ in XCTFail("Unexpected AppleScript"); return nil }
        let early = afterRead ?? self.afterRead
        let backstop = self.backstop
        inserter.restoreTiming = { route in
            TextInserter.ClipboardRestoreTiming(backstop: backstop,
                                                afterRead: route == .remote ? nil : early)
        }
        inserter.clipboardTrustReason = { syncer.map { "syncer:\($0)" } }
        inserter.pasteFieldReader = nil
        inserter.postPasteShortcut = { target(pasteboard) }
        inserter.onClipboardRestore = { record in
            sink.records.append(record)
            sink.expectation?.fulfill()
        }
        return inserter
    }

    private func setUserClipboard(_ pb: NSPasteboard, _ text: String) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func waitForRestore(_ sink: Sink, timeout: TimeInterval = 3) {
        let exp = expectation(description: "clipboard restore")
        sink.expectation = exp
        wait(for: [exp], timeout: timeout)
        sink.expectation = nil
    }

    /// Spin the main run loop (timers and asyncAfter keep firing) for `seconds`.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Pure policy

    func test_timingPolicy_earlyRestoreOnLocalRoutesOnly_andShorterThanBackstop() {
        let native = TextInserter.restoreTiming(route: .native)
        let electron = TextInserter.restoreTiming(route: .electron)
        let remote = TextInserter.restoreTiming(route: .remote)
        XCTAssertNil(remote.afterRead, "a remote viewer syncs eagerly; a read proves nothing")
        XCTAssertEqual(remote.backstop, TextInserter.remoteClipboardRestoreDelay)
        XCTAssertEqual(native.backstop, TextInserter.localClipboardRestoreDelay)
        XCTAssertEqual(electron.backstop, TextInserter.electronClipboardRestoreDelay)
        XCTAssertLessThanOrEqual(try XCTUnwrap(native.afterRead), 0.2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(electron.afterRead), 0.4)
        XCTAssertLessThan(try XCTUnwrap(electron.afterRead), electron.backstop / 5,
                          "the point of the change: Electron restores in well under a second")
    }

    func test_runningClipboardSyncer_findsVMsAndKVMs_notOrdinaryApps() {
        XCTAssertEqual(AppCompatibility.runningClipboardSyncer(
            runningBundleIDs: ["com.splashtop.streamer"]), "com.splashtop.streamer",
                       "Splashtop Streamer serves this Mac's clipboard outward; unmeasured")
        XCTAssertNil(AppCompatibility.runningClipboardSyncer(
            runningBundleIDs: ["com.apple.finder", nil, "com.splashtop.stp.macosx",
                               "com.microsoft.rdc.macos", "com.microsoft.VSCode"]),
                     "Splashtop (measured) and RDP (lazy by protocol) do not read eagerly")
        // Unmeasured remote viewers may sync eagerly: backstop decides while they run.
        XCTAssertTrue(AppCompatibility.isClipboardSyncer(bundleID: "com.apple.ScreenSharing"))
        XCTAssertTrue(AppCompatibility.isClipboardSyncer(bundleID: "com.p5sys.jump.mac.viewer"))
        XCTAssertTrue(AppCompatibility.isClipboardSyncer(bundleID: "com.philandro.anydesk"))
        XCTAssertEqual(AppCompatibility.runningClipboardSyncer(
            runningBundleIDs: ["com.apple.finder", "com.VMware.Fusion"]), "com.VMware.Fusion")
        XCTAssertTrue(AppCompatibility.isClipboardSyncer(bundleID: "com.parallels.desktop.console"))
        XCTAssertTrue(AppCompatibility.isClipboardSyncer(bundleID: "org.deskflow.deskflow"))
        XCTAssertFalse(AppCompatibility.isClipboardSyncer(bundleID: nil))
    }

    func test_logLine_carriesRouteTriggerAndTimings() {
        let record = TextInserter.ClipboardRestoreRecord(
            route: .electron, trigger: "read", lazy: true, pasteToRead: 0.012,
            pasteToRestore: 0.3125, restored: true, earlyOffReason: nil)
        XCTAssertEqual(record.logLine,
                       "TextInserter: clipboard restore route=electron trigger=read read=12ms "
                       + "pasteToRestore=313ms restored=true")
        let never = TextInserter.ClipboardRestoreRecord(
            route: .native, trigger: "backstop", lazy: true, pasteToRead: nil,
            pasteToRestore: 0.3, restored: false, earlyOffReason: "syncer:com.vmware.fusion")
        XCTAssertTrue(never.logLine.contains("read=none"))
        XCTAssertTrue(never.logLine.hasSuffix("early=off(syncer:com.vmware.fusion)"))
        let remote = TextInserter.ClipboardRestoreRecord(
            route: .remote, trigger: "backstop", lazy: false, pasteToRead: nil,
            pasteToRestore: 3.0, restored: true, earlyOffReason: "route")
        XCTAssertTrue(remote.logLine.contains("read=n/a"))
    }

    // MARK: - The lazy write itself

    /// Pins the OS behavior the design depends on, on a named pasteboard: +1 changeCount, markers
    /// visible from the type list without calling the provider, provider called once, and a
    /// second read served from the pasteboard's cache with the same text.
    func test_lazyWrite_typesDoNotCallProvider_firstReadDoes_secondReadIsCached() {
        let pb = makePasteboard()
        let provider = DictationPasteProvider(text: "hello world")
        var receipts = 0
        provider.onRead = { receipts += 1 }
        let before = pb.changeCount

        let written = TextInserter.writeLazyDictation(provider: provider, to: pb).generation

        XCTAssertEqual(written, before + 1)
        let types = pb.types ?? []
        for marker in DictationPasteProvider.markerTypes {
            XCTAssertTrue(types.contains(marker), "missing marker \(marker.rawValue)")
        }
        XCTAssertTrue(types.contains(.string))
        XCTAssertEqual(provider.provideCount, 0, "a types-only query must not count as a read")
        XCTAssertEqual(pb.string(forType: .string), "hello world")
        XCTAssertEqual(provider.provideCount, 1)
        XCTAssertEqual(pb.string(forType: .string), "hello world")
        XCTAssertEqual(provider.provideCount, 1, "second read is served from the pasteboard cache")
        XCTAssertEqual(receipts, 1)
        XCTAssertEqual(pb.changeCount, written, "reading must not advance changeCount")
    }

    func test_ownRead_isServedButIsNotAReceipt() {
        let pb = makePasteboard()
        let provider = DictationPasteProvider(text: "mine")
        var receipts = 0
        provider.onRead = { receipts += 1 }
        TextInserter.writeLazyDictation(provider: provider, to: pb)

        let value = TextInserter.withOwnPasteboardRead { pb.string(forType: .string) }

        XCTAssertEqual(value, "mine")
        XCTAssertEqual(provider.provideCount, 1)
        XCTAssertEqual(receipts, 0)
        XCTAssertFalse(DictationPasteProvider.ownReadInProgress, "flag must be reset")
    }

    // MARK: - End to end (named pasteboard, simulated target)

    /// Provider called once, synchronously with the paste (a responsive app): the user's
    /// clipboard is back right after the margin, long before the backstop.
    func test_targetReadsDuringPaste_restoresAfterReadMargin_notBackstop() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
        }

        inserter.pasteViaClipboard("dictated words")
        waitForRestore(sink)

        XCTAssertEqual(sink.reads, ["dictated words"], "the target pasted the dictation")
        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.route, .electron)
        XCTAssertEqual(record.trigger, "read")
        XCTAssertTrue(record.restored)
        XCTAssertNotNil(record.pasteToRead)
        XCTAssertLessThan(record.pasteToRestore, backstop / 2, "restored early, not at the backstop")
        XCTAssertGreaterThanOrEqual(record.pasteToRestore, afterRead * 0.9)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// The target reads later (a busy Electron app): the restore waits for that read.
    func test_targetReadsLate_restoreWaitsForTheRead() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, sink: sink) { pb in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                sink.reads.append(pb.string(forType: .string))
            }
        }

        inserter.pasteViaClipboard("late read")
        waitForRestore(sink)

        XCTAssertEqual(sink.reads, ["late read"], "a late reader still got the dictation")
        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "read")
        XCTAssertGreaterThanOrEqual(try! XCTUnwrap(record.pasteToRead), 0.2)
        XCTAssertGreaterThanOrEqual(record.pasteToRestore, 0.25 + afterRead * 0.9)
        XCTAssertLessThan(record.pasteToRestore, backstop)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// Provider never called (nothing pasted, e.g. no text field focused): backstop restores and
    /// the log says no read happened.
    func test_targetNeverReads_backstopRestores_logsNoRead() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, sink: sink) { _ in }

        inserter.pasteViaClipboard("never read")
        waitForRestore(sink)

        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertNil(record.pasteToRead)
        XCTAssertGreaterThanOrEqual(record.pasteToRestore, backstop * 0.9)
        XCTAssertTrue(record.restored)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// Read twice inside one paste: both reads get the dictation (the second from the cache),
    /// and only the first read counts, so a later provider call cannot push the restore out.
    func test_targetReadsTwice_bothGetDictation_onlyFirstReceiptCounts() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let margin: TimeInterval = 0.3
        var inserterRef: TextInserter?
        let inserter = makeInserter(pasteboard: pb, afterRead: margin, sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                sink.reads.append(pb.string(forType: .string))
            }
            // Force a second PROVIDER call (as if the OS had not cached): must not re-arm.
            let provider = inserterRef?.pendingDictationProviderForTest
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                provider?.pasteboard(pb, item: NSPasteboardItem(), provideDataForType: .string)
            }
        }
        inserterRef = inserter

        inserter.pasteViaClipboard("twice")
        waitForRestore(sink)

        XCTAssertEqual(sink.reads, ["twice", "twice"])
        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "read")
        // Expected ~0.3 s (first read + margin); a re-arm would give ~0.5 s. 100 ms slack each way.
        XCTAssertLessThan(record.pasteToRestore, 0.2 + margin - 0.1,
                          "the restore is timed from the FIRST read, not re-armed by a later one")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// User copies between the target's read and the restore: their copy wins, untouched.
    func test_userCopiesDuringWindow_afterRead_isNotClobbered() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, afterRead: 0.15, sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
            DispatchQueue.main.async {
                pb.clearContents()
                pb.setString("USER COPIED JUST NOW", forType: .string)
            }
        }

        inserter.pasteViaClipboard("dictation")
        waitForRestore(sink)

        XCTAssertFalse(try! XCTUnwrap(sink.records.first).restored)
        XCTAssertEqual(pb.string(forType: .string), "USER COPIED JUST NOW")
    }

    /// User copies while nobody has read yet: backstop fires, sees the change, leaves it.
    func test_userCopiesDuringWindow_noRead_isNotClobbered() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, sink: sink) { pb in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pb.clearContents()
                pb.setString("USER COPIED", forType: .string)
            }
        }

        inserter.pasteViaClipboard("dictation")
        waitForRestore(sink)

        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertFalse(record.restored)
        XCTAssertEqual(pb.string(forType: .string), "USER COPIED")
    }

    /// A clipboard with several items and many types (text, rich text, an image, a private type,
    /// a file URL) comes back byte for byte.
    func test_multiItemMultiTypeClipboard_isRestoredExactly() {
        let pb = makePasteboard()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<4096).map { UInt8($0 & 0xFF) })
        let rtf = Data("{\\rtf1\\ansi hello}".utf8)
        let custom = NSPasteboard.PasteboardType("com.example.private-blob")
        let item1 = NSPasteboardItem()
        item1.setString("rich hello", forType: .string)
        item1.setData(rtf, forType: .rtf)
        item1.setData(png, forType: .png)
        item1.setData(Data([1, 2, 3, 0, 255]), forType: custom)
        let item2 = NSPasteboardItem()
        item2.setString("file:///Users/example/Desktop/report.pdf", forType: .fileURL)
        pb.clearContents()
        pb.writeObjects([item1, item2])
        let before = snapshot(pb)
        XCTAssertEqual(before.count, 2)

        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
        }
        inserter.pasteViaClipboard("dictation over a rich clipboard")
        waitForRestore(sink)

        XCTAssertEqual(sink.reads, ["dictation over a rich clipboard"])
        XCTAssertTrue(try! XCTUnwrap(sink.records.first).restored)
        XCTAssertEqual(snapshot(pb), before, "every item and every type must come back unchanged")
    }

    /// An empty clipboard stays empty (no dictation left behind).
    func test_emptyOriginalClipboard_endsEmpty() {
        let pb = makePasteboard()
        pb.clearContents()
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
        }
        inserter.pasteViaClipboard("temporary")
        waitForRestore(sink)
        XCTAssertNil(pb.string(forType: .string))
    }

    /// Two dictations back to back: the second paste gets ITS text (never the first's), a stale
    /// receipt from the first provider cannot trigger the restore, and the user's true original
    /// (not dictation one) comes back.
    func test_secondDictationDuringWindow_neverStale_restoresTrueOriginal() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        var readTarget = false
        let inserter = makeInserter(pasteboard: pb, afterRead: 0.1, sink: sink) { pb in
            if readTarget { sink.reads.append(pb.string(forType: .string)) }
        }

        inserter.pasteViaClipboard("first dictation")          // target never reads this one
        let firstProvider = try! XCTUnwrap(inserter.pendingDictationProviderForTest)
        readTarget = true
        inserter.pasteViaClipboard("second dictation")
        XCTAssertFalse(inserter.pendingDictationProviderForTest === firstProvider)

        // A late receipt from the superseded provider must be ignored.
        firstProvider.pasteboard(pb, item: NSPasteboardItem(), provideDataForType: .string)
        waitForRestore(sink)

        XCTAssertEqual(sink.reads, ["second dictation"])
        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records.first?.trigger, "read")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
        spin(backstop + 0.1)
        XCTAssertEqual(sink.records.count, 1, "exactly one restore; the backstop was replaced")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// A known clipboard syncer (VM) is running: it may read first, so a read is not trusted and
    /// the backstop decides. The read is still logged.
    func test_syncerRunning_disablesEarlyRestore() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, syncer: "com.vmware.fusion", sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
        }

        inserter.pasteViaClipboard("dictation")
        waitForRestore(sink)

        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertNotNil(record.pasteToRead)
        XCTAssertEqual(record.earlyOffReason, "syncer:com.vmware.fusion")
        XCTAssertGreaterThanOrEqual(record.pasteToRestore, backstop * 0.9)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// speakfree's own read of the clipboard (the user's Cmd+V tail tracking) is not the
    /// target's read: the backstop decides.
    func test_speakfreesOwnRead_doesNotTriggerEarlyRestore() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(pasteboard: pb, sink: sink) { pb in
            sink.reads.append(TextInserter.withOwnPasteboardRead { pb.string(forType: .string) })
        }

        inserter.pasteViaClipboard("dictation")
        waitForRestore(sink)

        XCTAssertEqual(sink.reads, ["dictation"])
        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertNil(record.pasteToRead)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    func test_nativeApp_takesNativeRouteAndRestoresEarlyToo() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        let inserter = makeInserter(bundleID: "com.apple.TextEdit", pasteboard: pb, sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
        }
        inserter.pasteViaClipboard("native")
        waitForRestore(sink)
        XCTAssertEqual(sink.records.first?.route, .native)
        XCTAssertEqual(sink.records.first?.trigger, "read")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// The user switched apps and pasted there before the target read: that read may not be the
    /// target's, so it is not a receipt and the backstop decides.
    func test_readWhileAnotherAppIsFrontmost_isNotAReceipt() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        var frontPID: pid_t = 999_999
        let inserter = makeInserter(pasteboard: pb, sink: sink) { pb in
            frontPID = 4242   // the user is now in another app
            sink.reads.append(pb.string(forType: .string))
        }
        inserter.frontmostPIDProvider = { frontPID }

        inserter.pasteViaClipboard("dictation")
        waitForRestore(sink)

        let record = try! XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "backstop")
        XCTAssertEqual(record.earlyOffReason, "read-while-other-app-frontmost")
        XCTAssertGreaterThanOrEqual(record.pasteToRestore, backstop * 0.9)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    // MARK: - Another process reads (real cross-process pasteboard traffic, named pasteboard)

    /// Starts a separate process that reads the named pasteboard's text; `done` gets its output.
    private func readInAnotherProcess(_ pb: NSPasteboard, done: @escaping (String) -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let name = pb.name.rawValue
        process.arguments = ["-l", "JavaScript", "-e",
            "ObjC.import('AppKit'); var v = $.NSPasteboard.pasteboardWithName('\(name)')"
            + ".stringForType($.NSPasteboardTypeString); v.isNil() ? '<nil>' : ObjC.unwrap(v)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        addTeardownBlock { if process.isRunning { process.terminate() } }
        process.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(text) }
        }
        try process.run()
    }

    func test_anotherProcessReads_getsDictation_andIsTheReceipt() throws {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        var childRead: String?
        let inserter = makeInserter(pasteboard: pb, afterRead: 0.1, sink: sink) { [unowned self] pb in
            do { try self.readInAnotherProcess(pb) { childRead = $0 } } catch { XCTFail("\(error)") }
        }
        // The child can take seconds to launch on a loaded machine; the restore still comes from
        // its read, so a long backstop only removes the flake.
        inserter.restoreTiming = { (_: TextInserter.PasteRoute) in TextInserter.ClipboardRestoreTiming(backstop: 30, afterRead: 0.1) }

        inserter.pasteViaClipboard("from another process")
        waitForRestore(sink, timeout: 35)

        let record = try XCTUnwrap(sink.records.first)
        XCTAssertEqual(record.trigger, "read")
        XCTAssertTrue(record.restored)
        spin(0.3)
        XCTAssertEqual(childRead, "from another process")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// Integration check: speakfree's main thread is busy past the backstop while another
    /// process is waiting to read; that queued read must still get the dictation. (On macOS 26
    /// the queued read was observed to be served before the overdue timer even without the
    /// grace period; the deterministic grace tests below pin the defense itself.)
    func test_busyMainThread_lateBackstop_letsQueuedReadFinishFirst() throws {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        var childRead: String?
        let inserter = makeInserter(pasteboard: pb, afterRead: 0.1, sink: sink) { [unowned self] pb in
            do { try self.readInAnotherProcess(pb) { childRead = $0 } } catch { XCTFail("\(error)") }
            // Block main well past the backstop while the child's read request queues up.
            Thread.sleep(forTimeInterval: 1.5)
        }
        inserter.restoreTiming = { (_: TextInserter.PasteRoute) in TextInserter.ClipboardRestoreTiming(backstop: 0.6, afterRead: 0.1) }

        inserter.pasteViaClipboard("queued read")
        waitForRestore(sink, timeout: 8)
        spin(0.5)

        XCTAssertEqual(childRead, "queued read", "the queued read must get the dictation, not nothing")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// Deterministic version of the above: the clock jumps 1 s while nothing has read, so the
    /// backstop sees itself running late and waits exactly one grace period before restoring.
    func test_lateBackstop_withNoRead_waitsOneGracePeriod() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        var skew: TimeInterval = 0
        let inserter = makeInserter(pasteboard: pb, sink: sink) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { skew = 1.0 }
        }
        inserter.uptime = { ProcessInfo.processInfo.systemUptime + skew }
        let start = Date()

        inserter.pasteViaClipboard("late")
        waitForRestore(sink)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(sink.records.first?.trigger, "backstop")
        XCTAssertGreaterThanOrEqual(elapsed, backstop + TextInserter.lateBackstopGrace * 0.9,
                                    "a late backstop must wait one grace period")
        XCTAssertLessThan(elapsed, backstop + 2 * TextInserter.lateBackstopGrace + 0.2,
                          "only ONE grace period, never an endless wait")
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    /// After a read, a late backstop needs no grace (the text is cached by the pasteboard).
    func test_lateBackstop_afterRead_noGrace() {
        let pb = makePasteboard()
        setUserClipboard(pb, "USER ORIGINAL")
        let sink = Sink()
        var skew: TimeInterval = 0
        let inserter = makeInserter(pasteboard: pb, syncer: "com.vmware.fusion", sink: sink) { pb in
            sink.reads.append(pb.string(forType: .string))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { skew = 1.0 }
        }
        inserter.uptime = { ProcessInfo.processInfo.systemUptime + skew }
        let start = Date()

        inserter.pasteViaClipboard("read then late")
        waitForRestore(sink)

        XCTAssertLessThan(Date().timeIntervalSince(start), backstop + TextInserter.lateBackstopGrace * 0.8)
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")
    }

    // MARK: - Helpers

    private struct TypeData: Equatable { let type: String; let data: Data }

    private func snapshot(_ pb: NSPasteboard) -> [[TypeData]] {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { TypeData(type: type.rawValue, data: $0) }
            }
        }
    }
}
