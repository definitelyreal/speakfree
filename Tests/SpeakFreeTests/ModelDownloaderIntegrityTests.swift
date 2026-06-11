// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T1.5 — Download integrity
//
// Unit tests for the SHA256 verification seam in ModelDownloader.
// No disk I/O, no network — the `computeSHA256` closure is overridden per test.

import XCTest
import CryptoKit
@testable import SpeakFreeLib

final class ModelDownloaderIntegrityTests: XCTestCase {

    // MARK: - helpers

    /// The authoritative hash the table has for `tiny.en` (from HF LFS pointer, 2026-06-10).
    private let tinyEnExpected = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"

    /// Swap in a fixed hash for the duration of the test, restoring the original on exit.
    private func setHashSeam(_ hash: String) -> (() -> Void) {
        let saved = ModelDownloader.computeSHA256
        ModelDownloader.computeSHA256 = { _ in hash }
        return { ModelDownloader.computeSHA256 = saved }
    }

    override func tearDown() {
        // Belt-and-suspenders: reset to a fresh real hasher after every test so a mid-test
        // crash never leaves the seam poisoned for a subsequent test.
        ModelDownloader.computeSHA256 = { url in
            var hasher = CryptoKit.SHA256()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let chunkSize = 1 << 20
            while true {
                let chunk = try handle.read(upToCount: chunkSize)
                guard let bytes = chunk, !bytes.isEmpty else { break }
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        super.tearDown()
    }

    // MARK: - known-hash table coverage

    func test_knownHashes_containsAllCatalogModels() {
        // Every model the Settings UI can trigger a download for must be in the table.
        let required = [
            "tiny.en", "tiny",
            "base.en", "base",
            "small.en", "small",
            "medium.en", "medium",
            "large-v3-turbo", "large-v3",
        ]
        for model in required {
            XCTAssertNotNil(
                ModelDownloader.knownSHA256[model],
                "Missing SHA256 entry for model '\(model)'"
            )
        }
    }

    func test_knownHashes_allHashesAreLowercaseHex64() {
        for (model, hash) in ModelDownloader.knownSHA256 {
            XCTAssertEqual(
                hash.count, 64,
                "Hash for '\(model)' should be 64 hex characters, got \(hash.count)"
            )
            XCTAssert(
                hash.allSatisfy { $0.isHexDigit },
                "Hash for '\(model)' contains non-hex characters: \(hash)"
            )
        }
    }

    // MARK: - verifySHA256: matching hash passes

    func test_verifyPasses_whenHashMatches() throws {
        // Seed the seam with the correct expected hash for tiny.en.
        let restore = setHashSeam(tinyEnExpected)
        defer { restore() }

        // Must not throw when the returned digest matches the table entry.
        try ModelDownloader.verifySHA256(
            modelSize: "tiny.en",
            at: URL(fileURLWithPath: "/dev/null")
        )
        // If we reach here, the verify passed — correct behaviour.
    }

    // MARK: - verifySHA256: tampered file is rejected

    func test_verifyRejects_tamperedFile() {
        let tamperedHash = String(repeating: "aa", count: 32)  // 64 hex 'a's — wrong
        let restore = setHashSeam(tamperedHash)
        defer { restore() }

        do {
            try ModelDownloader.verifySHA256(
                modelSize: "tiny.en",
                at: URL(fileURLWithPath: "/dev/null")
            )
            XCTFail("verifySHA256 must throw when the digest does not match the table")
        } catch ModelDownloadError.hashMismatch(let modelSize, let expected, let actual) {
            XCTAssertEqual(modelSize, "tiny.en",      "mismatch error must name the model")
            XCTAssertEqual(expected, tinyEnExpected,  "mismatch error must carry the expected hash")
            XCTAssertEqual(actual, tamperedHash,       "mismatch error must carry the actual hash")
        } catch {
            XCTFail("Expected ModelDownloadError.hashMismatch, got \(error)")
        }
    }

    // MARK: - verifySHA256: unknown model passes through (no-op)

    func test_verifyPassesThrough_forUnknownModel() throws {
        // A model not in the table should not block download (graceful degradation).
        // The seam returns a "wrong" hash to prove the table check is skipped entirely.
        let restore = setHashSeam(String(repeating: "aa", count: 32))
        defer { restore() }

        // large-v2 is not in knownSHA256 — must succeed regardless of the computed digest.
        try ModelDownloader.verifySHA256(
            modelSize: "large-v2",
            at: URL(fileURLWithPath: "/dev/null")
        )
        // Reaching here without throwing is the success condition.
    }

    // MARK: - error description is human-readable

    func test_hashMismatchError_descriptionContainsBothHashes() {
        let err = ModelDownloadError.hashMismatch(
            modelSize: "small",
            expected: "abcd1234" + String(repeating: "0", count: 56),
            actual:   "deadbeef" + String(repeating: "0", count: 56)
        )
        let desc = err.errorDescription ?? ""
        XCTAssert(desc.contains("small"),    "Error description should name the model")
        XCTAssert(desc.contains("abcd1234"), "Error description should contain expected hash prefix")
        XCTAssert(desc.contains("deadbeef"), "Error description should contain actual hash prefix")
    }

    // MARK: - computeSHA256 default seam is correct on a real file

    func test_defaultSeam_hashesDevNull() throws {
        // /dev/null always exists and contains zero bytes.
        // SHA256 of the empty string is a known constant.
        let emptyFileSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

        // Use the saved real seam (tearDown will restore it anyway).
        let saved = ModelDownloader.computeSHA256
        defer { ModelDownloader.computeSHA256 = saved }

        let hash = try saved(URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(
            hash, emptyFileSHA256,
            "SHA256 of /dev/null (empty) must equal the known empty-string digest"
        )
    }
}
