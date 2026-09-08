// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import XCTest
import AVFoundation
@testable import SpeakFreeLib

final class AudioBufferResamplerTests: XCTestCase {
    func testContinuousSignalAcrossDeviceRatesAndVariableBuffers() throws {
        for rate in [24_000.0, 44_100.0, 48_000.0] {
            let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let resampler = try XCTUnwrap(AudioBufferResampler(inputFormat: input, outputFormat: output))
            var offset = 0
            var samples: [Float] = []
            for index in 0..<120 {
                let length = [4096, 1024, 2048][index % 3]
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(length)))
                buffer.frameLength = AVAudioFrameCount(length)
                for i in 0..<length { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 173 * Double(offset + i) / rate)) }
                offset += length
                if let converted = resampler.convert(buffer) {
                    samples.append(contentsOf: UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
                }
            }
            let expectedCount = Double(offset) * 16_000 / rate
            // The continuous converter retains its short filter tail until more input.
            XCTAssertLessThan(abs(Double(samples.count) - expectedCount), 64, "rate \(rate)")
            // A 173Hz half-amplitude sine can move at most 0.034/sample. Repeated
            // source chunks introduce jumps at boundaries, even if duration is right.
            let maxJump = zip(samples.dropFirst(64), samples.dropFirst(65)).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(maxJump, 0.04, "rate \(rate)")
            XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.49)
        }
    }
}
