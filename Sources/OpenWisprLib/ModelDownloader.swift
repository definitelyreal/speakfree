import Foundation

public class ModelDownloader {
    static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    public static func download(modelSize: String) throws {
        let modelFileName = "ggml-\(modelSize).bin"
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let destPath = modelsDir.appendingPathComponent(modelFileName)
        let tmpPath = destPath.appendingPathExtension("downloading")

        if FileManager.default.fileExists(atPath: destPath.path) {
            print("Model '\(modelSize)' already exists at \(destPath.path)")
            return
        }

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

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

        // Validate: GGML files start with a magic number and should be at least 1MB
        let attrs = try? FileManager.default.attributesOfItem(atPath: tmpPath.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        if fileSize < 1_000_000 {
            try? FileManager.default.removeItem(at: tmpPath)
            throw ModelDownloadError.invalidModel
        }

        // Atomically move from tmp to final destination
        try FileManager.default.moveItem(at: tmpPath, to: destPath)
        print("Model downloaded to \(destPath.path)")
    }
}

enum ModelDownloadError: LocalizedError {
    case downloadFailed
    case invalidModel

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download model"
        case .invalidModel:
            return "Downloaded file is not a valid Whisper model"
        }
    }
}
