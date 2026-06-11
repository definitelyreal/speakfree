// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.4 — Unify download logic.
//
// Single owner of the Whisper-model download flow that was previously duplicated
// (with drift) across three GUI sites: the Settings inline banner, the Welcome
// onboarding panel, and the modal ModelDownloadController.
//
// Responsibilities centralised here:
//   • URLSession download-task lifecycle + delegate (progress / finish / error)
//   • progress callbacks (fraction + byte counts), delivered on the main queue
//   • <1 MB sanity reject (a saved HTML error page is never a model)
//   • T1.5 SHA256 post-download integrity verification — applied on EVERY GUI path
//     (previously ONLY the curl CLI path verified; all three URLSession sites
//      installed unverified bytes — this closes that drift)
//   • cancel / pause / resume
//   • atomic move from the .downloading temp file to the final destination
//
// The three UI sites become thin consumers: they own only their own widgets and
// hand the coordinator a model size + a set of callbacks.
//
// NOTE: the headless CLI path (`ModelDownloader.download`, curl-based, no UI) is
// intentionally left as-is. It already performs the same <1 MB + SHA256 checks; it
// is not a URLSession path and has no progress UI, so routing it through this
// coordinator would buy nothing and would change CLI behaviour. It is NOT dead code.

import Foundation

/// Coordinates a single Whisper model download over URLSession, with progress,
/// cancellation, and mandatory SHA256 integrity verification.
///
/// One coordinator instance drives one download at a time. Create a fresh one per
/// download (the three call sites already create/own one each).
public final class ModelDownloadCoordinator: NSObject, URLSessionDownloadDelegate {

    // MARK: - Callbacks (always invoked on the main queue)

    /// Reports download progress. `fraction` is in [0, 1] (0 when total is unknown).
    public var onProgress: ((_ fraction: Double, _ bytesWritten: Int64, _ bytesTotal: Int64) -> Void)?
    /// Called once the model is verified and installed at `destURL`.
    public var onSuccess: ((_ destURL: URL) -> Void)?
    /// Called on any failure (network, sanity, hash mismatch, disk). Not called on cancel.
    public var onFailure: ((_ error: Error) -> Void)?

    // MARK: - Test seam

    /// Builds the URLSession used for the download. Overridable in tests to inject a
    /// `MockURLProtocol`-backed configuration. Production uses `.default` + `self` as delegate.
    ///
    /// Audit note: setter is `internal` so external code cannot swap in a session that
    /// would bypass the delegate (and therefore the SHA256 verification). Only this module
    /// and `@testable` tests can override it.
    public internal(set) var makeSession: (URLSessionDownloadDelegate) -> URLSession = { delegate in
        URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - State

    private var modelSize: String = ""
    private var destPath: URL!
    private var tmpPath: URL!
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?

    /// True between `start` and a terminal callback. Used by callers for UI state if they want.
    public private(set) var isDownloading = false

    // MARK: - Public API

    /// Begin downloading `modelSize` (e.g. "tiny.en"). If the model already exists on disk,
    /// `onSuccess` fires immediately with no network activity.
    ///
    /// All callbacks are delivered on the main queue.
    public func start(modelSize: String) {
        self.modelSize = modelSize

        let modelFileName = "ggml-\(modelSize).bin"
        let modelsDir = Config.configDir.appendingPathComponent("models")
        self.destPath = modelsDir.appendingPathComponent(modelFileName)
        self.tmpPath = destPath.appendingPathExtension("downloading")

        guard let url = URL(string: "\(ModelDownloader.baseURL)/\(modelFileName)") else {
            deliverFailure(ModelDownloadError.downloadFailed)
            return
        }

        // Ensure the models directory exists (0700 — user-private).
        try? FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Clean any partial download from a previous attempt.
        try? FileManager.default.removeItem(at: tmpPath)

        // Already installed → succeed immediately, no network.
        if FileManager.default.fileExists(atPath: destPath.path) {
            deliverSuccess(destPath)
            return
        }

        isDownloading = true
        let session = makeSession(self)
        self.session = session
        let task = session.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }

    /// Cancel the in-flight download. No callback is delivered (matches prior cancel semantics
    /// across all three sites: cancel is user-initiated and silent).
    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    /// Suspend the in-flight download (Welcome's Pause). Resumable via `resume()`.
    public func pause() {
        downloadTask?.suspend()
    }

    /// Resume a suspended download.
    public func resume() {
        downloadTask?.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(fraction, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // URLSession's `location` is an ephemeral file that is deleted the moment this
        // method returns — so we must move it out synchronously, on this delegate queue,
        // BEFORE hopping to main. Validation + verification + install all happen here.
        let result = installVerified(from: location)
        switch result {
        case .success(let dest):
            DispatchQueue.main.async { [weak self] in
                self?.isDownloading = false
                self?.onSuccess?(dest)
            }
        case .failure(let error):
            DispatchQueue.main.async { [weak self] in
                self?.isDownloading = false
                self?.onFailure?(error)
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error = error, (error as NSError).code != NSURLErrorCancelled else { return }
        deliverFailure(error)
    }

    // MARK: - Install + verify (runs on the delegate queue, synchronously)

    private func installVerified(from location: URL) -> Result<URL, Error> {
        do {
            // 1. Move the ephemeral download into our temp file.
            try? FileManager.default.removeItem(at: tmpPath)
            try FileManager.default.moveItem(at: location, to: tmpPath)

            // 2. Sanity: a real GGML model is at least 1 MB (a saved HTTP error page is tiny).
            let size = (try? FileManager.default.attributesOfItem(atPath: tmpPath.path))?[.size] as? Int ?? 0
            guard size >= 1_000_000 else {
                try? FileManager.default.removeItem(at: tmpPath)
                return .failure(ModelDownloadError.invalidModel)
            }

            // 3. T1.5 integrity: verify SHA256 against the pinned table before install.
            //    Throws ModelDownloadError.hashMismatch on a tampered/corrupt download.
            do {
                try ModelDownloader.verifySHA256(modelSize: modelSize, at: tmpPath)
            } catch {
                try? FileManager.default.removeItem(at: tmpPath)
                return .failure(error)
            }

            // 4. Atomically install.
            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.moveItem(at: tmpPath, to: destPath)
            return .success(destPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
            return .failure(error)
        }
    }

    // MARK: - Delivery helpers (hop to main)

    private func deliverSuccess(_ dest: URL) {
        DispatchQueue.main.async { [weak self] in
            self?.isDownloading = false
            self?.onSuccess?(dest)
        }
    }

    private func deliverFailure(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.isDownloading = false
            self?.onFailure?(error)
        }
    }
}
