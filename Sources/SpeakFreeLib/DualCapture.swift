// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import AudioToolbox
import AVFoundation
import CoreAudio
import CTryCatch
import Foundation

/// Dual-mic capture prototype (Michael, 2026-07-14 — "consolidate, don't stitch",
/// flag-gated).
///
/// When engaged: the ALWAYS-ON engine is pinned to the built-in mic (pre-roll lives
/// there, and the AirPods are released to A2DP while idle — the whole point), and a
/// SECOND stream on the Bluetooth default input is opened only for the duration of a
/// recording. The dictation that gets inserted still comes from the built-in track
/// (complete, includes pre-roll); the Bluetooth track is saved and transcribed for
/// comparison so the corpus can prove whether/when the close-field AirPods mic wins
/// before any merge logic ships.
public enum DualCapture {

    /// Pure engagement rule (unit-tested): dual capture engages only when the flag is
    /// on, the user has NOT pinned a specific mic, the system default input is
    /// Bluetooth, and this Mac has a built-in mic to carry the primary track.
    public static func shouldEngage(flagOn: Bool, pinnedUID: String?,
                                    defaultIsBluetooth: Bool, hasBuiltIn: Bool) -> Bool {
        flagOn && pinnedUID == nil && defaultIsBluetooth && hasBuiltIn
    }

    /// Word-level agreement between two transcriptions (0…1): LCS length over the
    /// longer token count, case/punctuation-insensitive. Drives the corpus verdict on
    /// whether the Bluetooth track ever beats the built-in one.
    public static func tokenAgreement(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty || !tb.isEmpty else { return 1 }
        guard !ta.isEmpty && !tb.isEmpty else { return 0 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: tb.count + 1), count: ta.count + 1)
        for i in 1...ta.count {
            for j in 1...tb.count {
                dp[i][j] = ta[i-1] == tb[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1])
            }
        }
        return Double(dp[ta.count][tb.count]) / Double(max(ta.count, tb.count))
    }

    /// Write 16 kHz mono Float32 samples as a 16-bit wav (same settings as the
    /// primary recording file).
    public static func writeWav(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        var offset = 0
        let chunk = 16_000 * 4
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(count)) else { break }
            buf.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
            }
            try file.write(from: buf)
            offset += count
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Minimal second capture stream: its own AVAudioEngine bound to a specific device,
/// accumulating 16 kHz mono Float32 samples between start() and stop(). No pre-roll,
/// no file, no crash recovery — it exists to produce a comparison track.
final class SecondaryRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Begin capturing from `device`. Returns false when the stream can't start
    /// (device vanished mid-handoff, invalid format, …) — callers just proceed
    /// single-mic; this stream is best-effort by design.
    func start(device: AudioInputDevice) -> Bool {
        stop()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let unit = inputNode.audioUnit else { return false }
        var deviceID = device.id
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return false }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let conv = AVAudioConverter(from: format, to: targetFormat) else {
            DiagnosticLogger.shared.log(
                "SecondaryRecorder: \(device.name) format not ready — skipping dual capture")
            return false
        }
        converter = conv
        samples = []

        var tapErr: NSError?
        let tapOK = CTryCatch({
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.append(buffer, converter: conv)
            }
        }, &tapErr)
        guard tapOK else {
            DiagnosticLogger.shared.log(
                "SecondaryRecorder: installTap failed — \(tapErr?.localizedDescription ?? "?")")
            return false
        }
        do {
            try engine.start()
        } catch {
            DiagnosticLogger.shared.log("SecondaryRecorder: start failed — \(error.localizedDescription)")
            return false
        }
        self.engine = engine
        DiagnosticLogger.shared.log("SecondaryRecorder: capturing from \(device.name)")
        return true
    }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convErr == nil, let data = out.floatChannelData else { return }
        let converted = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
    }

    /// Stop capturing and return whatever was collected (empty when start failed).
    @discardableResult
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        lock.lock()
        let out = samples
        samples = []
        lock.unlock()
        return out
    }
}
