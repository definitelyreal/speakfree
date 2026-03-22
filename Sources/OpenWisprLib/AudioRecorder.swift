import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private var currentOutputURL: URL?
    // Serial queue protects audioFile from concurrent access between audio thread and main thread
    private let writeQueue = DispatchQueue(label: "com.openwisprmod.audiowrite")

    /// No-op — engine is created fresh per recording session to avoid stale-tap crashes.
    func warmUp() {}

    func startRecording(to outputURL: URL) throws {
        guard !isRecording else { return }

        // Always create a fresh engine — avoids stale-tap NSException crashes
        // (seen on macOS 26 when reusing a paused engine across sessions)
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

    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        writeQueue.sync { self.audioFile = nil }  // Wait for any in-flight writes to finish
        isRecording = false

        return currentOutputURL
    }
}
