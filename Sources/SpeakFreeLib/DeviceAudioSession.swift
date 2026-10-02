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
    private var verifyTimer: DispatchSourceTimer? // worker only
    private let cancelLock = NSLock()
    private var cancelled = false
    /// Set once the sample clock is steady AND the live input stream still matches the tap
    /// format. No sample leaves this session before then (2026-09-25 AirPods static).
    private var verified = false
    private var reportedFailure = false
    private var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled }
    private var isVerified: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return verified }
    /// Live device rates; injectable so the verification rule is testable without hardware.
    private let liveRates: (AudioDeviceID) -> CaptureFormatCheck.LiveRates
    static let recheckSeconds: Double = 2
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

    init(liveRates: @escaping (AudioDeviceID) -> CaptureFormatCheck.LiveRates = AudioDeviceCatalog.liveInputRates(of:)) {
        self.liveRates = liveRates
    }

    /// One failure per session: the tap, the worker checks and the engine observer can all
    /// notice the same fault.
    private func reportOnce(_ failure: (String) -> Void, _ reason: String) {
        cancelLock.lock()
        let first = !reportedFailure && !cancelled
        reportedFailure = true
        verified = false
        cancelLock.unlock()
        if first { failure(reason) }
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
                self.reportOnce(failure, exception?.localizedDescription ?? swiftError?.localizedDescription ?? "Audio startup failed")
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
            self.reportOnce(failure, "Audio engine stopped after a device configuration change")
        }
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.invalid("No input audio unit") }
        var deviceID = device.id
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout.size(ofValue: deviceID)))
        guard result == noErr else { throw CaptureError.invalid("Microphone binding failed (\(result))") }
        guard !isCancelled else { throw CaptureError.invalid("Capture request superseded") }
        let format = input.inputFormat(forBus: 0)
        // Checked against the device's LIVE input stream, not the catalog snapshot: on
        // 2026-09-25 the snapshot said 24 kHz, a retry five seconds later opened at 48 kHz
        // and passed, and that stream delivered static for 36 minutes.
        if case .mismatch(let why) = check(device: device, format: format) {
            throw CaptureError.invalid("Unsettled format: \(why)")
        }
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let resampler = AudioBufferResampler(inputFormat: format, outputFormat: target) else {
            throw CaptureError.invalid("Cannot convert microphone format")
        }
        var clock = CaptureClockGuard()
        var rejected = 0
        var outputTime: Double?
        var failed = false
        var clockSettled = false
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self, !failed else { return }
            guard when.isHostTimeValid, buffer.format == format else {
                failed = true
                self.reportOnce(failure, "Microphone format changed during capture")
                return
            }
            let time = AVAudioTime.seconds(forHostTime: when.hostTime)
            guard clock.accept(start: time, frames: Int(buffer.frameLength), rate: buffer.format.sampleRate) else {
                rejected += 1
                if outputTime != nil || clockSettled || rejected >= 8 {
                    failed = true
                    self.reportOnce(failure, "Microphone timestamps disagree with its sample rate (\(Int(format.sampleRate)) Hz)")
                }
                return
            }
            rejected = 0
            if !clockSettled {
                clockSettled = true
                self.worker.async { self.confirm(device: device, format: format, failure: failure) }
            }
            guard self.isVerified else { return }
            guard let converted = resampler.convert(buffer), let data = converted.floatChannelData?[0] else { return }
            let start = outputTime ?? time
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
            outputTime = start + Double(samples.count) / 16_000
            packet(CapturePacket(start: start, samples: samples))
        }
        try engine.start()
        DiagnosticLogger.shared.log("Capture: started \(device.name), \(format.sampleRate) Hz / \(format.channelCount) ch; checking sample clock")
    }

    /// Worker only. The sample clock is steady; re-read the live input stream before a single
    /// sample is used, write the result line, then keep re-checking while the session lives.
    private func confirm(device: AudioInputDevice, format: AVAudioFormat, failure: @escaping (String) -> Void) {
        guard !isCancelled, engine != nil else { return }
        cancelLock.lock(); let alreadyFailed = reportedFailure; cancelLock.unlock()
        guard !alreadyFailed else { return }
        if case .mismatch(let why) = check(device: device, format: format) {
            DiagnosticLogger.shared.log("Capture: \(device.name) not verified: \(why)")
            reportOnce(failure, "Unverified format: \(why)")
            return
        }
        cancelLock.lock(); verified = !reportedFailure && !cancelled; cancelLock.unlock()
        DiagnosticLogger.shared.log(String(format: "Capture: %@ verified: sample clock steady at %.0f Hz; input stream matches",
                                           device.name, format.sampleRate))
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + Self.recheckSeconds, repeating: Self.recheckSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isCancelled else { return }
            if case .mismatch(let why) = self.check(device: device, format: format) {
                self.verifyTimer?.cancel(); self.verifyTimer = nil
                self.reportOnce(failure, "Microphone format changed: \(why)")
            }
        }
        verifyTimer = timer
        timer.resume()
    }

    private func check(device: AudioInputDevice, format: AVAudioFormat) -> CaptureFormatCheck.Verdict {
        CaptureFormatCheck.verdict(tapRate: format.sampleRate, tapChannels: format.channelCount,
                                   live: liveRates(device.id), deviceChannels: device.inputChannels,
                                   isBluetooth: device.isBluetooth)
    }

    func stop() {
        cancelLock.lock(); cancelled = true; verified = false; cancelLock.unlock()
        worker.async { self.retire() }
    }

    private func retire() {
        verifyTimer?.cancel(); verifyTimer = nil
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

/// Is the tap's format the one the microphone is really delivering right now? Pure, so the
/// rule is tested without hardware.
enum CaptureFormatCheck {
    struct LiveRates: Equatable {
        var nominal: Double
        /// Rate of the device's first input stream; 0 when unreadable.
        var stream: Double
    }

    enum Verdict: Equatable {
        case verified
        case mismatch(String)
    }

    static func verdict(tapRate: Double, tapChannels: UInt32, live: LiveRates,
                        deviceChannels: Int, isBluetooth: Bool) -> Verdict {
        guard tapRate > 0, tapChannels > 0 else { return .mismatch("no input format") }
        if deviceChannels > 0, Int(tapChannels) > deviceChannels {
            return .mismatch("\(tapChannels) ch tap; microphone has \(deviceChannels) ch")
        }
        let rates = String(format: "tap %.0f Hz; input stream %.0f Hz; device %.0f Hz", tapRate, live.stream, live.nominal)
        if live.stream > 0 {
            // The rate the microphone delivers must be the rate the tap is labelled with.
            return abs(tapRate - live.stream) <= 1 ? .verified : .mismatch(rates)
        }
        // Input stream unreadable: the previous nominal-rate rule. A Bluetooth headset's
        // nominal rate can describe its output side, so a lower tap rate is allowed there.
        return AudioRecorder.isCaptureFormatUsable(engineRate: tapRate, engineChannels: tapChannels,
            deviceRate: live.nominal, deviceChannels: deviceChannels, deviceIsBluetooth: isBluetooth)
            ? .verified : .mismatch(rates)
    }
}
