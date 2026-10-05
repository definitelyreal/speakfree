// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_core · 2026-10-01
import AppKit
import XCTest
@testable import SpeakFreeLib

final class ClipboardHistoryMonitorTests: XCTestCase {
    private final class Promise: NSObject, NSPasteboardItemDataProvider {
        var readCount = 0
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            readCount += 1
            item.setString("promised", forType: type)
        }
    }

    private func scratchBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("speakfree.test.history.\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func makeMonitor(_ board: NSPasteboard, store: HistoryStore) -> ClipboardHistoryMonitor {
        let monitor = ClipboardHistoryMonitor(pasteboard: board, store: store)
        monitor.sourceAppBundleID = { "example.editor" }
        monitor.accessIsDenied = { false }
        monitor.accessNeedsApproval = { false }
        monitor.secureInputIsActive = { false }
        monitor.setEnabled(true)
        return monitor
    }

    private func copy(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func flush(_ monitor: ClipboardHistoryMonitor) {
        let finished = expectation(description: "clipboard reader finished")
        monitor.flushForTesting { finished.fulfill() }
        wait(for: [finished], timeout: 4)
    }

    func testAskPermissionPausesBeforeMetadataAndPayloadAndResumesAfterAllow() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        var asking = true
        var reads = 0
        monitor.accessNeedsApproval = { XCTAssertFalse(Thread.isMainThread); return asking }
        monitor.readRootTypes = { reads += 1; return board.types ?? [] }
        for text in ["first synthetic copy", "second synthetic copy"] {
            copy(text, to: board)
            monitor.pollNow()
            flush(monitor)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(monitor.status?.contains("paused") == true)
        asking = false
        copy("allowed synthetic copy", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["allowed synthetic copy"])
        XCTAssertNil(monitor.status)
    }

    func testMetadataAndAccessQueriesRunOffMainWhileStatusAndStoreMergeOnMain() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        var denied = true
        var metadata: [String] = []
        var statuses = 0
        var merges = 0
        monitor.accessIsDenied = { XCTAssertFalse(Thread.isMainThread); return denied }
        monitor.readRootTypes = {
            XCTAssertFalse(Thread.isMainThread); metadata.append("root")
            return board.types ?? []
        }
        monitor.readItems = {
            XCTAssertFalse(Thread.isMainThread); metadata.append("items")
            return board.pasteboardItems
        }
        monitor.readItemTypes = {
            XCTAssertFalse(Thread.isMainThread); metadata.append("types")
            return $0.types
        }
        monitor.makeEntry = { items, source in
            XCTAssertFalse(Thread.isMainThread); metadata.append("summary")
            XCTAssertEqual(source, "example.editor")
            return HistoryEntry(source: .clipboard, sourceAppBundleID: source, items: items)
        }
        monitor.onStatusChange = { _ in XCTAssertTrue(Thread.isMainThread); statuses += 1 }
        store.onChange = { XCTAssertTrue(Thread.isMainThread); merges += 1 }
        copy("denied fixture", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertNotNil(monitor.status)
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertEqual(statuses, 1)
        XCTAssertEqual(merges, 0)
        denied = false
        copy("allowed fixture", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(metadata, ["root", "items", "types", "summary"])
        XCTAssertNil(monitor.status)
        XCTAssertEqual(statuses, 2)
        XCTAssertEqual(merges, 1)
        XCTAssertEqual(store.entries.first?.plainText, "allowed fixture")
    }

    func testSummaryConversionKeepsMainResponsiveAndRejectsInvalidatedResult() {
        for boundary in ["suspend", "new-copy"] {
            let board = scratchBoard()
            let store = HistoryStore(policy: .init(captureClipboard: true))
            let monitor = makeMonitor(board, store: store)
            let entered = expectation(description: "summary conversion started")
            let release = DispatchSemaphore(value: 0)
            var summaries = 0
            monitor.makeEntry = { items, source in
                XCTAssertFalse(Thread.isMainThread)
                summaries += 1
                if summaries == 1, !Thread.isMainThread {
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 8), .success)
                }
                return HistoryEntry(source: .clipboard, sourceAppBundleID: source, items: items)
            }
            copy("summary fixture", to: board)
            monitor.pollNow()
            wait(for: [entered], timeout: 2)
            let responsive = expectation(description: "main works during summary conversion")
            DispatchQueue.main.async { responsive.fulfill() }
            wait(for: [responsive], timeout: 1)
            if boundary == "suspend" { monitor.suspend(); monitor.resume() }
            copy("latest copy", to: board)
            for _ in 0..<5 { monitor.pollNow() }
            release.signal()
            flush(monitor)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(summaries, 1, "A blocked parser retains the sole reader slot")
            monitor.pollNow()
            flush(monitor)
            XCTAssertEqual(summaries, 2)
            XCTAssertEqual(store.entries.compactMap(\.plainText), ["latest copy"])
            XCTAssertEqual(store.entries.first?.sourceAppBundleID, "example.editor")
        }
    }

    func testBlockedMetadataKeepsMainResponsiveAndDoesNotQueueAnotherReader() {
        for stage in ["root", "items", "types"] {
          for boundary in ["invalidate", "new-copy"] {
            let board = scratchBoard()
            let store = HistoryStore(policy: .init(captureClipboard: true))
            let monitor = makeMonitor(board, store: store)
            let provider = Promise(), item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            board.clearContents()
            XCTAssertTrue(board.writeObjects([item]))
            let entered = expectation(description: "\(stage) metadata blocked")
            let release = DispatchSemaphore(value: 0)
            var calls = 0
            let blockOnce = {
                XCTAssertFalse(Thread.isMainThread)
                guard !Thread.isMainThread else { return }
                calls += 1
                if calls == 1 {
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 8), .success)
                }
            }
            monitor.readRootTypes = { if stage == "root" { blockOnce() }; return board.types ?? [] }
            monitor.readItems = { if stage == "items" { blockOnce() }; return board.pasteboardItems }
            monitor.readItemTypes = { if stage == "types" { blockOnce() }; return $0.types }
            monitor.pollNow()
            wait(for: [entered], timeout: 2)
            let responsive = expectation(description: "main works during metadata IPC")
            DispatchQueue.main.async { responsive.fulfill() }
            wait(for: [responsive], timeout: 1)
            if boundary == "invalidate" { monitor.suspend(); monitor.resume() }
            for index in 0..<5 {
                copy("new local copy \(index)", to: board)
                monitor.pollNow()
            }
            release.signal()
            flush(monitor)
            XCTAssertEqual(calls, 1, "Even an invalidated blocked read owns the sole reader slot")
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(provider.readCount, 0, "Stale metadata must not authorize any payload read")
            // The newest generation is admitted only after the old worker has returned.
            monitor.pollNow()
            flush(monitor)
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(store.entries.compactMap(\.plainText), ["new local copy 4"])
          }
        }
    }

    func testStartupAndResumeDoNotHarvestPriorClipboard() {
        let board = scratchBoard()
        copy("before consent", to: board)
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        monitor.pollNow()
        flush(monitor)
        XCTAssertTrue(store.entries.isEmpty)
        copy("new copy", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.first?.plainText, "new copy")
        monitor.suspend()
        copy("while suspended", to: board)
        monitor.resume()
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testClearInvalidatesCaptureAlreadyQueuedBeforeReturningToMain() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        copy("about to be cleared", to: board)
        monitor.pollNow()
        // The reader may already have obtained bytes, but it cannot publish until
        // main yields. Match the coordinator's clear boundary before that happens.
        monitor.suspend()
        store.clear()
        monitor.resume()
        flush(monitor)
        monitor.pollNow()
        flush(monitor)
        XCTAssertTrue(store.entries.isEmpty)
        copy("copied after clear", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["copied after clear"])
    }

    func testAllSensitiveAndOwnMarkersSkipBeforeLazyProviderRead() {
        for marker in ClipboardHistoryMonitor.ignoredTypes {
            let board = scratchBoard()
            let store = HistoryStore(policy: .init(captureClipboard: true))
            let monitor = makeMonitor(board, store: store)
            let provider = Promise()
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            if marker != "Pasteboard generator type" {
                XCTAssertTrue(item.setData(Data(), forType: .init(marker)))
            }
            board.clearContents()
            board.writeObjects([item])
            if marker == "Pasteboard generator type" {
                // Legacy flavor names are valid on NSPasteboard, but NOT on
                // NSPasteboardItem. Publish through the legacy root API so the
                // fixture really advertises the marker it asks us to respect.
                board.addTypes([.init(marker)], owner: nil)
                XCTAssertTrue(board.setData(Data(), forType: .init(marker)))
            }
            monitor.pollNow()
            flush(monitor)
            XCTAssertEqual(provider.readCount, 0, marker)
            XCTAssertTrue(store.entries.isEmpty, marker)
        }
    }

    func testMarkerOnLaterItemPreventsReadingAnyItem() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        let provider = Promise()
        let first = NSPasteboardItem()
        first.setDataProvider(provider, forTypes: [.string])
        let second = NSPasteboardItem()
        second.setString("secret", forType: .string)
        second.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents()
        board.writeObjects([first, second])
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(provider.readCount, 0)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRemoteRootMarkerSkipsItemEnumerationAndProviderThenAllowsNextLocalCopy() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        let provider = Promise()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        board.addTypes([PasteboardAccess.remoteClipboardType], owner: nil)
        XCTAssertTrue(board.types?.contains(PasteboardAccess.remoteClipboardType) == true)
        var itemEnumerations = 0
        monitor.readItems = {
            itemEnumerations += 1
            return board.pasteboardItems
        }

        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(itemEnumerations, 0, "Root remote offers must stop before item enumeration")
        XCTAssertEqual(provider.readCount, 0)
        XCTAssertTrue(store.entries.isEmpty)

        copy("new local copy", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(itemEnumerations, 1)
        XCTAssertEqual(provider.readCount, 0)
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["new local copy"])
    }

    func testRemoteMarkerOnLaterItemSkipsEveryLazyPayloadEvenWithoutRootMarker() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        let provider = Promise()
        let first = NSPasteboardItem()
        first.setDataProvider(provider, forTypes: [.string])
        let second = NSPasteboardItem()
        second.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(second.setData(Data(), forType: PasteboardAccess.remoteClipboardType))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([first, second]))
        // Explicitly exercise the item-only fallback, independently of whether this
        // OS aggregates all item types into the pasteboard's root list.
        monitor.readRootTypes = { [.string] }

        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(provider.readCount, 0, "A later remote marker must veto earlier promises too")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testBorrowAndDeniedAccessSkipBeforeLazyProviderRead() {
        for denied in [false, true] {
            let board = scratchBoard()
            let store = HistoryStore(policy: .init(captureClipboard: true))
            let monitor = makeMonitor(board, store: store)
            monitor.accessIsDenied = { denied }
            monitor.isClipboardBorrowed = { !denied }
            let provider = Promise()
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            board.clearContents()
            board.writeObjects([item])
            monitor.pollNow()
            flush(monitor)
            XCTAssertEqual(provider.readCount, 0)
            XCTAssertTrue(store.entries.isEmpty)
            if denied { XCTAssertNotNil(monitor.status) }
        }
    }

    func testExactIgnoredRestoreDoesNotSuppressNextRealCopy() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        copy("own restore", to: board)
        monitor.ignore(changeCount: board.changeCount)
        monitor.pollNow()
        copy("external copy", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["external copy"])
    }

    func testAppTransitionAndExcludedAppAreNotCaptured() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        var source = "com.1password.1password"
        monitor.sourceAppBundleID = { source }
        copy("transition", to: board)
        monitor.pollNow()
        copy("excluded", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertTrue(store.entries.isEmpty)
        source = "example.editor"
        monitor.pollNow()
        copy("allowed", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.first?.plainText, "allowed")
    }

    func testActivationBaselineAllowsCopyBeforeFirstPollWithoutImportingOldClipboard() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        copy("old application's stale clipboard", to: board)
        monitor.sourceAppBundleID = { "example.new-editor" }
        monitor.applicationDidActivate()
        // A normal copy immediately after switching apps must survive the first timer tick.
        copy("copied after activation", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["copied after activation"])
        XCTAssertEqual(store.entries.first?.sourceAppBundleID, "example.new-editor")
    }

    func testMultiItemRichCaptureAndReplayAreByteExact() throws {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        let first = NSPasteboardItem()
        first.setString("  rich\n", forType: .string)
        first.setData(Data(#"{\rtf1\b rich}"#.utf8), forType: .rtf)
        first.setData(Data("<b>rich</b>".utf8), forType: .html)
        first.setData(Data([0, 1, 255, 77]), forType: .rtfd)
        let second = NSPasteboardItem()
        second.setData(Data([137, 80, 78, 71]), forType: .png)
        second.setData(Data([73, 73, 42, 0]), forType: .tiff)
        second.setData(Data([255, 216, 255]), forType: .init("public.jpeg"))
        second.setData(Data("%PDF-1.7 synthetic".utf8), forType: .pdf)
        let third = NSPasteboardItem()
        third.setString("file:///not-read/reference.png", forType: .fileURL)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([first, second, third]))
        let before = try XCTUnwrap(board.pasteboardItems).map { item in
            HistoryPasteboardItem(representations: item.types.filter { HistoryEntry.supportedTypes.contains($0.rawValue) }.map {
                HistoryRepresentation(type: $0.rawValue, data: item.data(forType: $0)!)
            })
        }
        monitor.pollNow()
        flush(monitor)
        let entry = try XCTUnwrap(store.entries.first)
        let expected = before.map { item -> HistoryPasteboardItem in
            let omitted = item.data(forType: .png) == nil ? [] : item.representations.filter { $0.type == "public.tiff" }.map(\.type)
            return .init(representations: item.representations.filter { !omitted.contains($0.type) },
                         omittedRepresentationTypes: omitted)
        }
        XCTAssertEqual(entry.items, expected)
        XCTAssertNotNil(entry.representationNote)
        let replay = scratchBoard()
        XCTAssertTrue(replay.writeObjects(entry.makePasteboardItems()))
        let after = try XCTUnwrap(replay.pasteboardItems).map { item in
            HistoryPasteboardItem(representations: item.types.filter { HistoryEntry.supportedTypes.contains($0.rawValue) }.map {
                HistoryRepresentation(type: $0.rawValue, data: item.data(forType: $0)!)
            })
        }
        XCTAssertEqual(after.map(\.representations), expected.map(\.representations))
    }

    func testLosslessPNGDoesNotMaterializeAlternateTIFFPromise() throws {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true, maximumEntryBytes: 16))
        let monitor = makeMonitor(board, store: store)
        let provider = Promise()
        let item = NSPasteboardItem()
        item.setData(Data([137, 80, 78, 71]), forType: .png)
        item.setDataProvider(provider, forTypes: [.tiff])
        board.clearContents()
        board.writeObjects([item])
        monitor.pollNow()
        flush(monitor)
        let captured = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(provider.readCount, 0, "PNG must avoid triggering an expanded TIFF")
        XCTAssertEqual(captured.items[0].representations.map(\.type), ["public.png"])
        XCTAssertEqual(captured.items[0].omittedRepresentationTypes, ["public.tiff"])
        XCTAssertNotNil(captured.representationNote)
    }

    func testJPEGWithTIFFRetainsBothInsteadOfImplicitLossySubstitution() throws {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        let item = NSPasteboardItem()
        let jpeg = Data([255, 216, 255])
        let tiff = Data([73, 73, 42, 0])
        item.setData(jpeg, forType: .init("public.jpeg"))
        item.setData(tiff, forType: .tiff)
        board.clearContents()
        board.writeObjects([item])
        monitor.pollNow()
        flush(monitor)
        let captured = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(captured.items[0].data(forType: .tiff), tiff)
        XCTAssertEqual(captured.items[0].data(forType: .init("public.jpeg")), jpeg)
        XCTAssertNil(captured.representationNote)
    }

    func testOversizeAndUnreadableRepresentationSkipWholeEntryWithVisibleStatus() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true, maximumEntryBytes: 4))
        let monitor = makeMonitor(board, store: store)
        copy("longer than four bytes", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(monitor.status)
    }

    func testChangeDuringCaptureCannotCommitAnOlderGeneration() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        copy("first", to: board)
        monitor.pollNow()
        copy("second", to: board)
        flush(monitor)
        XCTAssertTrue(store.entries.isEmpty)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.first?.plainText, "second")
    }

    func testSecureInputSkipsLazyProviderAndDoesNotHarvestSkippedClipboardLater() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        var secure = true
        monitor.secureInputIsActive = { secure }
        let provider = Promise()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        board.writeObjects([item])
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(provider.readCount, 0)
        XCTAssertTrue(store.entries.isEmpty)
        secure = false
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(provider.readCount, 0, "Ending Secure Input must not harvest its skipped generation")
        copy("new nonsecure copy", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["new nonsecure copy"])
    }

    func testSecureInputActivatingBeforeCaptureCommitDropsPendingEntry() {
        let board = scratchBoard()
        let store = HistoryStore(policy: .init(captureClipboard: true))
        let monitor = makeMonitor(board, store: store)
        var secure = false
        monitor.secureInputIsActive = { secure }
        copy("pending copy", to: board)
        monitor.pollNow()
        secure = true
        copy("copied while secure", to: board)
        flush(monitor)
        XCTAssertTrue(store.entries.isEmpty)
        secure = false
        monitor.pollNow()
        flush(monitor)
        XCTAssertTrue(store.entries.isEmpty, "The commit-time secure guard must baseline any skipped generation")
        copy("fresh copy", to: board)
        monitor.pollNow()
        flush(monitor)
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["fresh copy"])
    }
    func testInvalidatedCaptureStopsReadingFurtherPromisedFormats() {
        final class CancellingPromise: NSObject, NSPasteboardItemDataProvider {
            var reads: [NSPasteboard.PasteboardType] = []
            var onFirstRead: (() -> Void)?
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                            provideDataForType type: NSPasteboard.PasteboardType) {
                item.setData(Data("synthetic representation".utf8), forType: type)
                let record = {
                    self.reads.append(type)
                    if self.reads.count == 1 { self.onFirstRead?() }
                }
                if Thread.isMainThread { record() }
                else { DispatchQueue.main.sync(execute: record) }
            }
        }
        for boundary in ["disable", "suspend", "stop", "activation", "secure-input"] {
            let board = scratchBoard()
            let store = HistoryStore(policy: .init(captureClipboard: true))
            let monitor = makeMonitor(board, store: store)
            var secure = false
            monitor.secureInputIsActive = { secure }
            let provider = CancellingPromise()
            provider.onFirstRead = {
                switch boundary {
                case "disable": monitor.setEnabled(false)
                case "suspend": monitor.suspend()
                case "stop": monitor.stop()
                case "activation": monitor.applicationDidActivate()
                default: secure = true; monitor.pollNow()
                }
            }
            let first = NSPasteboardItem()
            first.setDataProvider(provider, forTypes: [.png])
            let second = NSPasteboardItem()
            second.setDataProvider(provider, forTypes: [.png])
            board.clearContents()
            XCTAssertTrue(board.writeObjects([first, second]))
            monitor.pollNow()
            flush(monitor)
            XCTAssertEqual(provider.reads, [.png], boundary)
            XCTAssertTrue(store.entries.isEmpty, boundary)
            provider.onFirstRead = nil
            withExtendedLifetime(provider) {}
        }
    }

}
