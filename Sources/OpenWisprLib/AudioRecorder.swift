import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private var currentOutputURL: URL?
    // Serial queue protects audioFile + pcmSamples from concurrent access
    private let writeQueue = DispatchQueue(label: "com.openwisprmod.audiowrite")
    // Accumulated Float32 PCM samples for direct engine use (16kHz mono)
    private var pcmSamples: [Float] = []

    /// Current RMS audio level (0.0–1.0), updated from the audio tap.
    private(set) var currentLevel: Float = 0

    // MARK: - Pre-roll buffer

    /// Always-running engine that captures the last ~500ms of audio.
    /// When recording starts, the pre-roll is prepended so no speech is lost.
    private var prerollEngine: AVAudioEngine?
    private var prerollConverter: AVAudioConverter?
    private let prerollLock = NSLock()
    private var prerollBuffer: [Float] = []
    private let prerollMaxSamples = 8000  // 500ms at 16kHz

    /// Start the pre-roll listener. Call once on app launch.
    func warmUp() {
        startPreroll()
    }

    private func startPreroll() {
        stopPreroll()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("AudioRecorder: pre-roll converter failed")
            return
        }

        prerollConverter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            // Don't capture pre-roll while actively recording — the recording tap handles that
            guard !self.isRecording else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            conv.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil && convertedBuffer.frameLength > 0,
               let channelData = convertedBuffer.floatChannelData?[0] {
                let count = Int(convertedBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: count))

                self.prerollLock.lock()
                self.prerollBuffer.append(contentsOf: samples)
                // Keep only the last 500ms
                if self.prerollBuffer.count > self.prerollMaxSamples {
                    self.prerollBuffer.removeFirst(self.prerollBuffer.count - self.prerollMaxSamples)
                }
                self.prerollLock.unlock()

                // Update RMS for visualizer even when not recording
                var sum: Float = 0
                for i in 0..<count { sum += channelData[i] * channelData[i] }
                let rms = sqrtf(sum / Float(max(count, 1)))
                self.currentLevel = min(rms / 0.15, 1.0)
            }
        }

        do {
            try engine.start()
            prerollEngine = engine
        } catch {
            print("AudioRecorder: pre-roll engine start failed: \(error.localizedDescription)")
        }
    }

    private func stopPreroll() {
        prerollEngine?.inputNode.removeTap(onBus: 0)
        prerollEngine?.stop()
        prerollEngine = nil
        prerollConverter = nil
        prerollLock.lock()
        prerollBuffer = []
        prerollLock.unlock()
    }

    /// Take the pre-roll samples and clear the buffer.
    private func drainPreroll() -> [Float] {
        prerollLock.lock()
        let samples = prerollBuffer
        prerollBuffer = []
        prerollLock.unlock()
        return samples
    }

    // MARK: - Recording

    func startRecording(to outputURL: URL) throws {
        guard !isRecording else { return }

        // Grab pre-roll audio captured before fn was pressed
        let preroll = drainPreroll()

        // Stop the pre-roll engine — we'll use a fresh engine for recording
        // to avoid two taps on the same input node
        stopPreroll()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        audioFile = try AVAudioFile(forWriting: outputURL, settings: settings)
        currentOutputURL = outputURL

        // Seed PCM samples with pre-roll audio
        pcmSamples = preroll

        // Write pre-roll to WAV file too
        if !preroll.isEmpty {
            writePrerollToFile(preroll, format: targetFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            conv.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil && convertedBuffer.frameLength > 0 {
                // Compute RMS level for the overlay visualizer
                if let channelData = convertedBuffer.floatChannelData?[0] {
                    let count = Int(convertedBuffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<count { sum += channelData[i] * channelData[i] }
                    let rms = sqrtf(sum / Float(max(count, 1)))
                    self.currentLevel = min(rms / 0.15, 1.0)
                }

                // Accumulate Float32 samples for direct engine use
                if let channelData = convertedBuffer.floatChannelData?[0] {
                    let count = Int(convertedBuffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
                    self.writeQueue.async {
                        self.pcmSamples.append(contentsOf: samples)
                    }
                }

                self.writeQueue.async {
                    do {
                        try self.audioFile?.write(from: convertedBuffer)
                    } catch {
                        fputs("AudioRecorder write error: \(error.localizedDescription)\n", stderr)
                    }
                }
            }
        }

        try engine.start()
        audioEngine = engine
        isRecording = true
    }

    /// Write pre-roll Float32 samples to the WAV file as Int16.
    private func writePrerollToFile(_ samples: [Float], format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<samples.count {
                channelData[i] = samples[i]
            }
        }
        writeQueue.async {
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                fputs("AudioRecorder pre-roll write error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func stopRecording() -> (url: URL, samples: [Float])? {
        guard isRecording else { return nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        var samples: [Float] = []
        writeQueue.sync {
            self.audioFile = nil
            samples = self.pcmSamples
            self.pcmSamples = []
        }
        isRecording = false

        // Restart pre-roll for next recording
        startPreroll()

        guard let url = currentOutputURL else { return nil }
        return (url: url, samples: samples)
    }
}
