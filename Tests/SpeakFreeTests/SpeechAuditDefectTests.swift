// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
import XCTest
@testable import SpeakFreeLib

final class SpeechAuditDefectTests: XCTestCase {
    private let audioURL = URL(fileURLWithPath: "/tmp/speech-audit-defect.wav")

    func testZeroPayloadIsCaptureFailureInsteadOfAccidentalTap() {
        let result = FinalizePipeline.resolveGateSamples(
            memorySamples: [], readWav: { [] })

        XCTAssertEqual(result.failure, .captureFailed)
        XCTAssertFalse(result.usedWavFallback)
    }

    func testWavPayloadStillRescuesEmptyMemoryCapture() {
        let wavSamples = [Float](repeating: 0.1, count: FinalizePipeline.minSamples)
        let result = FinalizePipeline.resolveGateSamples(
            memorySamples: [], readWav: { wavSamples })

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.samples, wavSamples)
        XCTAssertTrue(result.usedWavFallback)
    }

    func testFirstBufferGuardOnlyRecoversCurrentActiveTake() {
        XCTAssertTrue(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: true, scheduledGeneration: 4, currentGeneration: 4,
            firstBufferArrived: false))
        XCTAssertFalse(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: true, scheduledGeneration: 4, currentGeneration: 4,
            firstBufferArrived: true))
        XCTAssertFalse(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: false, scheduledGeneration: 4, currentGeneration: 4,
            firstBufferArrived: false))
        XCTAssertFalse(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: true, scheduledGeneration: 4, currentGeneration: 5,
            firstBufferArrived: false))
    }

    func testRealShortYeahSurvivesHallucinationFilter() async throws {
        let engine = FakeEngine(cannedTranscript: "Yeah.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = speechSamples(seconds: 0.8)

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "Yeah.")
    }

    func testRealShortSoSurvivesHallucinationFilter() async throws {
        let engine = FakeEngine(cannedTranscript: "So")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = speechSamples(seconds: 0.7)

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "So")
    }

    func testEmptyRoomFillerRemainsFiltered() async throws {
        let engine = FakeEngine(cannedTranscript: "Yeah.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = [Float](repeating: 0.001, count: 16_000 * 6)

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "")
    }

    func testLongTakeWithSomeSpeechSparesBareFiller() async throws {
        // Long take, one short VOICED burst (a real word), energy not sustained across ≥3 windows:
        // spared via the duration branch, and only because the burst is voiced.
        let engine = FakeEngine(cannedTranscript: "Okay.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        var samples = [Float](repeating: 0.001, count: 16_000 * 3)
        let burst = sineBurst(seconds: 0.03, freqHz: 150, amp: 0.11) // ~1 window, RMS ~0.078
        samples.replaceSubrange(20_000..<20_000 + burst.count, with: burst)

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "Okay.")
    }

    // MARK: - Voicedness + quiet-room-SNR spare (2026-08-12 hallucination-filter upgrade)

    /// Quiet office, a softly spoken real word whose peak sits BELOW the sustained bar (0.04) and
    /// whose take is SHORT (<2.5 s): survives only through the quiet-room SNR spare + voicedness.
    func testQuietRoomSoftWordSparedViaSNR() async throws {
        let engine = FakeEngine(cannedTranscript: "Yeah.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        var samples = [Float](repeating: 0.001, count: Int(1.5 * 16_000)) // quiet floor, <2.5 s
        let burst = sineBurst(seconds: 0.2, freqHz: 150, amp: 0.0424) // RMS ~0.03: energetic, sub-0.04
        samples.replaceSubrange(8_000..<8_000 + burst.count, with: burst)

        let evidence = Transcriber.audioEvidence(in: samples)
        XCTAssertFalse(evidence.hasSustainedSpeechEnergy, "peak must sit below the sustained bar")
        XCTAssertLessThan(evidence.durationSeconds, 2.5)
        XCTAssertTrue(evidence.hasQuietRoomSNR, "peak far above the quiet floor")
        XCTAssertTrue(evidence.hasVoicedSpeech)

        let result = try await transcriber.transcribe(audioURL: audioURL, samples: samples)
        XCTAssertEqual(result, "Yeah.")
    }

    /// A broadband click/tap train: clears the energy AND sustained bars, but has no pitch — the
    /// voicedness gate keeps the hallucinated filler deleted.
    func testBroadbandClickNotSpared() async throws {
        let engine = FakeEngine(cannedTranscript: "Okay.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = clickTrain(seconds: 1.0)

        let evidence = Transcriber.audioEvidence(in: samples)
        XCTAssertTrue(evidence.hasSustainedSpeechEnergy, "click clears the energy bar")
        XCTAssertFalse(evidence.hasVoicedSpeech, "a transient has no pitch")

        let result = try await transcriber.transcribe(audioURL: audioURL, samples: samples)
        XCTAssertEqual(result, "")
    }

    /// A white-noise burst: energetic and sustained, but pitchless — filtered by voicedness.
    func testWhiteNoiseBurstNotSpared() async throws {
        let engine = FakeEngine(cannedTranscript: "So.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = whiteNoise(count: 16_000, amp: 0.12) // RMS ~0.069: energetic, sustained

        let evidence = Transcriber.audioEvidence(in: samples)
        XCTAssertTrue(evidence.hasSustainedSpeechEnergy)
        XCTAssertFalse(evidence.hasVoicedSpeech)

        let result = try await transcriber.transcribe(audioURL: audioURL, samples: samples)
        XCTAssertEqual(result, "")
    }

    /// A pure 150 Hz voiced burst is spared (positive control for the voicedness path).
    func testVoicedBurstSpared() async throws {
        let engine = FakeEngine(cannedTranscript: "Yeah.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = sineBurst(seconds: 0.8, freqHz: 150, amp: 0.08) // RMS ~0.057

        let result = try await transcriber.transcribe(audioURL: audioURL, samples: samples)
        XCTAssertEqual(result, "Yeah.")
    }

    func testTrueSilenceFiltered() async throws {
        let engine = FakeEngine(cannedTranscript: "Hmm.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = [Float](repeating: 0.0, count: 16_000 * 2)

        let result = try await transcriber.transcribe(audioURL: audioURL, samples: samples)
        XCTAssertEqual(result, "")
    }

    // MARK: - Pure-function unit tests (mutation-test targets)

    func testNormalizedPitchAutocorrelationDetectsPitchButNotNoiseOrClick() {
        let sine = sineBurst(seconds: 0.03, freqHz: 150, amp: 0.1)[0..<480]
        let noise = whiteNoise(count: 480, amp: 0.1)[0..<480]
        var click = [Float](repeating: 0, count: 480)
        click[240] = 0.9; click[241] = -0.9; click[242] = 0.9
        let dc = [Float](repeating: 0.08, count: 480)[0..<480]

        XCTAssertGreaterThan(Transcriber.normalizedPitchAutocorrelation(sine), 0.9)
        XCTAssertLessThan(Transcriber.normalizedPitchAutocorrelation(click[0..<480]), 0.5)

        // Combined gate (NCC + zero-crossing band): only the voiced sine passes.
        XCTAssertTrue(Transcriber.isVoicedWindow(sine))
        XCTAssertFalse(Transcriber.isVoicedWindow(noise), "broadband noise: zero-crossings too high")
        XCTAssertFalse(Transcriber.isVoicedWindow(click[0..<480]), "transient: no pitch")
        XCTAssertFalse(Transcriber.isVoicedWindow(dc), "DC/constant block: zero-crossings too low")

        // Zero-crossing discriminator directly.
        XCTAssertLessThan(Transcriber.zeroCrossingCount(dc), 2)
        XCTAssertGreaterThan(Transcriber.zeroCrossingCount(noise), 120)
    }

    func testNoiseFloorPercentileIsRobustToSpeechFraction() {
        // 8 quiet windows + 2 loud: the 20th percentile lands in the quiet floor, not the speech.
        let values: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.06, 0.06]
        XCTAssertEqual(Transcriber.noiseFloorRMS(from: values), 0.001, accuracy: 1e-6)
        XCTAssertEqual(Transcriber.noiseFloorRMS(from: []), 0.0)
    }

    func testElectronRejectsLiveAXButKeepsRememberedTailEligible() {
        XCTAssertNil(AppDelegate.liveCursorContext(
            "untrusted Electron AX text", isElectronClass: true))
        XCTAssertEqual(AppDelegate.liveCursorContext(
            "native editor text", isElectronClass: false), "native editor text")

        let remembered = FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: "Remembered tail ",
            lastInsertedBundleID: "com.microsoft.VSCode",
            lastInsertedAt: Date(),
            frontmostBundleID: "com.microsoft.VSCode",
            now: Date())
        XCTAssertEqual(remembered, "Remembered tail ")
    }

    func testLegacyNilPunctuationDisplaysAutomaticOnlyEverywhere() throws {
        var config = Config.defaultConfig
        config.spokenPunctuation = nil

        XCTAssertEqual(SettingsViewModel(config: config).punctuationMode, .off)
        let facts = HelpFacts.live(config: config)
        XCTAssertEqual(facts.punctuationMode, .off)
        XCTAssertEqual(facts.punctuationDisplayName, "Automatic Only")
    }

    private func speechSamples(seconds: Double) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { index in
            sin(Float(index) * 0.08) * 0.08
        }
    }

    /// Voiced tone: a pure sine at `freqHz` (a real fundamental → passes the voicedness gate).
    private func sineBurst(seconds: Double, freqHz: Double, amp: Float) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { i in
            amp * sin(Float(2.0 * Double.pi * freqHz * Double(i) / 16_000.0))
        }
    }

    /// Deterministic white noise in [-amp, amp] (broadband, no pitch → fails the voicedness gate).
    private func whiteNoise(count: Int, amp: Float, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24) // [0, 1)
            return (unit * 2 - 1) * amp
        }
    }

    /// A broadband click/tap train: one sharp 3-sample transient per 480-sample window (energetic,
    /// but no harmonic pitch in the 85–255 Hz band → fails the voicedness gate).
    private func clickTrain(seconds: Double, spikeAmp: Float = 0.9) -> [Float] {
        let count = Int(seconds * 16_000)
        var samples = [Float](repeating: 0, count: count)
        var i = 240
        while i + 2 < count {
            samples[i] = spikeAmp
            samples[i + 1] = -spikeAmp
            samples[i + 2] = spikeAmp
            i += 480
        }
        return samples
    }
}
