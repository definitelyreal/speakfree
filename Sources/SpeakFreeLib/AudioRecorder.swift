// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
// ai-processed:unverified · session:unknown/agent:audio_file_integrity · 2026-10-02
import AppKit
import AVFoundation
import Foundation

/// Recording and pre-roll storage. Device lifecycle lives on independent workers;
/// the short capture-control queue owns recording boundaries and sample ordering.
class AudioRecorder {
    private(set) var capture: MicrophoneCaptureCoordinator!
    private let writeQueue = DispatchQueue(label: "com.speakfree.audiowrite")
    private let healthLock = NSLock()
    private var latestRMS: Float = 0
    private var peakSinceCheck: Float = 0
    private var lastBufferUptime = ProcessInfo.processInfo.systemUptime
    private var recording = false // capture.queue
    private var preroll: [Float] = [] // capture.queue
    private var prelistenActive = true // capture.queue
    /// Key press seen, take not started yet (capture.queue). While armed, pre-roll keeps every
    /// sample instead of only the last 500 ms, so file-system stalls between key press and
    /// `startRecording` (logged up to 2.4 s, 2026-09-22) no longer drop the first words.
    private var armed = false
    /// Runaway bound for an armed pre-roll whose take never starts.
    static let armedPrerollCapSamples = 16_000 * 60
    static let prerollSamples = 8_000
    private var lastSource = "Microphone connecting"
    private var recordingSources: [String] = []
    private var outputURL: URL?
    private var pcmSamples: [Float] = [] // writeQueue
    private var audioFile: WavWriter? // writeQueue
    private var writeFailed = false
    private let writerFactory: (URL) throws -> WavWriter
    private let installArchive: (URL, URL) throws -> Void

    struct CompletedRecording {
        let url: URL
        let samples: [Float]
        /// nil after successful writes + header/length validation, or a fully checked repair.
        let archiveError: String?
        var audioFileIsValid: Bool { archiveError == nil }
    }
    private var monitorsStarted = false // main
    private var observers: [NSObjectProtocol] = []
    private(set) var pinnedInputDeviceUID: String?
    /// The headset "Stay on" routes to (nil when off or paused). See StayOnController.
    private(set) var stayOnDeviceUID: String?
    var onCaptureStatus: ((String) -> Void)?

    init(factory: @escaping () -> DeviceCapturing = { DeviceAudioSession() },
         writerFactory: @escaping (URL) throws -> WavWriter = { try WavWriter(url: $0) },
         installArchive: @escaping (URL, URL) throws -> Void = { try WavWriter.installReplacement($0, at: $1) }) {
        self.writerFactory = writerFactory
        self.installArchive = installArchive
        capture = MicrophoneCaptureCoordinator(factory: factory, samples: { [weak self] samples, source in
            self?.receive(samples, source: source)
        }, status: { [weak self] message in
            DispatchQueue.main.async { [weak self] in self?.onCaptureStatus?(message) }
        }, replace: { [weak self] index, samples, source in
            self?.replaceTail(from: index, with: samples, source: source)
        })
    }

    /// capture.queue. The coordinator found the headset stretch of this take was static and
    /// hands over what the Mac's own microphone heard instead, from `index` on.
    func replaceTail(from index: Int, with samples: [Float], source: String) {
        guard recording else { return }
        if !recordingSources.contains(source) { recordingSources.append(source) }
        writeQueue.async {
            let keep = min(max(0, index), self.pcmSamples.count)
            self.pcmSamples.removeSubrange(keep...)
            self.pcmSamples += samples
            // Once a write fails, only memory is authoritative. Do not append to a stale
            // file offset; finalization rebuilds the complete archive in a separate file.
            guard !self.writeFailed else { return }
            do {
                try self.audioFile?.truncate(toSamples: keep)
                try self.audioFile?.append(samples)
            } catch { self.noteWriteFailure(error) }
        }
    }

    var preBufferEnabled = true {
        didSet {
            let enabled = preBufferEnabled
            capture.queue.async {
                self.prelistenActive = enabled
                if !enabled { self.preroll = [] }
            }
            updateRouting()
        }
    }
    var currentLevel: Float { min(currentRMS / 0.15, 1) }
    var currentRMS: Float {
        healthLock.lock(); defer { healthLock.unlock() }
        return latestRMS
    }

    func warmUp() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.warmUp() }; return
        }
        if !monitorsStarted {
            monitorsStarted = true
            AudioDeviceCatalog.onDeviceListChanged = { [weak self] _, devices in self?.handleDeviceListChanged(devices) }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.capture.queue.async { self.preroll = [] }
                self.capture.suspend()
            })
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.handleSystemResume("wake/session resume")
                })
            }
        }
        updateRouting()
        capture.start()
    }

    private func updateRouting() {
        capture.configure(devices: AudioDeviceCatalog.cachedInputDevices,
            systemDefault: AudioDeviceCatalog.cachedDefaultInput,
            pin: pinnedInputDeviceUID, prelisten: preBufferEnabled, stayOn: stayOnDeviceUID)
    }

    func setPinnedInputDevice(uid: String?) {
        guard uid != pinnedInputDeviceUID else { return }
        pinnedInputDeviceUID = uid
        updateRouting()
    }

    func setStayOnDevice(uid: String?) {
        guard uid != stayOnDeviceUID else { return }
        stayOnDeviceUID = uid
        updateRouting()
    }

    func handleDeviceListChanged(_ devices: [AudioInputDevice]) { updateRouting() }
    func handleSystemResume(_ reason: String) {
        AudioDeviceCatalog.refreshNow { [weak self] in
            guard let self else { return }
            self.capture.queue.async { self.preroll = [] }
            self.updateRouting(); self.capture.resume()
        }
    }
    func ensureAudioHealthy() { capture.recover() }
    func recoverDeadCaptureDuringRecording() { capture.recover() }
    func recoverFailedCapture() {
        capture.queue.async { self.preroll = [] }
        capture.recoverFailedCapture()
    }
    func shutdown() { capture.stop() }

    func currentCaptureDeviceName() -> String? {
        capture.queue.sync { recordingSources.isEmpty ? lastSource : recordingSources.joined(separator: " → ") }
    }

    private func receive(_ samples: [Float], source: String) {
        guard !samples.isEmpty else { return }
        lastSource = source
        var sum: Float = 0, peak: Float = 0
        for sample in samples { sum += sample * sample; peak = max(peak, abs(sample)) }
        healthLock.lock()
        latestRMS = sqrt(sum / Float(samples.count))
        peakSinceCheck = max(peakSinceCheck, peak)
        lastBufferUptime = ProcessInfo.processInfo.systemUptime
        healthLock.unlock()
        if recording {
            if !recordingSources.contains(source) { recordingSources.append(source) }
            append(samples)
        } else if prelistenActive || armed {
            preroll += samples
            let cap = armed ? Self.armedPrerollCapSamples : Self.prerollSamples
            if preroll.count > cap { preroll.removeFirst(preroll.count - cap) }
        }
    }

    private func append(_ samples: [Float]) {
        writeQueue.async {
            self.pcmSamples += samples
            guard !self.writeFailed else { return }
            do { try self.audioFile?.append(samples) }
            catch { self.noteWriteFailure(error) }
        }
    }

    private func noteWriteFailure(_ error: Error) {
        if !writeFailed {
            if let url = audioFile?.url {
                do { try AudioArchiveIntegrity.markInvalid(url) }
                catch { DiagnosticLogger.shared.log("Capture: could not persist invalid-archive marker; file recognition blocked in this process") }
            }
            DiagnosticLogger.shared.log("Capture: WAV write failed: \(error.localizedDescription); in-memory audio retained")
        }
        writeFailed = true
    }

    /// Call at key press, before any file-system work: from here until `startRecording` (or
    /// its failure) the pre-roll keeps everything captured. Async so key press never waits on
    /// the capture queue; `startRecording` runs on the same serial queue, so it sees the flag.
    func armTake() {
        capture.queue.async {
            if !self.recording { self.armed = true }
        }
    }

    /// Undo `armTake` when record start fails before `startRecording` runs (the caller's catch
    /// path), so pre-roll trims back to 500 ms instead of carrying unrelated audio into the next take.
    func disarmTake() {
        capture.queue.async { self.armed = false }
    }

    func startRecording(to url: URL) throws {
        try capture.queue.sync {
            guard !recording else { return }
            // Disarm on every exit, including a WavWriter failure, so pre-roll trims again.
            defer { armed = false }
            let file = try writerFactory(url)
            outputURL = url
            writeQueue.sync { audioFile = file; pcmSamples = []; writeFailed = false }
            recordingSources = preroll.isEmpty ? [] : [lastSource]
            append(preroll)
            DiagnosticLogger.shared.log("AudioRecorder: recording started, pre-roll \(preroll.count) samples, input device: \(lastSource)")
            if preroll.count > Self.prerollSamples {
                DiagnosticLogger.shared.log(String(
                    format: "AudioRecorder: kept %.2fs captured while recording start was delayed",
                    Double(preroll.count - Self.prerollSamples) / 16_000))
            }
            let prerollCount = preroll.count
            preroll = []
            recording = true
            capture.setRecording(true, prerollSamples: prerollCount)
        }
    }

    func stopRecording() -> CompletedRecording? {
        capture.queue.sync {
            guard recording, let url = outputURL else { return nil }
            capture.flush()
            recording = false
            capture.setRecording(false)
            var result: [Float] = []
            var archiveError: String?
            writeQueue.sync {
                // Keep the original writer's lease through validation and atomic publication.
                let lease = try? RecordingActivity.shared.acquire(url)
                defer { lease?.release() }
                do { try audioFile?.finish() } catch { noteWriteFailure(error) }
                audioFile = nil
                result = pcmSamples; pcmSamples = []
                do {
                    try Self.finalizeArchive(url: url, samples: result, writeFailed: writeFailed,
                                             writerFactory: writerFactory, install: installArchive)
                } catch {
                    archiveError = error.localizedDescription
                    DiagnosticLogger.shared.log("AudioRecorder: archive repair failed; file recognition disabled: \(error.localizedDescription)")
                }
            }
            outputURL = nil
            DiagnosticLogger.shared.log("AudioRecorder: recording stopped, \(result.count) samples (\(String(format: "%.2f", Double(result.count)/16000))s), sources: \(recordingSources.joined(separator: " → "))")
            return CompletedRecording(url: url, samples: result, archiveError: archiveError)
        }
    }

    func currentSamples() -> [Float] { writeQueue.sync { pcmSamples } }
    func currentSampleCount() -> Int { writeQueue.sync { pcmSamples.count } }
    func samples(after index: Int) -> [Float] { writeQueue.sync { Self.trailingSlice(pcmSamples, after: max(0, index)) } }
    func secondsSinceLastBuffer() -> Double {
        healthLock.lock(); defer { healthLock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastBufferUptime
    }
    func peakSinceLastCheck() -> Float {
        healthLock.lock(); defer { healthLock.unlock() }
        defer { peakSinceCheck = 0 }
        return peakSinceCheck
    }
    deinit {
        capture.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

enum AudioRecorderError: LocalizedError {
    case engineStartFailed
    var errorDescription: String? { "Audio engine failed to start" }
}
