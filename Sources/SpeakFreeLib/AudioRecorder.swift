// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
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
    private var lastSource = "Microphone connecting"
    private var recordingSources: [String] = []
    private var outputURL: URL?
    private var pcmSamples: [Float] = [] // writeQueue
    private var audioFile: WavWriter? // writeQueue
    private var writeFailed = false
    private var monitorsStarted = false // main
    private var observers: [NSObjectProtocol] = []
    private(set) var pinnedInputDeviceUID: String?
    var onCaptureStatus: ((String) -> Void)?

    init(factory: @escaping () -> DeviceCapturing = { DeviceAudioSession() }) {
        capture = MicrophoneCaptureCoordinator(factory: factory, samples: { [weak self] samples, source in
            self?.receive(samples, source: source)
        }, status: { [weak self] message in
            DispatchQueue.main.async { [weak self] in self?.onCaptureStatus?(message) }
        })
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
            pin: pinnedInputDeviceUID, prelisten: preBufferEnabled)
    }

    func setPinnedInputDevice(uid: String?) {
        guard uid != pinnedInputDeviceUID else { return }
        pinnedInputDeviceUID = uid
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
        } else if prelistenActive {
            preroll += samples
            if preroll.count > 8000 { preroll.removeFirst(preroll.count - 8000) }
        }
    }

    private func append(_ samples: [Float]) {
        writeQueue.async {
            self.pcmSamples += samples
            do { try self.audioFile?.append(samples) }
            catch {
                if !self.writeFailed {
                    self.writeFailed = true
                    DiagnosticLogger.shared.log("Capture: WAV write failed: \(error.localizedDescription); in-memory audio retained")
                }
            }
        }
    }

    func startRecording(to url: URL) throws {
        try capture.queue.sync {
            guard !recording else { return }
            let file = try WavWriter(url: url)
            outputURL = url
            writeQueue.sync { audioFile = file; pcmSamples = []; writeFailed = false }
            recordingSources = preroll.isEmpty ? [] : [lastSource]
            append(preroll)
            DiagnosticLogger.shared.log("AudioRecorder: recording started, pre-roll \(preroll.count) samples, input device: \(lastSource)")
            preroll = []
            recording = true
            capture.setRecording(true)
        }
    }

    func stopRecording() -> (url: URL, samples: [Float])? {
        capture.queue.sync {
            guard recording, let url = outputURL else { return nil }
            capture.flush()
            recording = false
            capture.setRecording(false)
            var result: [Float] = []
            writeQueue.sync {
                audioFile?.close(); audioFile = nil
                result = pcmSamples; pcmSamples = []
                Self.recoverArchiveIfHeaderOnly(url: url, samples: result)
            }
            outputURL = nil
            DiagnosticLogger.shared.log("AudioRecorder: recording stopped, \(result.count) samples (\(String(format: "%.2f", Double(result.count)/16000))s), sources: \(recordingSources.joined(separator: " → "))")
            return (url, result)
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
