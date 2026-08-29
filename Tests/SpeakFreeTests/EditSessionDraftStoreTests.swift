import XCTest
@testable import SpeakFreeLib

/// Consent-bound draft persistence (C5): nothing is written unless saving is enabled; when it is,
/// the draft is a 0600 file in the 0700 config dir, round-trips, and expires after 24h. Every test
/// redirects Config.configDirOverride to a scratch dir (2026-06-11 rule).
final class EditSessionDraftStoreTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-draft-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func sampleState(updatedAt: Date = Date()) -> EditSessionState {
        var s = EditSessionState(id: UUID(), createdAt: updatedAt, updatedAt: updatedAt)
        var seg = EditSegment(id: UUID(), state: .provisional)
        seg.appendRevision(text: "hello world", origin: .asr, timestamp: updatedAt)
        s.segments = [seg]
        return s
    }

    private var draftExists: Bool {
        FileManager.default.fileExists(atPath: EditSessionDraftStore.draftURL.path)
    }

    // MARK: - Consent OFF → nothing persists

    func testDisabledStoreNeverWrites() {
        let store = EditSessionDraftStore(enabled: false)
        store.flush(sampleState())        // even an explicit flush is a no-op when saving is off
        store.schedule(sampleState())
        XCTAssertFalse(draftExists, "no draft file when saving is off — Esc leaves no trace")
    }

    // MARK: - Consent ON → 0600 file, round-trips

    func testEnabledStoreFlushWritesSecureFile() throws {
        let store = EditSessionDraftStore(enabled: true)
        let state = sampleState()
        store.flush(state)

        XCTAssertTrue(draftExists)
        let attrs = try FileManager.default.attributesOfItem(atPath: EditSessionDraftStore.draftURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600, "draft file must be owner-only")
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: scratchDir.path)
        XCTAssertEqual(dirAttrs[.posixPermissions] as? Int, 0o700, "config dir must be 0700")

        let loaded = EditSessionDraftStore.load()
        XCTAssertEqual(loaded?.id, state.id)
        XCTAssertEqual(loaded?.segments.first?.currentText, "hello world")
    }

    func testEnabledStoreDebouncedScheduleEventuallyWrites() {
        let store = EditSessionDraftStore(enabled: true, debounce: 0.05)
        store.schedule(sampleState())
        // Poll (generously) rather than assert immediately — schedule is debounced.
        let deadline = Date().addingTimeInterval(3)
        while !draftExists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(draftExists, "a debounced schedule writes the draft within its interval")
    }

    // MARK: - Expiry

    func testExpiredDraftNotLoaded() {
        let store = EditSessionDraftStore(enabled: true)
        let old = Date().addingTimeInterval(-25 * 3600)   // 25h ago
        store.flush(sampleState(updatedAt: old))
        XCTAssertTrue(draftExists, "the file is on disk")
        XCTAssertNil(EditSessionDraftStore.load(), "but a >24h-old draft is not offered for recovery")
    }

    func testFreshDraftLoadedWithinWindow() {
        let store = EditSessionDraftStore(enabled: true)
        store.flush(sampleState(updatedAt: Date().addingTimeInterval(-3600)))  // 1h ago
        XCTAssertNotNil(EditSessionDraftStore.load())
    }

    func testClearRemovesDraft() {
        let store = EditSessionDraftStore(enabled: true)
        store.flush(sampleState())
        XCTAssertTrue(draftExists)
        EditSessionDraftStore.clear()
        XCTAssertFalse(draftExists)
    }

    // MARK: - Model wiring (consent flows through dispatch)

    @MainActor
    func testModelWithSavingOffNeverWritesDraft() {
        let model = EditSessionModel(persistenceEnabled: false)
        let segID = UUID()
        model.dispatch(.beginSegment(segmentID: segID))
        model.dispatch(.provisional(segmentID: segID, raw: "r", pipelineText: "hello"))
        model.dispatch(.cancel)   // cancel flushes — but saving is off, so still nothing
        XCTAssertFalse(draftExists)
    }

    @MainActor
    func testModelWithSavingOnFlushesOnCancel() {
        let model = EditSessionModel(sessionID: UUID(), persistenceEnabled: true)
        let segID = UUID()
        model.dispatch(.beginSegment(segmentID: segID))
        model.dispatch(.provisional(segmentID: segID, raw: "r", pipelineText: "hello"))
        model.dispatch(.cancel)   // cancel flushes synchronously
        XCTAssertTrue(draftExists)
        XCTAssertEqual(EditSessionDraftStore.load()?.lifecycle, .cancelled)
    }

    @MainActor
    func testModelCommitClearsDraft() {
        let model = EditSessionModel(sessionID: UUID(), persistenceEnabled: true)
        let segID = UUID()
        model.dispatch(.beginSegment(segmentID: segID))
        model.dispatch(.provisional(segmentID: segID, raw: "r", pipelineText: "hello"))
        model.dispatch(.terminate)  // flush → draft exists
        XCTAssertTrue(draftExists)

        let model2 = EditSessionModel(sessionID: UUID(), persistenceEnabled: true)
        let seg2 = UUID()
        model2.dispatch(.beginSegment(segmentID: seg2))
        model2.dispatch(.commit)    // commit clears the draft
        XCTAssertFalse(draftExists)
    }
}
