import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var recordingFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private var currentOutputURL: URL?
    // Serial queue protects audioFile from concurrent access between audio thread and main thread
    private let writeQueue = DispatchQueue(label: "com.openwisprmod.audiowrite")

    /// Call once at startup. Initializes the engine and pauses it immediately —
    /// mic indicator stays off but engine is ready to resume instantly on keypress.
    func warmUp() {
        do {
            try prepareEngine()
        } catch {
            print("AudioRecorder warmUp error: \(error.localizedDescription)")
        }
    }

    private func prepareEngine() throws {
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

        engine.prepare()
        try engine.start()
        engine.pause()  // Release hardware immediately — no mic indicator at rest

        audioEngine = engine
        recordingFormat = targetFormat
        converter = conv
    }

    func startRecording(to outputURL: URL) throws {
        guard !isRecording else { return }

        // Re-prepare if the engine was torn down (e.g. audio device changed)
        if audioEngine == nil {
            try prepareEngine()
        }

        guard let engine = audioEngine,
              let targetFormat = recordingFormat,
              let conv = converter else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Engine not ready"])
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

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Defensive: remove any stale tap before installing — removeTap is a no-op if none exists.
        // Prevents an NSException crash if the engine was reset (e.g. audio device change) without
        // our stopRecording() path being called.
        inputNode.removeTap(onBus: 0)

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
                self.writeQueue.sync {
                    if let err = (try? self.audioFile?.write(from: convertedBuffer)) as? Error {
                        fputs("AudioRecorder write error: \(err.localizedDescription)\n", stderr)
                    }
                }
            }
        }

        // Resume from paused state — fast, no full restart needed
        try engine.start()
        isRecording = true
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.pause()  // Release mic hardware — orange dot goes away
        writeQueue.sync { self.audioFile = nil }  // Wait for any in-flight writes to finish
        isRecording = false

        return currentOutputURL
    }
}
