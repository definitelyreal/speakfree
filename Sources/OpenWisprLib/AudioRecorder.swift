import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private var currentOutputURL: URL?
    private let writeQueue = DispatchQueue(label: "com.openwisprmod.audiowrite")
    private var pcmSamples: [Float] = []

    /// Current RMS audio level (0.0–1.0), updated from the audio tap.
    private(set) var currentLevel: Float = 0

    // MARK: - Pre-roll circular buffer

    /// Keeps the last ~500ms of audio so speech isn't lost when fn is pressed.
    private let prerollLock = NSLock()
    private var prerollBuffer: [Float] = []
    private let prerollMaxSamples = 8000  // 500ms at 16kHz

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Start the always-on audio engine. Call once on app launch.
    /// The engine runs a single tap that operates in two modes:
    ///   - Idle: fills a 500ms pre-roll circular buffer
    ///   - Recording: writes to file + accumulates PCM samples
    func warmUp() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("AudioRecorder: converter creation failed")
            return
        }
        audioConverter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleAudioBuffer(buffer, inputFormat: inputFormat, converter: conv)
        }

        do {
            try engine.start()
            audioEngine = engine
        } catch {
            print("AudioRecorder: engine start failed: \(error.localizedDescription)")
        }
    }

    /// Single tap callback — handles both pre-roll and recording modes.
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, converter: AVAudioConverter) {
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, convertedBuffer.frameLength > 0,
              let channelData = convertedBuffer.floatChannelData?[0] else { return }

        let count = Int(convertedBuffer.frameLength)

        // RMS level for visualizer
        var sum: Float = 0
        for i in 0..<count { sum += channelData[i] * channelData[i] }
        let rms = sqrtf(sum / Float(max(count, 1)))
        self.currentLevel = min(rms / 0.15, 1.0)

        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))

        if isRecording {
            // Recording mode: write to file + accumulate samples
            writeQueue.async {
                self.pcmSamples.append(contentsOf: samples)
                do {
                    try self.audioFile?.write(from: convertedBuffer)
                } catch {
                    fputs("AudioRecorder write error: \(error.localizedDescription)\n", stderr)
                }
            }
        } else {
            // Pre-roll mode: fill circular buffer
            prerollLock.lock()
            prerollBuffer.append(contentsOf: samples)
            if prerollBuffer.count > prerollMaxSamples {
                prerollBuffer.removeFirst(prerollBuffer.count - prerollMaxSamples)
            }
            prerollLock.unlock()
        }
    }

    // MARK: - Recording

    func startRecording(to outputURL: URL) throws {
        guard !isRecording else { return }

        // Drain pre-roll — this is the audio from just before fn was pressed
        prerollLock.lock()
        let preroll = prerollBuffer
        prerollBuffer = []
        prerollLock.unlock()

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

        // Seed with pre-roll audio
        pcmSamples = preroll

        // Write pre-roll to WAV file
        if !preroll.isEmpty {
            writePrerollToFile(preroll)
        }

        // Switch to recording mode — the tap is already running
        isRecording = true

        // If engine isn't running (shouldn't happen), start it
        if audioEngine == nil {
            warmUp()
        }
    }

    /// Write pre-roll Float32 samples to the WAV file.
    private func writePrerollToFile(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
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

        // Switch back to pre-roll mode — tap keeps running
        isRecording = false

        var samples: [Float] = []
        writeQueue.sync {
            self.audioFile = nil
            samples = self.pcmSamples
            self.pcmSamples = []
        }

        guard let url = currentOutputURL else { return nil }
        return (url: url, samples: samples)
    }
}
