import XCTest
@testable import SpeakFreeLib

/// Batch F (perf adjudication, findings 6/7/8): finalize micro-cost fixes living entirely
/// inside the leaf files — Config vocab/overrides mtime cache, GlossaryCorrector reorder,
/// UsageStats off-main save.
final class PerfBatchFTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perf-batch-f-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        Config.configDirOverride = tmpDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func write(_ text: String, to url: URL, mtime: Date) {
        // Non-atomic write: overwrites an existing file IN PLACE, preserving its inode.
        try! text.data(using: .utf8)!.write(to: url)
        try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func inode(of url: URL) -> Int {
        let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? Int) ?? -1
    }

    // MARK: - F1: vocabulary mtime cache

    // write → load → modify → load returns the new value.
    func test_loadVocabulary_invalidatesWhenFileChanges() {
        let file = Config.vocabularyFile
        write("Alpha\n", to: file, mtime: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(Config.loadVocabulary(), "Alpha")

        // Change content AND bump mtime → cache must yield the new value.
        write("Bravo\n", to: file, mtime: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(Config.loadVocabulary(), "Bravo")
    }

    // The cache is actually consulted: an in-place overwrite (SAME inode) with an unchanged
    // (mtime, size) stamp serves the cached parse even though the bytes on disk were swapped.
    func test_loadVocabulary_servesCacheWhenStampAndInodeUnchanged() {
        let file = Config.vocabularyFile
        let t = Date(timeIntervalSince1970: 1000)
        write("Alpha\n", to: file, mtime: t)
        XCTAssertEqual(Config.loadVocabulary(), "Alpha")
        let inode0 = inode(of: file)

        // In-place overwrite keeps the inode; same length + same mtime → identical stamp → cache hit.
        write("Bravo\n", to: file, mtime: t)
        XCTAssertEqual(inode(of: file), inode0, "precondition: in-place overwrite preserves the inode")
        XCTAssertEqual(Config.loadVocabulary(), "Alpha")

        // Bump only the mtime → invalidates.
        try! FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3000)], ofItemAtPath: file.path)
        XCTAssertEqual(Config.loadVocabulary(), "Bravo")
    }

    // Finding 4: a timestamp-PRESERVING replacement (Dropbox sync/restore) swaps the file to a
    // new inode while keeping the same mtime and size. (mtime, size) alone would serve the stale
    // parse forever; the inode in the stamp catches it.
    func test_loadVocabulary_invalidatesWhenInodeChangesAtSameStamp() {
        let file = Config.vocabularyFile
        let t = Date(timeIntervalSince1970: 1000)
        write("Alpha\n", to: file, mtime: t)
        XCTAssertEqual(Config.loadVocabulary(), "Alpha")
        let inode0 = inode(of: file)

        // Replace with a brand-new file (new inode), identical length + identical mtime.
        try! FileManager.default.removeItem(at: file)
        write("Bravo\n", to: file, mtime: t)
        XCTAssertNotEqual(inode(of: file), inode0, "precondition: replacement created a new inode")
        XCTAssertEqual(Config.loadVocabulary(), "Bravo",
                       "a new inode at an unchanged (mtime, size) must invalidate the cache")
    }

    // MARK: - F1: overrides mtime cache

    func test_loadOverrides_invalidatesWhenFileChanges() {
        let file = Config.overridesFile
        write("{\"crf\":\"CRM\"}", to: file, mtime: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(Config.loadOverrides(), ["crf": "CRM"])

        write("{\"crf\":\"CFO\"}", to: file, mtime: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(Config.loadOverrides(), ["crf": "CFO"])
    }

    // MARK: - F1: per-path cache key (CRITICAL for suite isolation)

    // Two different configDirOverride dirs must never return each other's cached value.
    func test_cacheKeyedPerPath_noCrossContamination() {
        let dirA = tmpDir.appendingPathComponent("A")
        let dirB = tmpDir.appendingPathComponent("B")
        try! FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        Config.configDirOverride = dirA
        write("Aaaaa\n", to: Config.vocabularyFile, mtime: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(Config.loadVocabulary(), "Aaaaa")

        Config.configDirOverride = dirB
        write("Bbbbb\n", to: Config.vocabularyFile, mtime: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(Config.loadVocabulary(), "Bbbbb")

        // Back to A: still A's value, not B's.
        Config.configDirOverride = dirA
        XCTAssertEqual(Config.loadVocabulary(), "Aaaaa")
    }

    // MARK: - F2: GlossaryCorrector reorder

    private let glossary = ["Rohrlich", "Bexx", "Maryna", "Viktor"]

    // The reordered fast path must skip the (expensive) real-word check entirely for tokens
    // with no glossary candidate, and produce identical output.
    func test_glossaryReorder_noCandidate_skipsRealWordCheckAndIsUnchanged() {
        var probed: [String] = []
        let isReal: (String) -> Bool = { probed.append($0); return false }

        // No token here is within edit distance of any glossary term.
        let input = "the quick brown mongoose jumped over fences"
        let out = GlossaryCorrector.correct(input, glossary: glossary, isRealWord: isReal)

        XCTAssertEqual(out, input, "no-candidate input must pass through unchanged")
        XCTAssertTrue(probed.isEmpty,
                      "isRealWord must not be consulted for tokens with no glossary candidate")
    }

    // Regression: reorder does not change any correction outcome (guard still protects real
    // words; near-misses still correct).
    func test_glossaryReorder_outcomesUnchanged() {
        let realWords: Set<String> = ["marina", "victor"]
        let isReal: (String) -> Bool = { realWords.contains($0.lowercased()) }
        func c(_ s: String) -> String {
            GlossaryCorrector.correct(s, glossary: glossary, isRealWord: isReal)
        }
        XCTAssertEqual(c("Rorlick"), "Rohrlich")                 // near-miss corrected
        XCTAssertEqual(c("the marina was calm"), "the marina was calm")  // real word protected
        XCTAssertEqual(c("he was the victor"), "he was the victor")      // real word protected
    }

    // MARK: - F3: UsageStats off-main save

    private struct StatsMirror: Codable {
        var totalCharacters: Int
        var totalDictations: Int
        var totalAudioSeconds: Double
    }

    // The in-memory counter updates synchronously; the persisted file matches after flush().
    func test_usageStats_synchronousCounter_andDurableAfterFlush() throws {
        let stats = UsageStats.shared
        let before = stats.totalDictations

        stats.recordDictation(characters: 42, audioSeconds: 3.5)
        XCTAssertEqual(stats.totalDictations, before + 1, "counter must be immediately correct")

        stats.flush()  // drain the background save queue

        let file = Config.configDir.appendingPathComponent("stats.json")
        let decoded = try JSONDecoder().decode(
            StatsMirror.self, from: Foundation.Data(contentsOf: file))
        XCTAssertEqual(decoded.totalDictations, stats.totalDictations)
        XCTAssertEqual(decoded.totalCharacters, stats.totalCharacters)
    }
}
