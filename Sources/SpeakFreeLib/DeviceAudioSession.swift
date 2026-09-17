// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
import AVFoundation
import AudioToolbox
import CTryCatch

protocol DeviceCapturing: AnyObject {
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
               failure: @escaping (String) -> Void)
    func stop()
}

/// All driver calls and engine references belong to this independent worker. A
/// blocked Bluetooth start cannot hold up the built-in stream, routing, or the UI.
final class DeviceAudioSession: DeviceCapturing {
    private let worker = DispatchQueue(label: "com.speakfree.devicecapture.\(UUID())", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var reportedConfigurationStop = false // worker only
    private let cancelLock = NSLock()
    private var cancelled = false
    private var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled }
    private static let budgetLock = NSLock()
    private static var starting: [String: Int] = [:]
    private static func acquire(_ uid: String) -> Bool {
        budgetLock.lock(); defer { budgetLock.unlock() }
        guard (starting[uid] ?? 0) < 2 else { return false }
        starting[uid, default: 0] += 1; return true
    }
    private static func release(_ uid: String) {
        budgetLock.lock(); defer { budgetLock.unlock() }
        starting[uid, default: 1] -= 1
    }

    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
               failure: @escaping (String) -> Void) {
        worker.async {
            guard !self.isCancelled else { return }
            guard Self.acquire(device.uid) else { failure("Microphone driver is still busy with earlier startup requests"); return }
            defer { Self.release(device.uid) }
            var exception: NSError?
            var swiftError: Error?
            let okay = CTryCatch({
                do { try self.configure(device: device, packet: packet, failure: failure) }
                catch { swiftError = error }
            }, &exception)
            if !okay || swiftError != nil {
                failure(exception?.localizedDescription ?? swiftError?.localizedDescription ?? "Audio startup failed")
                self.retire()
            }
        }
    }

    private func configure(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
                           failure: @escaping (String) -> Void) throws {
        let engine = AVAudioEngine()
        self.engine = engine // Failed candidates also stay worker-owned.
        configurationObserver = Self.observeStoppedEngine(engine, on: worker) { [weak self] in
            guard let self, !self.isCancelled, !self.reportedConfigurationStop else { return }
            self.reportedConfigurationStop = true
            failure("Audio engine stopped after a device configuration change")
        }
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.invalid("No input audio unit") }
        var deviceID = device.id
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout.size(ofValue: deviceID)))
        guard result == noErr else { throw CaptureError.invalid("Microphone binding failed (\(result))") }
        guard !isCancelled else { throw CaptureError.invalid("Capture request superseded") }
        let format = input.inputFormat(forBus: 0)
        guard AudioRecorder.isCaptureFormatUsable(engineRate: format.sampleRate,
            engineChannels: format.channelCount, deviceRate: device.nominalSampleRate,
            deviceChannels: device.inputChannels, deviceIsBluetooth: device.isBluetooth) else {
            throw CaptureError.invalid("Unsettled format: \(format.sampleRate) Hz / \(format.channelCount) ch; hardware \(device.nominalSampleRate) Hz")
        }
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let resampler = AudioBufferResampler(inputFormat: format, outputFormat: target) else {
            throw CaptureError.invalid("Cannot convert microphone format")
        }
        var clock = CaptureClockGuard()
        var rejected = 0
        var outputTime: Double?
        var failed = false
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            guard !failed else { return }
            guard when.isHostTimeValid, buffer.format == format else {
                failed = true
                failure("Microphone format changed during capture")
                return
            }
            let time = AVAudioTime.seconds(forHostTime: when.hostTime)
            guard clock.accept(start: time, frames: Int(buffer.frameLength), rate: buffer.format.sampleRate) else {
                rejected += 1
                if outputTime != nil || rejected >= 8 {
                    failed = true
                    failure("Microphone timestamps disagree with its sample rate")
                }
                return
            }
            rejected = 0
            guard let converted = resampler.convert(buffer), let data = converted.floatChannelData?[0] else { return }
            let start = outputTime ?? time
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
            outputTime = start + Double(samples.count) / 16_000
            packet(CapturePacket(start: start, samples: samples))
        }
        try engine.start()
        DiagnosticLogger.shared.log("Capture: started \(device.name), \(format.sampleRate) Hz / \(format.channelCount) ch; checking sample clock")
    }

    func stop() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
        worker.async { self.retire() }
    }

    private func retire() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        BackgroundDisposal.retire(&engine, linger: 8, prepare: { engine in
            var exception: NSError?
            _ = CTryCatch({ engine.inputNode.removeTap(onBus: 0); engine.stop() }, &exception)
        })
    }

    /// Output route changes can stop an engine even with its input pinned to
    /// the built-in mic. React on its worker instead of waiting 1.5–2.5 seconds
    /// for missing samples. Apple explicitly forbids teardown in the notification
    /// callback: its internal audio queue must never wait for driver/UI work.
    static func observeStoppedEngine(
        _ engine: AVAudioEngine, center: NotificationCenter = .default,
        on queue: DispatchQueue, onStopped: @escaping () -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak engine] _ in
            queue.async { [weak engine] in
                guard let engine, !engine.isRunning else { return }
                onStopped()
            }
        }
    }

    enum CaptureError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}
