// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_core · 2026-10-01
import AppKit
import XCTest
@testable import SpeakFreeLib

final class HistoryStoreTests: XCTestCase {
    private func scratchURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speakfree-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("private/history.plist")
    }

    private func flush(_ store: HistoryStore) {
        let ready = expectation(description: "history I/O finished")
        store.flushForTesting { ready.fulfill() }
        wait(for: [ready], timeout: 4)
    }

    func testSessionDefaultPreservesExactDictationButDoesNotCaptureClipboardOrPersist() throws {
        let url = try scratchURL()
        let store = HistoryStore(fileURL: url)
        let text = "  one\n\t two  \n"
        store.addDictation(text, sourceAppBundleID: "example.editor", linkedArchiveID: "recording-1")
        store.addClipboard(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data("copy".utf8))])])
        flush(store)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].plainText, text)
        XCTAssertEqual(store.entries[0].linkedArchiveID, "recording-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDisablingDictationCaptureKeepsExistingHistoryAndClipboardCopyIsDistinct() {
        let store = HistoryStore(policy: .init(captureClipboard: true))
        store.addDictation("same")
        store.configure(.init(captureDictations: false, captureClipboard: true))
        XCTAssertNil(store.addDictation("new"))
        store.addClipboard(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data("same".utf8))])])
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(Set(store.entries.map(\.source)), [.dictation, .clipboard])
        XCTAssertEqual(store.filtered(source: .dictation, query: "SAME").count, 1)
    }

    func testPreparedClipboardStillRequiresCurrentCapturePolicyAndCorrectSource() {
        let items = [HistoryPasteboardItem(representations: [
            .init(type: "public.utf8-plain-text", data: Data("synthetic".utf8))])]
        let prepared = HistoryEntry(source: .clipboard, items: items)
        let store = HistoryStore(policy: .init(captureClipboard: true))
        store.configure(.init(captureClipboard: false))
        XCTAssertNil(store.addClipboard(prepared))
        store.configure(.init(captureClipboard: true))
        XCTAssertNil(store.addClipboard(HistoryEntry(source: .dictation, items: items)))
        XCTAssertEqual(store.addClipboard(prepared), prepared)
        XCTAssertEqual(store.entries, [prepared])
    }

    func testRichMultiItemPersistenceRetainsBytesTypesOrderAndPrivateFileMode() throws {
        let url = try scratchURL()
        let policy = HistoryStore.Policy(captureClipboard: true, persistent: true)
        let store = HistoryStore(fileURL: url, policy: policy)
        flush(store)
        let items: [HistoryPasteboardItem] = [
            .init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("  rich\n".utf8)),
                .init(type: "public.rtf", data: Data(#"{\rtf1\b rich}"#.utf8)),
                .init(type: "com.apple.flat-rtfd", data: Data([0, 255, 21])),
                .init(type: "public.html", data: Data("<b>rich</b>".utf8))
            ]),
            .init(representations: [.init(type: "public.png", data: Data([137, 80, 78, 71])),
                                    .init(type: "public.tiff", data: Data([73, 73, 42, 0])),
                                    .init(type: "public.jpeg", data: Data([255, 216, 255])),
                                    .init(type: "com.adobe.pdf", data: Data("%PDF-1.7 synthetic".utf8))]),
            .init(representations: [.init(type: "public.file-url", data: Data("file:///not-read/example.pdf".utf8))])
        ]
        let saved = try XCTUnwrap(store.addClipboard(items: items, sourceAppBundleID: "example.writer"))
        flush(store)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let parentPermissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(parentPermissions?.intValue, 0o700)
        let restored = HistoryStore(fileURL: url, policy: policy)
        flush(restored)
        XCTAssertNil(restored.lastError)
        XCTAssertEqual(restored.entries, [saved])
        XCTAssertEqual(restored.entries[0].items, items)
        XCTAssertTrue(restored.entries[0].containsImage)
        XCTAssertTrue(restored.entries[0].containsFiles)
    }

    func testAgeCountAndByteBoundsNeverPartiallyTruncateAnItem() {
        var time = Date(timeIntervalSince1970: 10_000)
        let store = HistoryStore(policy: .init(maximumEntries: 2, maximumAge: 10,
                                               maximumBytes: 8, maximumEntryBytes: 5), now: { time })
        store.addDictation("1111")
        time += 1
        store.addDictation("2222")
        time += 1
        store.addDictation("3333")
        XCTAssertEqual(store.entries.compactMap(\.plainText), ["3333", "2222"])
        XCTAssertNil(store.addDictation("too big"))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertNotNil(store.lastError)
        time += 11
        store.pruneExpired()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDisablePersistenceRemovesSavedStorageButKeepsSession() throws {
        let url = try scratchURL()
        let store = HistoryStore(fileURL: url, policy: .init(persistent: true))
        flush(store)
        store.addDictation("keep in session")
        flush(store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.configure(.init(persistent: false))
        flush(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.entries.first?.plainText, "keep in session")
    }

    func testRestartWithSessionPolicyRemovesPreviouslySavedArchiveWithoutLoadingIt() throws {
        let url = try scratchURL()
        let oldStore = HistoryStore(fileURL: url, policy: .init(persistent: true))
        oldStore.addDictation("saved in a previous run")
        flush(oldStore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // A changed on-disk setting or a previously failed removal must not leave this
        // archive behind. The coordinator's identical configure call is deliberately a no-op.
        let restarted = HistoryStore(fileURL: url, policy: .init(persistent: false))
        restarted.configure(.init(persistent: false))
        flush(restarted)
        XCTAssertTrue(restarted.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(restarted.lastError)
    }

    func testEnablingPersistenceImmediatelyAfterSessionStartupDoesNotReloadOldArchive() throws {
        let url = try scratchURL()
        let previous = HistoryStore(fileURL: url, policy: .init(persistent: true))
        previous.addDictation("previous session")
        flush(previous)
        let current = HistoryStore(fileURL: url, policy: .init(persistent: false))
        current.addDictation("current session")
        current.configure(.init(persistent: true))
        flush(current)
        XCTAssertEqual(current.entries.compactMap(\.plainText), ["current session"])
        let restored = HistoryStore(fileURL: url, policy: .init(persistent: true))
        flush(restored)
        XCTAssertEqual(restored.entries.compactMap(\.plainText), ["current session"])
    }

    func testClearDuringLoadDoesNotResurrectEntriesAndLinkedRemovalDoesNotClearOthers() throws {
        let url = try scratchURL()
        let original = HistoryStore(fileURL: url, policy: .init(persistent: true))
        flush(original)
        original.addDictation("old", linkedArchiveID: "archive")
        flush(original)
        let loading = HistoryStore(fileURL: url, policy: .init(persistent: true))
        loading.clear()
        loading.addDictation("new", linkedArchiveID: "new-archive")
        flush(loading)
        XCTAssertEqual(loading.entries.compactMap(\.plainText), ["new"])
        loading.addDictation("independent")
        loading.removeLinkedArchive(id: "new-archive")
        XCTAssertEqual(loading.entries.compactMap(\.plainText), ["independent"])
    }

    func testBatchRemovalDeletesOnlyConfirmedIDsAndPublishesOnce() throws {
        let url = try scratchURL()
        let policy = HistoryStore.Policy(persistent: true)
        let store = HistoryStore(fileURL: url, policy: policy)
        flush(store)
        let first = try XCTUnwrap(store.addDictation("first match", linkedArchiveID: "saved-recording-one"))
        let second = try XCTUnwrap(store.addDictation("second match"))
        let later = try XCTUnwrap(store.addDictation("later match"))
        var notifications = 0
        store.onChange = { notifications += 1 }
        store.remove(ids: [first.id, second.id, first.id])
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.entries.map(\.id), [later.id])
        flush(store)
        let restored = HistoryStore(fileURL: url, policy: policy)
        flush(restored)
        XCTAssertEqual(restored.entries.map(\.id), [later.id])
    }

    func testBatchRemovalDuringLoadCannotResurrectConfirmedIDs() throws {
        let url = try scratchURL()
        let policy = HistoryStore.Policy(persistent: true)
        let original = HistoryStore(fileURL: url, policy: policy)
        flush(original)
        let removed = try XCTUnwrap(original.addDictation("remove"))
        let retained = try XCTUnwrap(original.addDictation("retain"))
        flush(original)
        let loading = HistoryStore(fileURL: url, policy: policy)
        loading.remove(ids: [removed.id])
        flush(loading)
        XCTAssertEqual(loading.entries.map(\.id), [retained.id])
        let restarted = HistoryStore(fileURL: url, policy: policy)
        flush(restarted)
        XCTAssertEqual(restarted.entries.map(\.id), [retained.id])
    }

    func testUnreadableHistoryShowsErrorAndIsNotOverwrittenUntilExplicitClear() throws {
        let url = try scratchURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not a history archive".utf8)
        try corrupt.write(to: url)
        let store = HistoryStore(fileURL: url, policy: .init(persistent: true))
        flush(store)
        XCTAssertNotNil(store.lastError)
        store.addDictation("session only")
        flush(store)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        store.clear()
        flush(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.lastError)
    }

    func testWriteFailureIsVisibleAndSessionRemainsUsable() throws {
        let url = try scratchURL()
        let parent = url.deletingLastPathComponent()
        try Data("a file cannot be a directory".utf8).write(to: parent)
        let store = HistoryStore(fileURL: url, policy: .init(persistent: true))
        flush(store)
        store.addDictation("still accessible")
        flush(store)
        XCTAssertEqual(store.entries.first?.plainText, "still accessible")
        XCTAssertNotNil(store.lastError)
    }

    func testExplicitImportKeepsOriginalDatesAndLinksDedupesArchiveButNotText() {
        let current = Date(timeIntervalSince1970: 20_000)
        let store = HistoryStore(policy: .init(maximumAge: 100), now: { current })
        func entry(_ text: String, age: TimeInterval, archive: String?) -> HistoryEntry {
            .init(createdAt: current.addingTimeInterval(-age), source: .dictation, linkedArchiveID: archive,
                  items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])])
        }
        let first = entry("same words", age: 10, archive: "first")
        let second = entry("same words", age: 20, archive: "second")
        let duplicate = entry("edited words", age: 5, archive: "first")
        let expired = entry("expired", age: 200, archive: "expired")
        XCTAssertEqual(store.importDictations([first, second, duplicate, expired]), 2)
        XCTAssertEqual(store.entries, [first, second])
        XCTAssertEqual(store.importDictations([first, second]), 0)
        store.configure(.init(captureDictations: false))
        XCTAssertEqual(store.importDictations([entry("off", age: 0, archive: "off")]), 0)
        XCTAssertEqual(store.entries.count, 2)
    }

    func testSearchAndPreviewAreBoundedWithoutChangingHugeTextReplay() throws {
        let text = "visible prefix " + String(repeating: "x", count: HistoryEntry.searchByteLimit + 20_000) + "outside-index"
        let entry = HistoryEntry(source: .clipboard, items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data(text.utf8))])])
        XCTAssertTrue(entry.matches("visible prefix"))
        XCTAssertFalse(entry.matches("outside-index"))
        XCTAssertTrue(entry.searchWasTruncated)
        XCTAssertLessThanOrEqual(entry.displayTitle.count, 180)
        XCTAssertEqual(entry.plainText, text)
        XCTAssertEqual(entry.makePasteboardItems()[0].string(forType: .string), text)
        let restored = try PropertyListDecoder().decode(HistoryEntry.self, from: PropertyListEncoder().encode(entry))
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(restored.byteCount, text.utf8.count)
    }

    func testFileReferenceShowsAndSearchesFilenameWithoutReadingTheFile() {
        let entry = HistoryEntry(source: .clipboard, items: [.init(representations: [
            .init(type: "public.file-url", data: Data("file:///missing-private-directory/Design%20notes.pdf".utf8))])])
        XCTAssertEqual(entry.displayTitle, "Design notes.pdf")
        XCTAssertTrue(entry.matches("notes.pdf"))
        XCTAssertFalse(entry.displayTitle.contains("missing-private-directory"))
        XCTAssertEqual(entry.byteCount, entry.items[0].byteCount)
        XCTAssertFalse(entry.formattedSize.isEmpty)
    }

    func testUnchangedAndCaptureOnlyConfigurationDoNotRewriteArchive() throws {
        let url = try scratchURL()
        let policy = HistoryStore.Policy(persistent: true)
        let store = HistoryStore(fileURL: url, policy: policy)
        store.addDictation("saved")
        flush(store)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        let revision = store.revision
        store.configure(policy)
        flush(store)
        XCTAssertEqual(store.revision, revision)
        var captureOnly = policy
        captureOnly.captureClipboard = true
        store.configure(captureOnly)
        flush(store)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode)
        let reloaded = HistoryStore(fileURL: url, policy: policy)
        flush(reloaded)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode,
                       "A clean startup must not rewrite unchanged saved history")
    }

    func testProductionFlushDrainsInitialLoadLatestWriteAndPendingDeletion() throws {
        let url = try scratchURL()
        let store = HistoryStore(fileURL: url, policy: .init(persistent: true))
        store.addDictation("first")
        let saved = expectation(description: "initial load and final write drained")
        store.flushPendingPersistence { result in
            if case .failure(let error) = result { XCTFail("Unexpected save failure: \(error.localizedDescription)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            saved.fulfill()
        }
        store.addDictation("last before quit")
        wait(for: [saved], timeout: 4)
        let reloaded = HistoryStore(fileURL: url, policy: .init(persistent: true))
        flush(reloaded)
        XCTAssertEqual(reloaded.entries.count, 2)
        store.configure(.init(persistent: false))
        let removed = expectation(description: "pending deletion drained")
        store.flushPendingPersistence { result in
            if case .failure(let error) = result { XCTFail("Unexpected deletion failure: \(error.localizedDescription)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            removed.fulfill()
        }
        wait(for: [removed], timeout: 4)
    }

    func testProductionFlushReportsLoadAndWriteFailures() throws {
        let corruptURL = try scratchURL()
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid archive".utf8).write(to: corruptURL)
        let corrupt = HistoryStore(fileURL: corruptURL, policy: .init(persistent: true))
        corrupt.addDictation("new text must survive the unreadable archive")
        let failedLoad = expectation(description: "load error returned")
        corrupt.flushPendingPersistence { result in
            if case .success = result { XCTFail("Unsaved session text still requires an explicit quit decision") }
            failedLoad.fulfill()
        }
        wait(for: [failedLoad], timeout: 4)
        let blockedURL = try scratchURL()
        try Data("not a directory".utf8).write(to: blockedURL.deletingLastPathComponent())
        let blocked = HistoryStore(fileURL: blockedURL, policy: .init(persistent: true))
        blocked.addDictation("cannot save")
        let failedWrite = expectation(description: "write error returned")
        blocked.flushPendingPersistence { result in
            if case .success = result { XCTFail("A failed save cannot acknowledge a successful termination flush") }
            failedWrite.fulfill()
        }
        wait(for: [failedWrite], timeout: 4)
    }

    func testUnreadableUntouchedArchiveDoesNotBlockQuitOrChangeItsBytes() throws {
        let url = try scratchURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("unsupported future archive fixture".utf8)
        try bytes.write(to: url)
        let store = HistoryStore(fileURL: url, policy: .init(persistent: true))
        for _ in 0..<2 {
            let completed = expectation(description: "unchanged unreadable archive permits quit")
            store.flushPendingPersistence { result in
                if case .failure(let error) = result { XCTFail("Nothing new needs saving: \(error)") }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 4)
            XCTAssertNotNil(store.lastError, "The loading problem must remain visible")
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), bytes, "Quit must not reset unknown saved data")
        }
    }

    func testUnreadableArchiveCannotAcknowledgeUnappliedDeletionEvenWithNoSessionText() throws {
        for duringLoad in [true, false] {
            let url = try scratchURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("unsupported archive with unknown entries".utf8)
            try bytes.write(to: url)
            let store = HistoryStore(fileURL: url, policy: .init(persistent: true))
            if !duringLoad { flush(store) }
            store.removeLinkedArchive(id: "recording-synthetic-deleted")
            let failed = expectation(description: "unapplied deletion remains a quit blocker")
            store.flushPendingPersistence { result in
                if case .success = result { XCTFail("An unreadable archive may still contain the removed recording's text") }
                failed.fulfill()
            }
            wait(for: [failed], timeout: 4)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            store.clear()
            let cleared = expectation(description: "explicit clearing resolves the deletion")
            store.flushPendingPersistence { result in
                if case .failure(let error) = result { XCTFail("Explicit clear should resolve the archive: \(error)") }
                cleared.fulfill()
            }
            wait(for: [cleared], timeout: 4)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testQuitDrainCompletesInsideMainDispatchNestedRunLoop() throws {
        for persistent in [true, false] {
            let url = try scratchURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !persistent { try Data("old saved copy".utf8).write(to: url) }
            let completed = expectation(description: "nested termination loop drains load/write/delete")
            DispatchQueue.main.async {
                let store = HistoryStore(fileURL: url, policy: .init(persistent: persistent))
                if persistent { store.addDictation("new synthetic text before quit") }
                var result: Result<Void, Error>?
                store.flushPendingPersistence { result = $0 }
                // Match an external terminate() called from main-dispatch work:
                // nested run-loop sources may run, but main dispatch cannot re-enter.
                let deadline = Date().addingTimeInterval(2)
                while result == nil && Date() < deadline {
                    _ = RunLoop.current.run(mode: .default, before: deadline)
                }
                guard let result else {
                    XCTFail("Quit completion depended on re-entering the main dispatch queue")
                    completed.fulfill()
                    return
                }
                if case .failure(let error) = result { XCTFail("Unexpected quit failure: \(error)") }
                XCTAssertEqual(FileManager.default.fileExists(atPath: url.path), persistent)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 4)
            if persistent {
                let restarted = HistoryStore(fileURL: url, policy: .init(persistent: true))
                flush(restarted)
                XCTAssertEqual(restarted.entries.compactMap(\.plainText), ["new synthetic text before quit"])
            }
        }
    }
}
