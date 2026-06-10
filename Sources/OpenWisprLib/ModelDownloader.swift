// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
import Foundation
import CryptoKit

public class ModelDownloader {
    static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    // MARK: - Known SHA256 hashes (authoritative from HF LFS pointer files, 2026-06-10)
    //
    // Source: https://huggingface.co/ggerganov/whisper.cpp/raw/main/<filename>
    // Each pointer contains "oid sha256:<hex>" — fetched via curl and cross-checked against
    // a locally downloaded ggml-tiny.en.bin (matches). Parakeet models are downloaded
    // exclusively by FluidAudio / ParakeetModelManager, which owns its own integrity; their
    // hashes are not included here because HuggingFace hosts the compiled CoreML bundles as
    // multi-file repos (no single .bin LFS pointer), so there is no authoritative per-file
    // SHA256 to pin against. FluidAudio's registry-host pin in ParakeetModelManager provides
    // the primary supply-chain control for that path.
    public static let knownSHA256: [String: String] = [
        "tiny.en":          "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
        "tiny":             "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
        "base.en":          "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        "base":             "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        "small.en":         "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        "small":            "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        "medium.en":        "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
        "medium":           "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
        "large-v3-turbo":   "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        "large-v3":         "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
    ]

    // MARK: - SHA256 verification (seam-injectable for testing)

    /// Compute the SHA256 hex digest of a file on disk.
    /// This closure is a TEST SEAM, overridable in tests to inject deterministic behaviour
    /// without disk I/O. Audit AR-1: the setter is `internal` so external code cannot swap the
    /// hasher to bypass integrity checks — only this module (and `@testable` tests) can.
    public internal(set) static var computeSHA256: (URL) throws -> String = { url in
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let chunk = try handle.read(upToCount: chunkSize)
            guard let bytes = chunk, !bytes.isEmpty else { break }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verify the file at `url` against the known SHA256 for `modelSize`.
    /// - Returns normally if the hash matches or if no known hash exists for the model.
    /// - Throws `ModelDownloadError.hashMismatch` if a known hash exists and does not match.
    public static func verifySHA256(modelSize: String, at url: URL) throws {
        guard let expected = knownSHA256[modelSize] else {
            // No entry in the table — can't verify, pass through. This is intentional and
            // scoped: every shipped whisper model size IS in `knownSHA256`; Parakeet models go
            // through FluidAudio's own integrity path, not here. Audit AR-1: make the
            // unverified case observable rather than silent, so a typo / new model name that
            // slips past the table is visible in diagnostics instead of failing open quietly.
            DiagnosticLogger.shared.log(
                "ModelDownloader: no known SHA256 for '\(modelSize)' — integrity NOT verified (table-scoped)")
            return
        }
        let actual = try computeSHA256(url)
        if actual != expected {
            throw ModelDownloadError.hashMismatch(
                modelSize: modelSize, expected: expected, actual: actual)
        }
    }

    // MARK: - Download

    public static func download(modelSize: String) throws {
        let modelFileName = "ggml-\(modelSize).bin"
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let destPath = modelsDir.appendingPathComponent(modelFileName)
        let tmpPath = destPath.appendingPathExtension("downloading")

        if FileManager.default.fileExists(atPath: destPath.path) {
            print("Model '\(modelSize)' already exists at \(destPath.path)")
            return
        }

        try FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Clean up any partial download from a previous attempt
        try? FileManager.default.removeItem(at: tmpPath)

        let url = "\(baseURL)/\(modelFileName)"
        print("Downloading \(modelSize) model from \(url)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // --connect-timeout 30: fail fast if server unreachable
        // --max-time 600: abort if download takes longer than 10 minutes
        // -f: fail on HTTP errors (returns exit code 22 instead of saving error page)
        process.arguments = ["-L", "-f", "--connect-timeout", "30", "--max-time", "600", "--progress-bar", "-o", tmpPath.path, url]
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // Clean up partial download on failure
            try? FileManager.default.removeItem(at: tmpPath)
            throw ModelDownloadError.downloadFailed
        }

        // Validate: GGML files should be at least 1MB
        let attrs = try? FileManager.default.attributesOfItem(atPath: tmpPath.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        if fileSize < 1_000_000 {
            try? FileManager.default.removeItem(at: tmpPath)
            throw ModelDownloadError.invalidModel
        }

        // SHA256 integrity check — reject tampered or corrupted downloads before install.
        do {
            try verifySHA256(modelSize: modelSize, at: tmpPath)
        } catch {
            // Delete the bad file so a retry fetches fresh bytes.
            try? FileManager.default.removeItem(at: tmpPath)
            throw error
        }

        // Atomically move from tmp to final destination
        try FileManager.default.moveItem(at: tmpPath, to: destPath)
        print("Model downloaded to \(destPath.path)")
    }
}

public enum ModelDownloadError: LocalizedError {
    case downloadFailed
    case invalidModel
    case hashMismatch(modelSize: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download model"
        case .invalidModel:
            return "Downloaded file is not a valid Whisper model"
        case let .hashMismatch(modelSize, expected, actual):
            return "SHA256 mismatch for model '\(modelSize)': expected \(expected), got \(actual). "
                + "The downloaded file may be corrupt or tampered with. It has been deleted — please retry."
        }
    }
}
