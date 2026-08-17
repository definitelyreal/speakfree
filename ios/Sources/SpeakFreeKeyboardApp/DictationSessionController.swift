// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import AVFoundation
import Foundation
import OSLog
import SpeakFreeKeyboardCore
import UIKit

@MainActor
final class DictationSessionController: ObservableObject {
    private let logger = Logger(
        subsystem: "com.speakfree.keyboard",
        category: "DictationLifecycle"
    )
    static let shared = DictationSessionController()

    enum Phase: Equatable {
        case modelRequired
        case downloadingModel
        case preparingModel
        case ready
        case starting
        case recording
        case finalizing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .modelRequired
    @Published private(set) var modelProgress = 0.0
    @Published private(set) var modelDownloadedBytes: Int64 = 0
    @Published private(set) var modelTotalBytes: Int64 = 688_651_517
    @Published private(set) var transcript = ""
    @Published private(set) var status = "Download the local Parakeet model to begin."

    private let speechEngine = ParakeetStreamingDictationEngine()
    private let modelDownloader = ParakeetModelDownloadCoordinator.shared
    // AVAudioEngine cannot be trusted after a media-services reset. Keep it replaceable so a
    // subsequent recording does not reuse a poisoned input node.
    private var audioEngine = AVAudioEngine()
    private var ledger: DictationTranscriptLedger?
    private var startTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var finalizationToken: UUID?
    private var updateTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var activityStateTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var orphanActivityCleanupTask: Task<Void, Never>?
    private var audioNotificationTasks: [Task<Void, Never>] = []
    private var audioBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var audioPumpTask: Task<AudioPumpResult, Never>?
    private var snapshotStore: DictationSnapshotStore?
    private var tapInstalled = false
    private var sessionGeneration: UInt64 = 0
    private var finalizationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopCommandTracker = DictationStopCommandTracker()

    init() {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.speakfree.keyboard"
        ) {
            snapshotStore = DictationSnapshotStore(appGroupContainerURL: container)
            snapshotStore?.removeTerminalSnapshots(olderThan: 86_400)
            do {
                if let snapshot = try snapshotStore?.read(),
                   !snapshot.isFresh(maximumAge: 120) {
                    try snapshotStore?.remove()
                }
            } catch {
                // This app is the sole writer. Quarantine a malformed/old-schema live slot so a
                // truncated prior write cannot permanently block every future explicit session.
                try? snapshotStore?.remove()
            }
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SpeakFreeModelDownloadUITestFixture") {
            phase = .downloadingModel
            modelDownloadedBytes = 344_325_758
            modelTotalBytes = 688_651_517
            modelProgress = 0.45
            status = "Downloading Parakeet in the background…"
            return
        }
#endif
        observeAudioSessionLifecycle()
        modelDownloader.observe { [weak self] state in
            self?.receiveModelDownloadState(state)
        }
        orphanActivityCleanupTask = Task {
            await DictationLiveActivityCoordinator.shared.endOrphans()
        }
    }

    deinit {
        audioNotificationTasks.forEach { $0.cancel() }
        commandTask?.cancel()
        activityStateTask?.cancel()
        orphanActivityCleanupTask?.cancel()
        finalizationTask?.cancel()
        modelPreparationTask?.cancel()
    }

    var isModelActionAvailable: Bool {
        phase == .modelRequired || isFailure
    }

    var isModelDownloadCancellable: Bool { phase == .downloadingModel }

    var modelActionTitle: String {
        if case .failed = phase {
            return modelDownloadedBytes > 0 ? "Retry Model Download" : "Restart Model Download"
        }
        return modelDownloadedBytes > 0
            ? "Resume Local Model Download"
            : "Download Local Parakeet Model"
    }

    var modelDownloadDetail: String {
        let downloadedMB = Int((Double(modelDownloadedBytes) / 1_000_000).rounded())
        let totalMB = Int((Double(modelTotalBytes) / 1_000_000).rounded())
        return "\(downloadedMB) MB of \(totalMB) MB"
    }

    var diagnosticReport: String {
        let phaseName: String
        switch phase {
        case .modelRequired: phaseName = "modelRequired"
        case .downloadingModel: phaseName = "downloadingModel"
        case .preparingModel: phaseName = "preparingModel"
        case .ready: phaseName = "ready"
        case .starting: phaseName = "starting"
        case .recording: phaseName = "recording"
        case .finalizing: phaseName = "finalizing"
        case .failed: phaseName = "failed"
        }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let permission: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = "granted"
        case .denied: permission = "denied"
        case .undetermined: permission = "undetermined"
        @unknown default: permission = "unknown"
        }
        let snapshotSummary: String
        if let snapshot = try? snapshotStore?.read() {
            snapshotSummary = "phase=\(snapshot.phase.rawValue) revision=\(snapshot.revision)"
        } else {
            snapshotSummary = "unavailable"
        }
        return [
            "SpeakFree Keyboard \(appVersion) (\(build))",
            "iOS \(UIDevice.current.systemVersion)",
            "phase=\(phaseName)",
            "modelBytes=\(modelDownloadedBytes)/\(modelTotalBytes)",
            "modelCachesComplete=\(ParakeetModelDownloadCoordinator.requiredFilesAreCached)",
            "microphonePermission=\(permission)",
            "snapshot=\(snapshotSummary)",
            "status=\(status)",
        ].joined(separator: "\n")
    }

    var isStartAvailable: Bool { phase == .ready }
    var isStopAvailable: Bool { phase == .recording }

    func prepareModel() {
        guard phase != .downloadingModel, phase != .preparingModel, phase != .starting,
              phase != .recording, phase != .finalizing else { return }
        guard ParakeetModelDownloadCoordinator.requiredFilesAreCached else {
            phase = .downloadingModel
            status = "Downloading Parakeet in the background…"
            modelDownloader.startOrResume()
            return
        }
        prepareDownloadedModels()
    }

    func cancelModelDownload() {
        guard phase == .downloadingModel else { return }
        modelDownloader.cancel()
        phase = .modelRequired
        status = "Model download cancelled. Completed files were kept; tap Resume when ready."
    }

    private func prepareDownloadedModels() {
        guard phase != .preparingModel else { return }
        phase = .preparingModel
        status = "Download complete. Preparing Parakeet for local dictation…"
        modelProgress = max(modelProgress, 0.9)

        modelPreparationTask?.cancel()
        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await speechEngine.prepare(model: .englishV2) { [weak self] progress in
                    Task { @MainActor in
                        self?.modelProgress = 0.9 + 0.1 * progress
                    }
                }
                try Task.checkCancellation()
                guard await requestRecordPermission() else {
                    failMessage("Microphone access is required. Enable it in Settings before using background dictation.")
                    return
                }
                persistModelPreparationMarker()
                phase = .ready
                status = "Parakeet is ready. Start a session, then return to the app where you want to type."
            } catch {
                if error is CancellationError { return }
                fail(error)
            }
        }
    }

    private func receiveModelDownloadState(_ state: ParakeetModelDownloadCoordinator.State) {
        let progress = state.progress
        modelDownloadedBytes = progress.downloadedBytes
        modelTotalBytes = progress.totalBytes
        modelProgress = 0.9 * progress.fractionCompleted
        switch state {
        case .completed:
            if phase == .downloadingModel {
                prepareDownloadedModels()
            } else if phase == .modelRequired {
                status = "Parakeet is downloaded. Tap Prepare to finish local setup."
            }
        case .downloading:
            if phase == .modelRequired || isFailure {
                phase = .downloadingModel
            }
            if phase == .downloadingModel {
                status = "Downloading Parakeet in the background…"
            }
        case .cancelled:
            if phase == .downloadingModel {
                phase = .modelRequired
                status = "Model download cancelled. Completed files were kept."
            }
        case .failed(_, let message):
            if phase == .downloadingModel {
                phase = .failed(message)
                status = "Model download failed: \(message). Tap Retry to continue."
            }
        case .idle:
            break
        }
    }

    func start() {
        guard phase == .ready else { return }
        // Move out of .ready synchronously. Permission and model startup both suspend, so leaving
        // the phase unchanged here would let a rapid second tap start a competing audio session.
        phase = .starting
        status = "Starting the microphone…"
        sessionGeneration &+= 1
        let generation = sessionGeneration
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.startSession(generation: generation, requiresLiveActivity: false)
        }
    }

    /// Entry point for Action Button, Control Center, Back Tap, Siri, and Shortcuts. The intent
    /// remains in the containing app process; the keyboard never opens the app or accesses audio.
    @available(iOS 18.0, *)
    func startFromIntent() async throws -> String {
        if phase == .recording { return "SpeakFree is already listening." }
        guard phase != .starting, phase != .finalizing, phase != .preparingModel else {
            throw IntentStartError.busy
        }
        guard hasModelPreparationMarker,
              ParakeetModelDownloadCoordinator.requiredFilesAreCached else {
            if let modelPreparationMarkerURL {
                try? FileManager.default.removeItem(at: modelPreparationMarkerURL)
            }
            throw IntentStartError.setupRequired
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw IntentStartError.microphonePermissionRequired
        }

        if phase != .ready {
            phase = .preparingModel
            status = "Loading the local Parakeet model…"
            do {
                try await speechEngine.prepare(model: .englishV2)
                phase = .ready
            } catch {
                fail(error)
                throw error
            }
        }

        phase = .starting
        status = "Starting background dictation…"
        sessionGeneration &+= 1
        let generation = sessionGeneration
        await startSession(generation: generation, requiresLiveActivity: true)
        guard phase == .recording else { throw IntentStartError.unableToStart }
        return "SpeakFree is listening locally. Tap its red keyboard key to claim the transcript."
    }

    func stop() {
        requestFinish()
    }

    func cancel() {
        guard phase == .recording || phase == .finalizing else { return }
        Task { await cancelSession() }
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func startSession(generation: UInt64, requiresLiveActivity: Bool) async {
        cleanupTask?.cancel()
        guard await requestRecordPermission() else {
            failMessage("Microphone access is required. Enable it in Settings and try again.")
            return
        }
        guard !Task.isCancelled, generation == sessionGeneration else { return }
        guard let snapshotStore else {
            failMessage("The shared App Group is unavailable in this build.")
            return
        }

        do {
            // Recover from a killed/crashed prior writer before creating a new leased session.
            let previous: DictationSnapshot?
            do {
                previous = try snapshotStore.read()
            } catch {
                try snapshotStore.remove()
                previous = nil
            }
            if let previous, previous.phase == .active {
                try snapshotStore.remove()
            }
            let newLedger = DictationTranscriptLedger()
            transcript = ""

            let updates = await speechEngine.updates
            updateTask?.cancel()
            updateTask = Task { [weak self] in
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    self?.receive(update, generation: generation)
                }
            }

            try await speechEngine.begin()
            guard !Task.isCancelled, generation == sessionGeneration else {
                throw CancellationError()
            }
            stopCommandTracker.arm(sessionID: newLedger.sessionID, currentCommand: nil)
            await orphanActivityCleanupTask?.value
            orphanActivityCleanupTask = nil
            let hasLiveActivity = try await DictationLiveActivityCoordinator.shared.start(
                sessionID: newLedger.sessionID,
                required: requiresLiveActivity
            )
            guard !Task.isCancelled, generation == sessionGeneration else {
                if hasLiveActivity {
                    await DictationLiveActivityCoordinator.shared.end(status: "Session cancelled")
                }
                throw CancellationError()
            }
            if hasLiveActivity {
                activityStateTask?.cancel()
                activityStateTask = Task { [weak self] in
                    await DictationLiveActivityCoordinator.shared.waitUntilInactive(
                        sessionID: newLedger.sessionID
                    )
                    guard !Task.isCancelled, let self,
                          self.sessionGeneration == generation else { return }
                    self.activityStateTask = nil
                    if self.phase == .recording {
                        self.requestFinish()
                    } else if self.phase == .starting {
                        await self.cancelSession(
                            failure: "The required Live Activity ended before recording started.",
                            expectedGeneration: generation
                        )
                    }
                }
            }
            try configureAndStartAudioSession()
            startAudioPump(generation: generation)
            try installAudioTap(generation: generation)
            audioEngine.prepare()
            try audioEngine.start()

            // Publish only after capture is live. Setup failure must not leave a claimable
            // "active" session that never actually recorded.
            try snapshotStore.write(newLedger.snapshot(updatedAt: Date()))
            ledger = newLedger

            phase = .recording
            startTask = nil
            if hasLiveActivity,
               !(await DictationLiveActivityCoordinator.shared.isActive(sessionID: newLedger.sessionID)) {
                await cancelSession(
                    failure: "The required Live Activity ended before recording started.",
                    expectedGeneration: generation
                )
                return
            }
            status = "Listening locally. Return to your target app and tap the red dictation key to claim this session."
            scheduleSessionHeartbeat(generation: generation)
            scheduleSessionTimeout(generation: generation)
            scheduleCommandMonitor(generation: generation)
        } catch {
            await cancelSession(
                failure: error.localizedDescription,
                expectedGeneration: generation
            )
        }
    }

    private func receive(
        _ update: ParakeetStreamingDictationEngine.Update,
        generation: UInt64
    ) {
        guard generation == sessionGeneration, phase == .recording, !update.isFinal,
              var currentLedger = ledger,
              let snapshotStore else { return }
        do {
            let snapshot = try currentLedger.update(
                confirmedText: update.confirmedText,
                volatileText: update.volatileText
            )
            try snapshotStore.write(snapshot)
            ledger = currentLedger
            transcript = update.text
            status = update.isConfirmed ? "Stable words updated." : "Listening… words may still improve."
        } catch {
            // A confirmed-prefix regression would make an already-inserted edit unsafe. Stop
            // immediately rather than silently rewriting text the keyboard no longer owns.
            Task {
                await cancelSession(
                    failure: error.localizedDescription,
                    expectedGeneration: generation
                )
            }
        }
    }

    private func finishSession() async {
        guard phase == .recording else { return }
        let generation = sessionGeneration
        phase = .finalizing
        status = "Finishing the last words…"
        commandTask?.cancel()
        commandTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        await DictationLiveActivityCoordinator.shared.update(status: "Finishing…")
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Acquire finite post-recording execution time before capture or its required Live
        // Activity ends; there must be no unprotected suspension point between those states.
        guard beginFinalizationBackgroundTask(generation: generation) else { return }
        defer { endFinalizationBackgroundTask() }
        stopAudioCapture()
        // AudioRecordingIntent requires a Live Activity while capture is active. Capture is now
        // stopped, so end it before the longer best-effort batch pass can be suspended.
        await DictationLiveActivityCoordinator.shared.end(status: "Finishing locally")
        if case .failed(let message) = await finishAudioPump() {
            await cancelSession(failure: message)
            return
        }

        do {
            let finalText = try await speechEngine.finish { [weak self] fallback in
                await self?.checkpointFinalizingFallback(fallback, generation: generation)
            }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard generation == sessionGeneration, phase == .finalizing else { return }
            guard var currentLedger = ledger, let snapshotStore else {
                throw SessionError.missingSession
            }
            let snapshot = try currentLedger.finish(finalText: finalText)
            try snapshotStore.write(snapshot)
            ledger = currentLedger
            transcript = finalText
            updateTask?.cancel()
            updateTask = nil
            phase = .preparingModel
            status = "Dictation finished and saved. Preparing the live model for the next session…"
            deactivateAudioSession()
            await DictationLiveActivityCoordinator.shared.end(status: "Dictation finished")
            scheduleSnapshotRemoval(after: 120)
            // The terminal snapshot is durable before this lower-priority reload begins. If iOS
            // suspends us now, the high-quality result is still available to the keyboard.
            endFinalizationBackgroundTask()
            do {
                try await speechEngine.restoreLiveModel()
                guard generation == sessionGeneration else { return }
                phase = .ready
                status = "Dictation finished. The claimed keyboard session contains the final text."
            } catch {
                guard generation == sessionGeneration else { return }
                phase = .modelRequired
                status = "Dictation finished, but the live model must be prepared again before the next session."
            }
        } catch is CancellationError {
            return
        } catch {
            await cancelSession(failure: error.localizedDescription)
        }
    }

    private func requestFinish() {
        guard phase == .recording else { return }
        finalizationTask?.cancel()
        let token = UUID()
        finalizationToken = token
        finalizationTask = Task { [weak self] in
            await self?.finishSession()
            guard let self else { return }
            if self.finalizationToken == token {
                self.finalizationTask = nil
                self.finalizationToken = nil
            }
        }
    }

    private func checkpointFinalizingFallback(_ text: String, generation: UInt64) {
        guard generation == sessionGeneration, phase == .finalizing,
              var currentLedger = ledger, let snapshotStore else { return }
        do {
            let snapshot = try currentLedger.update(confirmedText: "", volatileText: text)
            try snapshotStore.write(snapshot)
            ledger = currentLedger
            transcript = text
        } catch {
            // Keep the last already-durable preview. The final pass may still produce a safe
            // terminal replacement; expiration will never claim an unpersisted value as latest.
        }
    }

    /// Once capture stops, the audio background mode no longer guarantees execution time. Keep
    /// the finite batch pass alive long enough to publish its terminal snapshot. If iOS expires
    /// that allowance, publish the latest live hypothesis first so the keyboard never waits on a
    /// permanently active session.
    @discardableResult
    private func beginFinalizationBackgroundTask(generation: UInt64) -> Bool {
        endFinalizationBackgroundTask()
        finalizationBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "SpeakFree Dictation Finalization"
        ) { [weak self] in
            // UIKit invokes this handler on the main thread. End the assertion and publish the
            // fallback in that callback; queueing another task can let iOS terminate us first.
            MainActor.assumeIsolated {
                self?.expireFinalization(generation: generation)
            }
        }
        guard finalizationBackgroundTask != .invalid else {
            expireFinalization(generation: generation)
            return false
        }
        return true
    }

    private func expireFinalization(generation: UInt64) {
        guard generation == sessionGeneration, phase == .finalizing else {
            endFinalizationBackgroundTask()
            return
        }
        if var currentLedger = ledger, let snapshotStore,
           let fallback = try? currentLedger.finish(
               finalText: transcript.trimmingCharacters(in: .whitespacesAndNewlines)
           ) {
            try? snapshotStore.write(fallback)
            ledger = currentLedger
        }
        sessionGeneration &+= 1
        finalizationTask?.cancel()
        finalizationTask = nil
        finalizationToken = nil
        stopAudioCapture()
        audioPumpTask?.cancel()
        updateTask?.cancel()
        updateTask = nil
        phase = .modelRequired
        status = "The high-quality final pass timed out in the background. The latest live text was preserved."
        deactivateAudioSession()
        scheduleSnapshotRemoval(after: 120)
        Task { await DictationLiveActivityCoordinator.shared.end(status: "Live result preserved") }
        Task { await speechEngine.cancel() }
        endFinalizationBackgroundTask()
        commandTask?.cancel()
        commandTask = nil
    }

    private func endFinalizationBackgroundTask() {
        guard finalizationBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finalizationBackgroundTask)
        finalizationBackgroundTask = .invalid
    }

    private func cancelSession(
        failure: String? = nil,
        expectedGeneration: UInt64? = nil
    ) async {
        guard expectedGeneration == nil || expectedGeneration == sessionGeneration else { return }
        if phase == .finalizing {
            finalizationTask?.cancel()
            finalizationTask = nil
            finalizationToken = nil
        }
        endFinalizationBackgroundTask()
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        stopAudioCapture()
        // Cancellation is an abort, unlike Stop. Drop queued buffers so an overloaded or wedged
        // recognizer cannot delay teardown and race a later session.
        audioPumpTask?.cancel()
        _ = await finishAudioPump()
        await speechEngine.cancel()
        if var currentLedger = ledger, let snapshotStore {
            if let snapshot = try? currentLedger.cancel() {
                try? snapshotStore.write(snapshot)
            }
        }
        ledger = nil
        updateTask?.cancel()
        updateTask = nil
        deactivateAudioSession()
        await DictationLiveActivityCoordinator.shared.end(
            status: failure == nil ? "Dictation cancelled" : "Dictation stopped"
        )
        if let failure {
            failMessage(failure)
        } else {
            phase = .ready
            status = "Dictation cancelled. Unstable words were discarded."
        }
        scheduleSnapshotRemoval(after: 30)
    }

    private func installAudioTap(generation: UInt64) throws {
        guard !tapInstalled else { return }
        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SessionError.invalidInputFormat
        }
        guard let continuation = audioBufferContinuation else { return }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            guard let copy = try? ParakeetStreamingDictationEngine.copyForStreaming(buffer) else {
                return
            }
            switch continuation.yield(copy) {
            case .enqueued:
                break
            case .dropped:
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .recording,
                          self.sessionGeneration == generation else { return }
                    await self.cancelSession(
                        failure: "Audio processing could not keep up. The session stopped without rewriting your text.",
                        expectedGeneration: generation
                    )
                }
            case .terminated:
                // Expected when Stop closes the stream while a realtime callback is in flight.
                break
            @unknown default:
                break
            }
        }
        tapInstalled = true
    }

    private func stopAudioCapture() {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioBufferContinuation?.finish()
        audioBufferContinuation = nil
    }

    private func startAudioPump(generation: UInt64) {
        audioPumpTask?.cancel()
        let stream = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        audioBufferContinuation = stream.continuation
        let targetEngine = speechEngine
        let task = Task<AudioPumpResult, Never> {
            do {
                for await buffer in stream.stream {
                    guard !Task.isCancelled else { return .cancelled }
                    try await targetEngine.append(buffer)
                }
                return .completed
            } catch {
                return Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
        audioPumpTask = task
        Task { @MainActor [weak self] in
            guard case .failed(let message) = await task.value,
                  let self,
                  self.phase == .recording,
                  self.sessionGeneration == generation else { return }
            await self.cancelSession(failure: message, expectedGeneration: generation)
        }
    }

    private func finishAudioPump() async -> AudioPumpResult {
        audioBufferContinuation?.finish()
        audioBufferContinuation = nil
        let task = audioPumpTask
        let result = await task?.value ?? .completed
        audioPumpTask = nil
        return result
    }

    private func configureAndStartAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .record,
            mode: .measurement,
            options: [.allowBluetoothHFP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func scheduleSessionTimeout(generation: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self,
                  self.sessionGeneration == generation else { return }
            self.timeoutTask = nil
            self.requestFinish()
        }
    }

    private func scheduleSessionHeartbeat(generation: UInt64) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self,
                      self.sessionGeneration == generation, phase == .recording,
                      var currentLedger = ledger, let snapshotStore else { return }
                do {
                    try snapshotStore.write(currentLedger.heartbeat())
                    ledger = currentLedger
                } catch {
                    await cancelSession(
                        failure: error.localizedDescription,
                        expectedGeneration: generation
                    )
                    return
                }
            }
        }
    }

    private func scheduleCommandMonitor(generation: UInt64) {
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self,
                      self.sessionGeneration == generation, self.phase == .recording else { return }
                let command = SpeakFreeDictationCommandStore.readStopCommand()
                guard self.stopCommandTracker.shouldStop(for: command) else { continue }
                self.commandTask = nil
                self.requestFinish()
                return
            }
        }
    }

    private var modelPreparationMarkerURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("speakfree-parakeet-prepared-v1", isDirectory: false)
    }

    private var hasModelPreparationMarker: Bool {
        guard let modelPreparationMarkerURL else { return false }
        return FileManager.default.fileExists(atPath: modelPreparationMarkerURL.path)
    }

    private func persistModelPreparationMarker() {
        guard let modelPreparationMarkerURL else { return }
        try? FileManager.default.createDirectory(
            at: modelPreparationMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data().write(to: modelPreparationMarkerURL, options: .atomic)
    }

    private func scheduleSnapshotRemoval(after seconds: TimeInterval) {
        cleanupTask?.cancel()
        guard let snapshotStore else { return }
        cleanupTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            try? snapshotStore.remove()
        }
    }

    private func observeAudioSessionLifecycle() {
        audioNotificationTasks = [
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVAudioSession.interruptionNotification
                ) {
                    guard !Task.isCancelled else { return }
                    self?.handleAudioInterruption(notification)
                }
            },
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVAudioSession.routeChangeNotification
                ) {
                    guard !Task.isCancelled else { return }
                    self?.handleAudioRouteChange(notification)
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: AVAudioSession.mediaServicesWereResetNotification
                ) {
                    guard !Task.isCancelled else { return }
                    self?.handleMediaServicesReset()
                }
            }
        ]
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard phase == .recording,
              let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
        requestFinish()
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard phase == .recording,
              let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue),
              reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory else {
            return
        }
        requestFinish()
    }

    private func handleMediaServicesReset() {
        // Every AVAudioEngine and node becomes invalid after this notification, even if it was
        // merely prepared for a later recording. Never retain the pre-reset graph.
        startTask?.cancel()
        startTask = nil
        if phase == .recording || phase == .finalizing {
            let generation = sessionGeneration
            Task {
                guard generation == sessionGeneration else { return }
                await cancelSession(
                    failure: "The audio system restarted. Your confirmed text was preserved; start a new dictation session.",
                    expectedGeneration: generation
                )
                audioEngine = AVAudioEngine()
            }
        } else {
            stopAudioCapture()
            audioEngine = AVAudioEngine()
            if phase == .starting {
                failMessage("The audio system restarted while the microphone was starting. Try again.")
            }
        }
    }

    private func fail(_ error: Error) {
        failMessage(error.localizedDescription)
    }

    private func failMessage(_ message: String) {
        logger.error("Dictation failed: \(message, privacy: .public)")
        phase = .failed(message)
        status = message
    }
}

private enum SessionError: LocalizedError {
    case missingSession
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "The shared dictation session was lost. No host text was changed."
        case .invalidInputFormat:
            return "No usable microphone route is available. Reconnect the microphone and try again."
        }
    }
}

private enum IntentStartError: LocalizedError {
    case setupRequired
    case microphonePermissionRequired
    case busy
    case unableToStart

    var errorDescription: String? {
        switch self {
        case .setupRequired:
            return "Open SpeakFree once and download the local Parakeet models before using the shortcut."
        case .microphonePermissionRequired:
            return "Open SpeakFree and allow microphone access before using the shortcut. Your downloaded models are still ready."
        case .busy:
            return "SpeakFree is already preparing or finishing a dictation session."
        case .unableToStart:
            return "SpeakFree could not start background dictation. Open the app to see the recovery message."
        }
    }
}

private enum AudioPumpResult: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}
