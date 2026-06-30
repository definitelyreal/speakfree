// Claude · 2026-06-28
//
// Best-effort byte-accurate pre-fetch of the large Parakeet model bundles directly from
// HuggingFace, so the onboarding download shows a SMOOTH real progress bar.
//
// Why this exists: FluidAudio's own downloader throws away URLSession's Content-Length and reports
// no usable progress for the ~450 MB encoder weights, so a determinate bar sits frozen for minutes
// (the "stuck at 0%" / "stuck at 2%" symptom). This downloads the big `.mlmodelc` bundles ourselves
// with true aggregate byte progress into FluidAudio's cache directory; ParakeetModelManager then
// calls FluidAudio's normal download, which SKIPS the files we already placed and fetches only the
// small remainder + compiles.
//
// Progress comes from a SESSION-LEVEL `URLSessionDownloadDelegate` (the per-task `delegate:` form of
// `URLSession.download(for:delegate:)` does NOT reliably deliver `didWriteData`, which froze the bar
// during the multi-minute encoder fetch). Cancellation is wired through `withTaskCancellationHandler`
// so a user Stop actually cancels the in-flight URLSession task (no orphaned background downloads).
//
// Safety model: FluidAudio remains the source of truth. We only place files we are confident about
// (the identity-named bundles whose repo path == cache path, verified byte-exact for v2). Anything
// we miss or get wrong, FluidAudio re-downloads, and it validates the whole cache on load. A stale
// file list therefore degrades to "no smooth bar" (FluidAudio's normal download), never to a broken
// install. Every file is written atomically (temp → move) so an interrupted pre-fetch leaves no
// partial file that FluidAudio's existence check would wrongly skip.

import Foundation

final class ParakeetDirectDownloader: NSObject, @unchecked Sendable {

    /// Per-model plan: the public HuggingFace repo and the `.mlmodelc` bundle directories whose
    /// repo layout maps 1:1 onto FluidAudio's on-disk cache (verified byte-exact). `nil` → no
    /// pre-fetch; the caller falls back to FluidAudio's normal download.
    static func plan(forModelID id: String) -> (repo: String, bundles: [String])? {
        switch id {
        case "parakeet-tdt-0.6b-v2":
            // After a FluidAudio v2 download these three bundles match the repo paths and sizes
            // exactly (Encoder 445 MB, Decoder 14 MB, JointDecision 3.4 MB = ~99% of bytes). The small
            // Preprocessor/vocab/config are renamed/derived by FluidAudio, so we leave those to it.
            return (
                "FluidInference/parakeet-tdt-0.6b-v2-coreml",
                ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]
            )
        default:
            return nil
        }
    }

    struct RemoteFile {
        let path: String
        let size: Int64
    }

    enum DownloadError: Error {
        case listFailed
        case httpError(Int)
    }

    /// Pre-fetches the planned large bundles into `cacheDir`, reporting aggregate progress as
    /// `(downloadedBytes, totalBytes)`. Throws on hard failure (after retries) so the caller can fall
    /// back to FluidAudio; throws `CancellationError` immediately on a user pause/stop.
    static func prefetch(
        modelID: String,
        into cacheDir: URL,
        progress: @escaping (_ downloaded: Int64, _ total: Int64) -> Void
    ) async throws {
        guard let plan = plan(forModelID: modelID) else { return }
        let downloader = ParakeetDirectDownloader()
        defer { downloader.session.invalidateAndCancel() }  // break the session↔delegate retain cycle

        let files = try await downloader.listFiles(repo: plan.repo, underBundles: plan.bundles)
        guard !files.isEmpty else { return }

        let totalBytes = files.reduce(Int64(0)) { $0 + max(0, $1.size) }
        var completedBytes: Int64 = 0
        progress(0, totalBytes)
        DiagnosticLogger.shared.log(
            "ParakeetDirectDownloader: \(files.count) files, \(totalBytes / 1_000_000) MB to fetch")

        let fm = FileManager.default
        for file in files {
            try Task.checkCancellation()
            let dest = cacheDir.appendingPathComponent(file.path)

            // Skip a file already present at the correct size (resume / re-run is free).
            if let existing = try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber,
                existing.int64Value == file.size, file.size > 0 {
                completedBytes += file.size
                progress(completedBytes, totalBytes)
                continue
            }

            DiagnosticLogger.shared.log(
                "ParakeetDirectDownloader: GET \(file.path) \(file.size / 1_000_000)MB")
            let base = completedBytes
            // Retry transient failures: a stall/drop during the multi-minute encoder download used to
            // abandon the whole pre-fetch. Cancellation is never retried — it propagates as a pause/stop.
            var attempt = 0
            while true {
                attempt += 1
                do {
                    try await downloader.downloadFile(
                        repo: plan.repo, path: file.path, to: dest,
                        onBytes: { written in progress(base + written, totalBytes) })
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let e as URLError where e.code == .cancelled {
                    throw CancellationError()
                } catch {
                    if attempt >= 4 { throw error }
                    DiagnosticLogger.shared.log(
                        "ParakeetDirectDownloader: \(file.path) attempt \(attempt) failed "
                            + "(\(error.localizedDescription)); retrying")
                    progress(base, totalBytes)  // reset this file's contribution before re-downloading
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)  // 1.5s, 3s, 4.5s
                }
            }
            completedBytes += file.size
            progress(completedBytes, totalBytes)
        }
        DiagnosticLogger.shared.log(
            "ParakeetDirectDownloader: done, \(completedBytes / 1_000_000) MB fetched")
    }

    // MARK: - Session (tolerant of the long encoder download)

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120   // tolerate brief stalls (default 60 s aborted the download)
        cfg.timeoutIntervalForResource = 3600  // up to an hour for the whole ~445 MB file
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // Single active download at a time (the pre-fetch is sequential), guarded by `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onBytes: ((Int64) -> Void)?

    // MARK: - HuggingFace listing

    private func listFiles(repo: String, underBundles bundles: [String]) async throws -> [RemoteFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")
        else { throw DownloadError.listFailed }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.listFailed
        }
        let prefixes = bundles.map { $0 + "/" }
        var result: [RemoteFile] = []
        for item in items {
            guard let path = item["path"] as? String,
                (item["type"] as? String) == "file",
                prefixes.contains(where: { path.hasPrefix($0) })
            else { continue }
            // LFS weight files carry the real size under `lfs.size`; small files use top-level `size`.
            let lfsSize = (item["lfs"] as? [String: Any])?["size"] as? NSNumber
            let size = lfsSize?.int64Value ?? (item["size"] as? NSNumber)?.int64Value ?? -1
            result.append(RemoteFile(path: path, size: size))
        }
        return result
    }

    // MARK: - Single-file download with byte progress

    private func downloadFile(
        repo: String, path: String, to dest: URL, onBytes: @escaping (_ written: Int64) -> Void
    ) async throws {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)") else {
            throw DownloadError.listFailed
        }
        let tempURL = try await downloadToTemp(url, onBytes: onBytes)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.moveItem(at: tempURL, to: dest)  // atomic: a partial download is never left at `dest`
    }

    /// Runs one download task, surfacing byte progress via the session delegate and honoring Task
    /// cancellation (Stop) by cancelling the URLSession task.
    private func downloadToTemp(_ url: URL, onBytes: @escaping (Int64) -> Void) async throws -> URL {
        let task = session.downloadTask(with: URLRequest(url: url))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                lock.lock()
                continuation = cont
                self.onBytes = onBytes
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        onBytes = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}

extension ParakeetDirectDownloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64
    ) {
        lock.lock()
        let cb = onBytes
        lock.unlock()
        cb?(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.httpError(http.statusCode)))
            return
        }
        // `location` is removed as soon as this method returns, so move it to a stable temp now.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-parakeet-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            finish(.success(stable))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        // Success is resumed in didFinishDownloadingTo; only surface a genuine error here.
        if let error = error { finish(.failure(error)) }
    }
}
