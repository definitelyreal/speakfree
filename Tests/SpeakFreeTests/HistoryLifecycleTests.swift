// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-05
import AppKit
import XCTest
@testable import SpeakFreeLib

@MainActor
final class HistoryLifecycleTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("history-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
    }

    override func tearDown() async throws {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    func testOnlyBusyInteractiveQuitRequiresExplicitConfirmation() {
        XCTAssertTrue(AppDelegate.TerminationIntent.interactive.requiresConfirmation(isBusy: true))
        XCTAssertFalse(AppDelegate.TerminationIntent.interactive.requiresConfirmation(isBusy: false))
        XCTAssertFalse(AppDelegate.TerminationIntent.confirmedByUser.requiresConfirmation(isBusy: true))
        XCTAssertFalse(AppDelegate.TerminationIntent.signalDrain.requiresConfirmation(isBusy: true))
    }

    func testUninsertedTextSurvivesWithoutRecordingsUntilItsExplicitCopy() {
        let menu = StatusBarController()
        menu.retainUninsertedDictation("First synthetic result")
        menu.retainUninsertedDictation("Second synthetic result")
        XCTAssertEqual(menu.uninsertedDictations.map(\.text), ["Second synthetic result", "First synthetic result"])
        menu.didCopyUninsertedDictation(id: menu.uninsertedDictations[1].id)
        XCTAssertEqual(menu.uninsertedDictations.map(\.text), ["Second synthetic result"])
        let files = (try? FileManager.default.contentsOfDirectory(atPath: RecordingStore.recordingsDir.path)) ?? []
        XCTAssertTrue(files.filter(RecordingStore.isRecordingArtifact).isEmpty,
                      "Session recovery must not persist recording or transcript artifacts")
    }

    func testArchiveDeletionNotifiesExactIDsAndEvictsLinkedHistory() throws {
        let board = NSPasteboard(name: .init("speakfree.test.archive-removal.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let archive = RecordingStore.newRecordingURL()
        try Data("synthetic".utf8).write(to: archive)
        let archiveID = archive.deletingPathExtension().lastPathComponent
        let store = HistoryStore()
        store.addDictation("Saved synthetic result", sourceAppBundleID: nil, linkedArchiveID: archiveID)
        store.addDictation("Session synthetic result", sourceAppBundleID: nil, linkedArchiveID: nil)
        var environment = HistoryCoordinator.Environment()
        environment.usesSystemServices = false
        let coordinator = HistoryCoordinator(config: .defaultConfig, inserter: { nil }, isBusy: { false },
            environment: environment, store: store, pasteboard: board)
        let received = expectation(description: "main-thread archive removal")
        let observer = NotificationCenter.default.addObserver(forName: RecordingStore.archivesRemoved,
            object: nil, queue: .main) { note in
                guard note.object as? URL == archive.deletingLastPathComponent().standardizedFileURL else { return }
                let ids = note.userInfo?["archiveIDs"] as? [String]
                XCTAssertEqual(ids, [archiveID])
                for id in ids ?? [] { coordinator.removeArchivedDictation(id: id) }
                received.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(RecordingStore.deleteAllRecordings().succeeded)
        wait(for: [received], timeout: 2)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNil(store.entries.first?.linkedArchiveID)
    }
}
