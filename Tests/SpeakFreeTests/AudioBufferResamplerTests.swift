// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-suggestion:unverified · session:unknown · 2026-10-02
import XCTest
import AVFoundation
@testable import SpeakFreeLib

final class AudioBufferResamplerTests: XCTestCase {
    func testContinuousSignalAcrossDeviceRatesAndVariableBuffers() throws {
        for rate in [16_000.0, 24_000.0, 44_100.0, 48_000.0] {
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
                let time = Double(offset) / rate
                offset += length
                if case .output(let converted, _) = resampler.convert(buffer, at: time) {
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
    func testIrregularNativeBuffersPreserveFirstInputTimeAndFrameCount() throws {
        for rate in [16_000.0, 24_000.0, 44_100.0, 48_000.0] {
            let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let resampler = try XCTUnwrap(AudioBufferResampler(inputFormat: input, outputFormat: output))
            var inputFrames = 0, outputFrames = 0, pending = 0
            let origin = 100.0
            for index in 0..<1000 {
                let length = [1, 2, 0, 7, 4096, 17, 1024, 3, 2048, 61][index % 10]
                let buffer = try makeBuffer(format: input, length: length)
                for i in 0..<length { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 173 * Double(inputFrames + i) / rate)) }
                let start = origin + Double(inputFrames) / rate
                inputFrames += length
                switch resampler.convert(buffer, at: start) {
                case .pending: if length > 0 { pending += 1 }
                case .failure(let reason): XCTFail("rate \(rate): \(reason)")
                case .output(let converted, let time):
                    XCTAssertEqual(time, origin + Double(outputFrames) / 16_000, accuracy: 1e-9)
                    outputFrames += Int(converted.frameLength)
                }
            }
            XCTAssertLessThan(abs(Double(outputFrames) - Double(inputFrames) * 16_000 / rate), 64)
            if rate != 16_000 { XCTAssertGreaterThan(pending, 0, "Exercise native converter buffering") }
        }
    }

    func testPendingBuffersAnchorAtFirstConsumedInputAndDoNotDuplicateSupply() throws {
        let format = try monoFormat()
        var calls = 0
        let converter = AudioBufferResampler(inputFormat: format, outputFormat: format) { output, supply in
            calls += 1
            var status = AVAudioConverterInputStatus.noDataNow
            XCTAssertNotNil(supply(4, &status))
            XCTAssertEqual(status, .haveData)
            XCTAssertNil(supply(4, &status))
            XCTAssertEqual(status, .noDataNow)
            if calls == 2 {
                output.frameLength = 4
                for i in 0..<4 { output.floatChannelData![0][i] = Float(i) / 10 }
            }
            return (.inputRanDry, nil)
        }
        let buffer = try makeBuffer(format: format, length: 4)
        assertPending(converter.convert(buffer, at: 100))
        guard case .output(let output, let time) = converter.convert(buffer, at: 100.00025) else {
            return XCTFail("Partial output from inputRanDry must be delivered")
        }
        XCTAssertEqual(time, 100)
        XCTAssertEqual(output.frameLength, 4)
    }

    func testEmptyInputDoesNotAnchorOrInvokeConverter() throws {
        let format = try monoFormat()
        var calls = 0
        let converter = AudioBufferResampler(inputFormat: format, outputFormat: format) { output, supply in
            calls += 1
            var status = AVAudioConverterInputStatus.noDataNow
            _ = supply(1, &status)
            output.frameLength = 1; output.floatChannelData![0][0] = 0.1
            return (.haveData, nil)
        }
        assertPending(converter.convert(try makeBuffer(format: format, length: 0), at: 50))
        XCTAssertEqual(calls, 0)
        guard case .output(_, let time) = converter.convert(try makeBuffer(format: format, length: 1), at: 100) else {
            return XCTFail("Expected output")
        }
        XCTAssertEqual(time, 100)
    }

    func testConverterErrorsWithFramesAreTerminalAndCannotCompressLaterAudio() throws {
        let format = try monoFormat()
        for (status, error) in [(AVAudioConverterOutputStatus.error, nil),
                                (.haveData, NSError(domain: "test.converter", code: -7)),
                                (.error, NSError(domain: "test.converter", code: -8))] as [(AVAudioConverterOutputStatus, NSError?)] {
            var calls = 0
            let converter = AudioBufferResampler(inputFormat: format, outputFormat: format) { output, supply in
                calls += 1
                var inputStatus = AVAudioConverterInputStatus.noDataNow
                _ = supply(4, &inputStatus)
                output.frameLength = 4
                for i in 0..<4 { output.floatChannelData![0][i] = 0.1 }
                return calls == 2 ? (status, error) : (.haveData, nil)
            }
            let buffer = try makeBuffer(format: format, length: 4)
            guard case .output = converter.convert(buffer, at: 100) else { return XCTFail("First output missing") }
            let expected = AudioBufferResampler.Failure.converter(domain: error?.domain, code: error?.code)
            assertFailure(converter.convert(buffer, at: 100.00025), expected)
            assertFailure(converter.convert(buffer, at: 100.0005), expected)
            XCTAssertEqual(calls, 2, "Do not resume on a clock that omits the failed input")
        }
    }

    func testNonfiniteSamplesOnAnyInputChannelAreRejectedBeforeConversion() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: interleaved))
            for sample in [Float.nan, .infinity, -.infinity] {
                var calls = 0
                let converter = AudioBufferResampler(inputFormat: format, outputFormat: try monoFormat()) { _, _ in
                    calls += 1; return (.inputRanDry, nil)
                }
                let buffer = try makeBuffer(format: format, length: 4)
                buffer.floatChannelData![1][3 * buffer.stride] = sample
                assertFailure(converter.convert(buffer, at: 100), .nonfiniteInput)
                XCTAssertEqual(calls, 0)
            }
        }
    }

    func testFloat64InputValidationCoversBothLayoutsAndFiniteControl() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 24_000,
                                                   channels: 2, interleaved: interleaved))
            for sample in [Double.nan, .infinity, -.infinity, 0.1] {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
                buffer.frameLength = 4
                let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for audio in audioBuffers {
                    let values = try XCTUnwrap(audio.mData).assumingMemoryBound(to: Double.self)
                    for i in 0..<(4 * Int(audio.mNumberChannels)) { values[i] = 0.1 }
                }
                // Last frame of channel two, in either one interleaved buffer or the
                // second planar buffer. This must be read as Float64, not Float32.
                let channelTwo = audioBuffers[interleaved ? 0 : 1].mData!.assumingMemoryBound(to: Double.self)
                channelTwo[interleaved ? 7 : 3] = sample
                var calls = 0
                let converter = AudioBufferResampler(inputFormat: format, outputFormat: try monoFormat()) { output, supply in
                    calls += 1
                    var status = AVAudioConverterInputStatus.noDataNow
                    _ = supply(4, &status)
                    output.frameLength = 1; output.floatChannelData![0][0] = 0.1
                    return (.inputRanDry, nil)
                }
                let result = converter.convert(buffer, at: 100)
                if sample.isFinite {
                    guard case .output = result else { return XCTFail("Finite Float64 control was rejected") }
                    XCTAssertEqual(calls, 1)
                } else {
                    assertFailure(result, .nonfiniteInput)
                    XCTAssertEqual(calls, 0)
                }
            }
        }
    }

    func testNonfiniteConvertedSamplesAreTerminal() throws {
        let format = try monoFormat()
        for sample in [Float.nan, .infinity, -.infinity] {
            let converter = AudioBufferResampler(inputFormat: format, outputFormat: format) { output, supply in
                var status = AVAudioConverterInputStatus.noDataNow
                _ = supply(1, &status)
                output.frameLength = 1; output.floatChannelData![0][0] = sample
                return (.inputRanDry, nil)
            }
            assertFailure(converter.convert(try makeBuffer(format: format, length: 1), at: 100), .invalidOutput)
        }
    }

    func testChangedFormatAndInvalidTimestampAreRejected() throws {
        let format = try monoFormat()
        let changed = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        for (input, time) in [(try makeBuffer(format: changed, length: 1), 100.0),
                              (try makeBuffer(format: format, length: 1), Double.nan)] {
            let converter = AudioBufferResampler(inputFormat: format, outputFormat: format) { _, _ in
                XCTFail("Invalid input must not reach converter"); return (.error, nil)
            }
            assertFailure(converter.convert(input, at: time), .invalidInput)
        }
    }

    func testUnhandledUnconsumedInputAndUnexpectedEndFailExplicitly() throws {
        let format = try monoFormat()
        let buffer = try makeBuffer(format: format, length: 1)
        for status in [AVAudioConverterOutputStatus.inputRanDry, .haveData] {
            let unconsumed = AudioBufferResampler(inputFormat: format, outputFormat: format) { output, _ in
                if status == .haveData { output.frameLength = 1; output.floatChannelData![0][0] = 0.1 }
                return (status, nil)
            }
            assertFailure(unconsumed.convert(buffer, at: 100), .inputNotConsumed)
        }
        let ended = AudioBufferResampler(inputFormat: format, outputFormat: format) { _, supply in
            var status = AVAudioConverterInputStatus.noDataNow
            _ = supply(1, &status)
            return (.endOfStream, nil)
        }
        assertFailure(ended.convert(buffer, at: 100), .unexpectedEnd)
    }

    func testFiniteSilentAudioRemainsValidOutput() throws {
        let format = try monoFormat()
        let converter = try XCTUnwrap(AudioBufferResampler(inputFormat: format, outputFormat: format))
        let buffer = try makeBuffer(format: format, length: 1024)
        for i in 0..<1024 { buffer.floatChannelData![0][i] = 0 }
        guard case .output(let output, _) = converter.convert(buffer, at: 100) else { return XCTFail("Silence is finite audio") }
        XCTAssertEqual(output.frameLength, 1024)
        XCTAssertTrue(UnsafeBufferPointer(start: output.floatChannelData![0], count: 1024).allSatisfy { $0 == 0 })
    }

    private func monoFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    }

    private func makeBuffer(format: AVAudioFormat, length: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(length, 1))))
        buffer.frameLength = AVAudioFrameCount(length)
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<length { buffer.floatChannelData![channel][i * buffer.stride] = 0.1 }
        }
        return buffer
    }

    private func assertPending(_ result: AudioBufferResampler.Conversion, file: StaticString = #filePath, line: UInt = #line) {
        guard case .pending = result else { return XCTFail("Expected ordinary pending conversion", file: file, line: line) }
    }

    private func assertFailure(_ result: AudioBufferResampler.Conversion, _ reason: AudioBufferResampler.Failure,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let actual) = result else { return XCTFail("Expected conversion failure \(reason)", file: file, line: line) }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }
}
