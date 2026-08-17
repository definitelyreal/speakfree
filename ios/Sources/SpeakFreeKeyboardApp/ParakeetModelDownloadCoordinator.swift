// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation
import OSLog
import UIKit

/// Owns the immutable Parakeet model transfers independently of the app's foreground lifetime.
/// Completed files and FluidAudio `.partial`/`.etag` files are reused, so Retry resumes at the
/// smallest safe boundary instead of deleting a multi-hundred-megabyte cache.
@MainActor
final class ParakeetModelDownloadCoordinator: NSObject {
    private let logger = Logger(
        subsystem: "com.speakfree.keyboard",
        category: "ModelDownload"
    )
    struct Progress: Equatable, Sendable {
        let downloadedBytes: Int64
        let totalBytes: Int64

        var fractionCompleted: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
        }
    }

    enum State: Equatable, Sendable {
        case idle(Progress)
        case downloading(Progress)
        case completed(Progress)
        case cancelled(Progress)
        case failed(Progress, String)

        var progress: Progress {
            switch self {
            case .idle(let value), .downloading(let value), .completed(let value),
                 .cancelled(let value), .failed(let value, _):
                value
            }
        }
    }

    static let shared = ParakeetModelDownloadCoordinator()
    static let sessionIdentifier = "com.speakfree.keyboard.parakeet-background-v1"

    /// Uses the same pinned manifest as the downloader. FluidAudio's lightweight existence
    /// checks can accept a truncated compiled-model directory and then fall back to an opaque
    /// foreground repair download; onboarding must never take that path.
    nonisolated static var requiredFilesAreCached: Bool {
        Manifest.files.allSatisfy(isComplete)
    }

    private var observer: ((State) -> Void)?
    private var state: State = .idle(Progress(downloadedBytes: 0, totalBytes: Manifest.totalBytes))
    private var liveBytes: [String: Int64] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    func observe(_ observer: @escaping (State) -> Void) {
        self.observer = observer
        refreshState()
    }

    func startOrResume() {
        logger.notice("Starting or resuming pinned Parakeet background download")
        let progress = diskProgress()
        let remainingBytes = max(0, progress.totalBytes - progress.downloadedBytes)
        if let available = try? Self.applicationSupportRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           available < remainingBytes + 134_217_728 {
            publishFailure("Not enough free storage. Free at least \(ByteCountFormatter.string(fromByteCount: remainingBytes + 134_217_728, countStyle: .file)) and try again.")
            return
        }
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                let activeIDs = Set(tasks.compactMap(\.taskDescription))
                var scheduled = false
                for file in Manifest.files where !Self.isComplete(file) {
                    guard !activeIDs.contains(file.id) else {
                        scheduled = true
                        continue
                    }
                    guard let request = Self.request(for: file) else {
                        self.publishFailure("The pinned model URL is invalid: \(file.remotePath)")
                        return
                    }
                    do {
                        try FileManager.default.createDirectory(
                            at: Self.destinationURL(file).deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                    } catch {
                        self.publishFailure("Unable to create the model cache: \(error.localizedDescription)")
                        return
                    }
                    let resumeURL = Self.resumeDataURL(file)
                    let task: URLSessionDownloadTask
                    if let data = try? Data(contentsOf: resumeURL), !data.isEmpty {
                        task = self.session.downloadTask(withResumeData: data)
                        try? FileManager.default.removeItem(at: resumeURL)
                    } else {
                        task = self.session.downloadTask(with: request)
                    }
                    task.taskDescription = file.id
                    task.resume()
                    scheduled = true
                }
                self.refreshState(forceDownloading: scheduled)
            }
        }
    }

    func cancel() {
        logger.notice("Cancelling active Parakeet background transfers")
        session.getAllTasks { [weak self] tasks in
            let pending = DispatchGroup()
            for task in tasks {
                guard let downloadTask = task as? URLSessionDownloadTask,
                      let id = task.taskDescription,
                      let file = Manifest.byID[id] else {
                    task.cancel()
                    continue
                }
                pending.enter()
                downloadTask.cancel { resumeData in
                    if let resumeData, !resumeData.isEmpty {
                        try? FileManager.default.createDirectory(
                            at: Self.resumeDataURL(file).deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try? resumeData.write(to: Self.resumeDataURL(file), options: .atomic)
                    }
                    pending.leave()
                }
            }
            pending.notify(queue: .main) {
                Task { @MainActor in
                    guard let self else { return }
                    self.liveBytes.removeAll()
                    self.publish(.cancelled(self.diskProgress()))
                }
            }
        }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    private func refreshState(forceDownloading: Bool = false) {
        let progress = diskProgress()
        if progress.downloadedBytes >= progress.totalBytes {
            publish(.completed(progress))
            return
        }
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                let current = self.diskProgress()
                self.publish((forceDownloading || !tasks.isEmpty) ? .downloading(current) : .idle(current))
            }
        }
    }

    private func diskProgress() -> Progress {
        var completed: Int64 = 0
        for file in Manifest.files {
            if Self.isComplete(file) {
                completed += file.expectedBytes
            } else {
                completed += min(file.expectedBytes, liveBytes[file.id] ?? Self.partialSize(file))
            }
        }
        return Progress(downloadedBytes: completed, totalBytes: Manifest.totalBytes)
    }

    private func publish(_ next: State) {
        state = next
        observer?(next)
    }

    private func publishFailure(_ message: String) {
        logger.error("Parakeet model download failed: \(message, privacy: .public)")
        publish(.failed(diskProgress(), message))
    }

    nonisolated private static func request(for file: Manifest.File) -> URLRequest? {
        guard let url = URL(string:
            "https://huggingface.co/\(file.repository)/resolve/\(file.revision)/\(file.remotePath)"
        ) else { return nil }
        var request = URLRequest(url: url)
        let partial = partialURL(file)
        let offset = fileSize(at: partial)
        let validator = (try? String(
            contentsOf: partial.appendingPathExtension("etag"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if offset > 0, offset < file.expectedBytes, let validator, !validator.isEmpty {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        } else if offset > 0 {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: partial.appendingPathExtension("etag"))
        }
        return request
    }

    nonisolated private static func installDownload(
        from temporaryURL: URL,
        task: URLSessionDownloadTask,
        file: Manifest.File
    ) throws {
        let fileManager = FileManager.default
        let destination = destinationURL(file)
        let partial = partialURL(file)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let response = task.response as? HTTPURLResponse
        guard let status = response?.statusCode, status == 200 || status == 206 else {
            throw DownloadError.serverStatus(response?.statusCode ?? -1, file.remotePath)
        }
        if response?.statusCode == 206, fileManager.fileExists(atPath: partial.path) {
            let offset = fileSize(at: partial)
            let contentRange = response?.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard contentRange.hasPrefix("bytes \(offset)-") else {
                throw DownloadError.invalidRange(file.remotePath)
            }
            try appendFile(at: temporaryURL, to: partial)
            guard fileSize(at: partial) == file.expectedBytes else {
                throw DownloadError.sizeMismatch(file.remotePath)
            }
            try replace(destination, with: partial)
        } else {
            guard fileSize(at: temporaryURL) == file.expectedBytes else {
                throw DownloadError.sizeMismatch(file.remotePath)
            }
            try replace(destination, with: temporaryURL)
        }
        try? fileManager.removeItem(at: partial.appendingPathExtension("etag"))
        try? fileManager.removeItem(at: resumeDataURL(file))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)
    }

    /// Appends a background-download file without mapping the complete model weight into memory.
    /// The largest Parakeet artifact is about 445 MB, so `Data(contentsOf:)` here is unsafe on iOS.
    nonisolated private static func appendFile(at source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    nonisolated private static func replace(_ destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    nonisolated private static func isComplete(_ file: Manifest.File) -> Bool {
        fileSize(at: destinationURL(file)) == file.expectedBytes
    }

    nonisolated private static func partialSize(_ file: Manifest.File) -> Int64 {
        fileSize(at: partialURL(file))
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
            .int64Value ?? 0
    }

    nonisolated private static func destinationURL(_ file: Manifest.File) -> URL {
        modelsRoot.appendingPathComponent(file.localPath, isDirectory: false)
    }

    nonisolated private static func partialURL(_ file: Manifest.File) -> URL {
        destinationURL(file).appendingPathExtension("partial")
    }

    nonisolated private static func resumeDataURL(_ file: Manifest.File) -> URL {
        destinationURL(file).appendingPathExtension("sfresume")
    }

    nonisolated private static var modelsRoot: URL {
        applicationSupportRoot
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    nonisolated private static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

extension ParakeetModelDownloadCoordinator: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            if let file = Manifest.byID[id] {
                liveBytes[id] = min(file.expectedBytes, Self.partialSize(file) + totalBytesWritten)
            }
            publish(.downloading(diskProgress()))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let file = Manifest.byID[id] else { return }
        do {
            try Self.installDownload(from: location, task: downloadTask, file: file)
            Task { @MainActor in
                liveBytes[id] = nil
                refreshState()
            }
        } catch {
            Task { @MainActor in
                publishFailure(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else {
            return
        }
        Task { @MainActor in
            publishFailure(error.localizedDescription)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            refreshState()
            let completion = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            completion?()
        }
    }
}

private extension ParakeetModelDownloadCoordinator {
    enum DownloadError: LocalizedError {
        case sizeMismatch(String)
        case serverStatus(Int, String)
        case invalidRange(String)

        var errorDescription: String? {
            switch self {
            case .sizeMismatch(let path):
                "Downloaded model file failed its pinned-size check: \(path)"
            case .serverStatus(let status, let path):
                "The model server returned HTTP \(status) for \(path)"
            case .invalidRange(let path):
                "The model server returned an unsafe resume range for \(path)"
            }
        }
    }

    enum Manifest {
        struct File: Sendable {
            let id: String
            let repository: String
            let revision: String
            let remotePath: String
            let localPath: String
            let expectedBytes: Int64
        }

        static let v2Repo = "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        static let v2Revision = "ee09c569f73759e6d44c9bd16766f477b2b36d39"
        static let eouRepo = "FluidInference/parakeet-realtime-eou-120m-coreml"
        static let eouRevision = "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355"

        static let files: [File] = {
            let v2: [(String, Int64)] = [
                ("Decoder.mlmodelc/analytics/coremldata.bin", 243),
                ("Decoder.mlmodelc/coremldata.bin", 554),
                ("Decoder.mlmodelc/metadata.json", 3_427),
                ("Decoder.mlmodelc/model.mil", 13_106),
                ("Decoder.mlmodelc/weights/weight.bin", 14_429_952),
                ("Encoder.mlmodelc/analytics/coremldata.bin", 243),
                ("Encoder.mlmodelc/coremldata.bin", 485),
                ("Encoder.mlmodelc/metadata.json", 2_926),
                ("Encoder.mlmodelc/model.mil", 959_769),
                ("Encoder.mlmodelc/weights/weight.bin", 445_187_200),
                ("JointDecision.mlmodelc/analytics/coremldata.bin", 243),
                ("JointDecision.mlmodelc/coremldata.bin", 534),
                ("JointDecision.mlmodelc/metadata.json", 2_936),
                ("JointDecision.mlmodelc/model.mil", 9_722),
                ("JointDecision.mlmodelc/weights/weight.bin", 3_453_388),
                ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243),
                ("Preprocessor.mlmodelc/coremldata.bin", 494),
                ("Preprocessor.mlmodelc/metadata.json", 2_974),
                ("Preprocessor.mlmodelc/model.mil", 27_166),
                ("Preprocessor.mlmodelc/weights/weight.bin", 298_880),
                ("parakeet_vocab.json", 18_762),
            ]
            let eou: [(String, Int64)] = [
                ("320ms/decoder.mlmodelc/analytics/coremldata.bin", 243),
                ("320ms/decoder.mlmodelc/coremldata.bin", 497),
                ("320ms/decoder.mlmodelc/metadata.json", 3_283),
                ("320ms/decoder.mlmodelc/model.mil", 7_409),
                ("320ms/decoder.mlmodelc/weights/weight.bin", 7_873_600),
                ("320ms/joint_decision.mlmodelc/analytics/coremldata.bin", 243),
                ("320ms/joint_decision.mlmodelc/coremldata.bin", 493),
                ("320ms/joint_decision.mlmodelc/metadata.json", 3_181),
                ("320ms/joint_decision.mlmodelc/model.mil", 9_608),
                ("320ms/joint_decision.mlmodelc/weights/weight.bin", 2_794_182),
                ("320ms/streaming_encoder.mlmodelc/analytics/coremldata.bin", 243),
                ("320ms/streaming_encoder.mlmodelc/coremldata.bin", 670),
                ("320ms/streaming_encoder.mlmodelc/metadata.json", 5_327),
                ("320ms/streaming_encoder.mlmodelc/model.mil", 655_998),
                ("320ms/streaming_encoder.mlmodelc/weights/weight.bin", 212_865_856),
                ("320ms/vocab.json", 17_437),
            ]
            let v2Files = v2.map { path, bytes in
                File(
                    id: "v2:\(path)", repository: v2Repo, revision: v2Revision,
                    remotePath: path,
                    localPath: "parakeet-tdt-0.6b-v2/\(path)", expectedBytes: bytes
                )
            }
            let eouFiles = eou.map { path, bytes in
                File(
                    id: "eou:\(path)", repository: eouRepo, revision: eouRevision,
                    remotePath: path,
                    localPath: "parakeet-eou-streaming/parakeet-eou-streaming/\(path)",
                    expectedBytes: bytes
                )
            }
            return v2Files + eouFiles
        }()

        static let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        static let totalBytes = files.reduce(Int64(0)) { $0 + $1.expectedBytes }
    }
}

final class SpeakFreeApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == ParakeetModelDownloadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            ParakeetModelDownloadCoordinator.shared.handleBackgroundEvents(
                completionHandler: completionHandler
            )
        }
    }
}
