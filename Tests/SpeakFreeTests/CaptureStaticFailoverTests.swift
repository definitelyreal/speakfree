// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-25
//
// In one observed session, Stay on held AirPods open while they delivered static. Parakeet
// returned nothing and the Whisper rescue typed invented sentences. These tests pin the
// fixes with synthetic audio only (no hardware, no real config, no recordings folder):
// the format check, the static judge, the in-take switch to the Mac's microphone with its
// audio replacing the headset stretch, the notice, and the "static" status line.
import XCTest
@testable import SpeakFreeLib

private final class ScriptedCapture: DeviceCapturing {
    var device: AudioInputDevice?
    var deliver: ((CapturePacket) -> Void)?
    var fail: ((String) -> Void)?
    var stopped = false
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void, failure: @escaping (String) -> Void) {
        self.device = device; deliver = packet; fail = failure
    }
    func stop() { stopped = true }
}

/// Deterministic test signals, 16 kHz.
enum SyntheticAudio {
    /// Flat white noise at `rms`: the shape of the broken AirPods stream (little energy under
    /// 1 kHz, about 8,000 crossings a second, no rise and fall).
    static func staticNoise(seconds: Double, rms: Float = 0.02, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        let scale = rms * Float(3.0).squareRoot() // uniform(-1, 1) has RMS 1/sqrt(3)
        return (0..<Int(seconds * 16_000)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
            return unit * scale
        }
    }

    /// A voiced buzz at 110 Hz (harmonics to 880 Hz) that rises and falls five times a second
    /// with short gaps: energy under 1 kHz, few crossings, a clear envelope.
    static func voice(seconds: Double, peak: Float = 0.1, offset: Double = 0) -> [Float] {
        (0..<Int(seconds * 16_000)).map { i in
            let t = Double(i) / 16_000 + offset
            var tone = 0.0
            for k in 1...8 { tone += sin(2 * .pi * 110 * Double(k) * t) / Double(k) }
            // Never exactly zero between syllables: a real microphone is never digitally silent.
            let envelope = pow(max(0, sin(2 * .pi * 2.5 * t)), 2) + 0.01
            return Float(tone * envelope / 2.0) * peak
        }
    }

    /// A quiet, low-pitched fan: steady and flat, no speech envelope.
    static func fan(seconds: Double, rms: Float = 0.006) -> [Float] {
        var previous: Float = 0
        return staticNoise(seconds: seconds, rms: rms * 8, seed: 7).map { x in
            previous = previous * 0.97 + x * 0.03; return previous
        }
    }
}

final class CaptureStaticJudgeTests: XCTestCase {
    func testStaticIsStaticAndVoiceIsNot() {
        XCTAssertTrue(CaptureStaticJudge.isStatic(samples: SyntheticAudio.staticNoise(seconds: 3)))
        XCTAssertFalse(CaptureStaticJudge.isStatic(samples: SyntheticAudio.voice(seconds: 3)))
        XCTAssertFalse(CaptureStaticJudge.isStatic(samples: SyntheticAudio.fan(seconds: 3)), "flat but low: a fan is not static")
        XCTAssertFalse(CaptureStaticJudge.isStatic(samples: SyntheticAudio.staticNoise(seconds: 3, rms: 0.003)), "too quiet to judge")
        XCTAssertTrue(CaptureStaticJudge.isStatic(samples: SyntheticAudio.staticNoise(seconds: 1.2)), "a whole take needs one second")
        XCTAssertFalse(CaptureStaticJudge.isStatic(samples: SyntheticAudio.staticNoise(seconds: 0.8)))
        XCTAssertFalse(CaptureStaticJudge.isStatic(CaptureStaticJudge.windows(of: SyntheticAudio.staticNoise(seconds: 1.5))),
                       "inside a take the judge waits for two seconds")
    }

    func testStaticThatComesAndGoesIsNotJudgedStatic() {
        // Hiss between sentences on a working headset: loud stretches alternate with quiet ones.
        let burst = SyntheticAudio.staticNoise(seconds: 0.5) + [Float](repeating: 0.0005, count: 8_000)
        XCTAssertFalse(CaptureStaticJudge.isStatic(samples: burst + burst + burst))
    }

    func testSpeechIsFoundOnlyWhereTheMacHeardAVoice() {
        let voice = CaptureStaticJudge.windows(of: SyntheticAudio.voice(seconds: 2))
        XCTAssertTrue(CaptureStaticJudge.isSpeech(voice, floorRMS: CaptureStaticJudge.quietLevel(voice)))
        let fan = CaptureStaticJudge.windows(of: SyntheticAudio.fan(seconds: 2))
        XCTAssertFalse(CaptureStaticJudge.isSpeech(fan, floorRMS: CaptureStaticJudge.quietLevel(fan)))
        let hiss = CaptureStaticJudge.windows(of: SyntheticAudio.staticNoise(seconds: 2, rms: 0.02))
        XCTAssertFalse(CaptureStaticJudge.isSpeech(hiss, floorRMS: CaptureStaticJudge.quietLevel(hiss)))
        XCTAssertFalse(CaptureStaticJudge.isSpeech([], floorRMS: 0))
    }

    func testWindowsDoNotDependOnPacketSize() {
        let audio = SyntheticAudio.voice(seconds: 1) + SyntheticAudio.staticNoise(seconds: 1)
        var whole = CaptureWindowMeter()
        let a = whole.add(audio, start: 10)
        var pieces = CaptureWindowMeter()
        var b: [CaptureWindowStats] = []
        var i = 0
        while i < audio.count {
            let n = min(333, audio.count - i)
            b += pieces.add(Array(audio[i..<i + n]), start: 10 + Double(i) / 16_000)
            i += n
        }
        XCTAssertEqual(a.count, 20)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.start, y.start, accuracy: 1e-9)
            XCTAssertEqual(x.rms, y.rms, accuracy: 1e-6)
            XCTAssertEqual(x.lowFraction, y.lowFraction, accuracy: 1e-5)
        }
    }

    /// Real takes, when a folder of them is supplied (never in CI, never from the live config):
    /// STATIC_JUDGE_FIXTURES=<dir> with files named static-*.wav and good-*.wav.
    func testRecordedFixturesWhenSupplied() throws {
        guard let dir = ProcessInfo.processInfo.environment["STATIC_JUDGE_FIXTURES"] else {
            throw XCTSkip("STATIC_JUDGE_FIXTURES not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".wav") }.sorted()
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let samples = try ProcessCommand.loadSamples(from: URL(fileURLWithPath: dir).appendingPathComponent(file))
            let judged = CaptureStaticJudge.isStatic(samples: samples)
            print("fixture \(file): static=\(judged) \(CaptureStaticJudge.describe(CaptureStaticJudge.windows(of: samples)))")
            if file.hasPrefix("static-") { XCTAssertTrue(judged, file) }
            if file.hasPrefix("good-") { XCTAssertFalse(judged, file) }
        }
    }
}

final class CaptureFormatCheckTests: XCTestCase {
    typealias Rates = CaptureFormatCheck.LiveRates

    func testTapMustMatchTheLiveInputStream() {
        // The 2026-09-25 open: tap labelled 48 kHz while the headset microphone ran at 24 kHz.
        XCTAssertNotEqual(CaptureFormatCheck.verdict(tapRate: 48_000, tapChannels: 1, live: Rates(nominal: 48_000, stream: 24_000),
                                                     deviceChannels: 1, isBluetooth: true), .verified)
        XCTAssertNotEqual(CaptureFormatCheck.verdict(tapRate: 48_000, tapChannels: 1, live: Rates(nominal: 24_000, stream: 24_000),
                                                     deviceChannels: 1, isBluetooth: true), .verified)
        // A headset whose nominal rate describes its output side but whose microphone matches.
        XCTAssertEqual(CaptureFormatCheck.verdict(tapRate: 24_000, tapChannels: 1, live: Rates(nominal: 48_000, stream: 24_000),
                                                  deviceChannels: 1, isBluetooth: true), .verified)
        XCTAssertEqual(CaptureFormatCheck.verdict(tapRate: 48_000, tapChannels: 1, live: Rates(nominal: 48_000, stream: 48_000),
                                                  deviceChannels: 1, isBluetooth: false), .verified)
        XCTAssertNotEqual(CaptureFormatCheck.verdict(tapRate: 44_100, tapChannels: 1, live: Rates(nominal: 48_000, stream: 48_000),
                                                     deviceChannels: 1, isBluetooth: false), .verified)
    }

    func testUnreadableStreamFallsBackToTheNominalRule() {
        XCTAssertNotEqual(CaptureFormatCheck.verdict(tapRate: 48_000, tapChannels: 1, live: Rates(nominal: 24_000, stream: 0),
                                                     deviceChannels: 1, isBluetooth: true), .verified)
        XCTAssertEqual(CaptureFormatCheck.verdict(tapRate: 24_000, tapChannels: 1, live: Rates(nominal: 48_000, stream: 0),
                                                  deviceChannels: 1, isBluetooth: true), .verified)
        XCTAssertNotEqual(CaptureFormatCheck.verdict(tapRate: 48_000, tapChannels: 2, live: Rates(nominal: 48_000, stream: 48_000),
                                                     deviceChannels: 1, isBluetooth: false), .verified)
        XCTAssertNotEqual(CaptureFormatCheck.verdict(tapRate: 0, tapChannels: 1, live: Rates(nominal: 48_000, stream: 48_000),
                                                     deviceChannels: 1, isBluetooth: false), .verified)
    }

    func testMismatchNamesAllThreeRates() {
        guard case .mismatch(let why) = CaptureFormatCheck.verdict(
            tapRate: 48_000, tapChannels: 1, live: Rates(nominal: 48_000, stream: 24_000), deviceChannels: 1, isBluetooth: true)
        else { return XCTFail("expected a mismatch") }
        XCTAssertEqual(why, "tap 48000 Hz; input stream 24000 Hz; device 48000 Hz")
    }
}

final class CaptureStaticFailoverTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isBuiltIn: true, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
    private let airPods = AudioInputDevice(id: 2, uid: "airpods", name: "Jamie’s AirPods Pro", isBuiltIn: false, isBluetooth: true, nominalSampleRate: 24_000, inputChannels: 1)

    /// A router with Stay on AirPods, whose take buffer behaves like AudioRecorder's.
    private final class Harness {
        var sessions: [ScriptedCapture] = []
        var recording = false
        var take: [Float] = []
        var sources: [String] = []
        var events: [CaptureFallback] = []
        var replacements: [(index: Int, count: Int, source: String)] = []
        var router: MicrophoneCaptureCoordinator!
        var clock = 0.0
    }

    private func harness(stayOn: Bool = true) -> Harness {
        let h = Harness()
        h.router = MicrophoneCaptureCoordinator(factory: { let s = ScriptedCapture(); h.sessions.append(s); return s },
            samples: { samples, source in
                if h.recording { h.take += samples; h.sources.append("\(source.prefix(3)):\(samples.count)") }
            },
            status: { _ in },
            replace: { index, samples, source in
                h.replacements.append((index, samples.count, source))
                h.take = Array(h.take.prefix(index)) + samples
            }, refresh: {}, now: { h.clock })
        h.router.onFallback = { h.events.append($0) }
        h.router.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: stayOn ? nil : airPods.uid,
                           prelisten: true, stayOn: stayOn ? airPods.uid : nil)
        h.router.start(); h.router.queue.sync {}
        return h
    }

    /// Feeds both microphones in 100 ms packets from `from` for `seconds`.
    private func feed(_ h: Harness, from: Double, seconds: Double,
                      base: (Double) -> [Float], headset: ((Double) -> [Float])?) {
        var t = from
        while t < from + seconds - 1e-9 {
            h.sessions[0].deliver?(CapturePacket(start: t, samples: base(t)))
            if let headset, let session = h.sessions.last(where: { $0.device?.uid == airPods.uid && !$0.stopped }) {
                session.deliver?(CapturePacket(start: t, samples: headset(t)))
            }
            h.router.queue.sync {}
            t += 0.1
        }
    }

    private func voice(_ t: Double) -> [Float] { SyntheticAudio.voice(seconds: 0.1, offset: t) }
    private func hiss(_ t: Double) -> [Float] { SyntheticAudio.staticNoise(seconds: 0.1, seed: UInt64((t * 10).rounded() + 100)) }
    private func quiet(_ t: Double) -> [Float] { [Float](repeating: 0.0004, count: 1_600) }

    func testReplacementAfterCaptureGapUsesRecordedSampleIndex() {
        let h = harness()
        let tagged: (Double) -> [Float] = { t in Array(repeating: 0.2 + Float(t) * 0.005, count: 1600) }
        feed(h, from: 0, seconds: 1, base: quiet, headset: tagged)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        var expected: [Float] = []
        // Both streams omit [2,3). The take therefore contains five seconds, not six.
        for step in Array(10..<20) + Array(30..<70) {
            let t = Double(step) / 10
            let base = voice(t), headset = step < 40 ? tagged(t) : hiss(t)
            expected += step < 40 ? headset : base
            h.sessions[0].deliver?(CapturePacket(start: t, samples: base))
            if !h.sessions[1].stopped { h.sessions[1].deliver?(CapturePacket(start: t, samples: headset)) }
            h.router.queue.sync {}
        }
        h.router.queue.sync { h.router.flush() }
        XCTAssertEqual(h.replacements.first?.index, 32000, "host time 4 is take sample 32000 after the missing second")
        XCTAssertEqual(h.take.count, expected.count, "replacement must not retain or append overlapping static")
        XCTAssertTrue(h.take == expected, "keep both tagged pre-static stretches and the exact base replacement")
        h.router.stop(); h.router.queue.sync {}
    }

    func testStaticEvidenceAndReplacementOriginDoNotCrossHeadsetIdentities() {
        // Exercise both a different UID and a reopened session of the same UID.
        for sameUID in [false, true] {
            let h = harness()
            feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
            h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
            for step in 10..<29 {
                let t = Double(step) / 10
                h.sessions[1].deliver?(CapturePacket(start: t, samples: hiss(t)))
            }
            h.router.queue.sync {}
            let oldAudio = h.take
            let next = sameUID ? airPods : AudioInputDevice(id: 3, uid: "second-headset", name: "Second headset",
                isBuiltIn: false, isBluetooth: true, nominalSampleRate: 24000, inputChannels: 1)
            if sameUID {
                h.sessions[1].fail?("synthetic session restart")
                h.router.queue.sync { h.clock = 1 }
            }
            h.router.configure(devices: [builtIn, next], systemDefault: builtIn, pin: nil,
                               prelisten: true, stayOn: next.uid)
            h.router.queue.sync {}
            let newSession = h.sessions.last!
            newSession.deliver?(CapturePacket(start: 2.9, samples: voice(2.9)))
            // Corroboration for the old headset arrives only after its identity is retired.
            for step in 10..<30 {
                let t = Double(step) / 10
                h.sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
            }
            h.router.queue.sync {}
            XCTAssertFalse(newSession.stopped, "a new headset/session must not inherit the old one's 19 static windows")
            XCTAssertFalse(h.events.contains { $0.reason == .staticNoise })
            XCTAssertTrue(h.replacements.isEmpty)
            // Now this new source itself delivers enough static to justify a replacement.
            for step in 30..<60 {
                let t = Double(step) / 10
                h.sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
                if !newSession.stopped { newSession.deliver?(CapturePacket(start: t, samples: hiss(t))) }
                h.router.queue.sync {}
            }
            XCTAssertEqual(h.replacements.first?.index, oldAudio.count,
                           "replacement must begin at the new source, not erase the previous headset")
            XCTAssertTrue(Array(h.take.prefix(oldAudio.count)) == oldAudio)
            XCTAssertEqual(h.events.filter { $0.reason == .staticNoise }.map(\.uid), [next.uid])
            h.router.stop(); h.router.queue.sync {}
        }
    }

    func testNewHeadsetReplacementDoesNotErasePreviousHeadsetInPreroll() {
        let h = harness()
        let tagged: (Double) -> [Float] = { _ in Array(repeating: 0.3, count: 1600) }
        feed(h, from: 0, seconds: 1, base: quiet, headset: tagged)
        let next = AudioInputDevice(id: 3, uid: "second-headset", name: "Second headset", isBuiltIn: false,
                                    isBluetooth: true, nominalSampleRate: 24000, inputChannels: 1)
        h.router.configure(devices: [builtIn, next], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: next.uid)
        h.router.queue.sync {}
        let session = h.sessions.last!
        // A remains in the first 0.3 s of pre-roll; B has only supplied its final 0.2 s.
        for step in 10..<12 {
            let t = Double(step) / 10
            session.deliver?(CapturePacket(start: t, samples: hiss(t)))
            h.sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
        }
        h.router.queue.sync {
            h.take = Array(repeating: 0.3, count: 4800) + hiss(1) + hiss(1.1)
            h.recording = true
            h.router.setRecording(true, prerollSamples: h.take.count)
        }
        for step in 12..<42 {
            let t = Double(step) / 10
            h.sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
            if !session.stopped { session.deliver?(CapturePacket(start: t, samples: hiss(t))) }
            h.router.queue.sync {}
        }
        XCTAssertEqual(h.replacements.first?.index, 4800)
        XCTAssertTrue(Array(h.take.prefix(4800)) == Array(repeating: Float(0.3), count: 4800))
        h.router.stop(); h.router.queue.sync {}
    }

    // ai-suggestion:unverified · session:unknown · 2026-10-02
    /// Same capture times, but the base worker delivers after the final headset callback.
    private func feedLateBase(_ h: Harness, steps: Int, base: (Double) -> [Float],
                              headset: (Double) -> [Float]) -> [Float] {
        for step in 0..<steps {
            let t = 1 + Double(step) / 10
            h.sessions[1].deliver?(CapturePacket(start: t, samples: headset(t)))
        }
        h.router.queue.sync {}
        var expected: [Float] = []
        for step in 0..<steps {
            let t = 1 + Double(step) / 10
            let samples = base(t)
            expected += samples
            h.sessions[0].deliver?(CapturePacket(start: t, samples: samples))
            h.router.queue.sync {}
            if step < steps - 1 {
                XCTAssertTrue(h.replacements.isEmpty, "do not truncate headset audio while its replacement is incomplete")
            }
        }
        return expected
    }

    func testLateBaseEvidenceAfterFinalHeadsetCallbackReplacesCompleteWaveform() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        let expected = feedLateBase(h, steps: 20, base: voice, headset: hiss)
        XCTAssertEqual(h.events.map(\.reason), [.staticNoise])
        XCTAssertEqual(h.replacements.count, 1)
        XCTAssertEqual(h.take, expected)
        h.router.stop(); h.router.queue.sync {}
    }

    func testLateBaseEvidenceWithUnalignedClockPreservesBaseWaveform() {
        for offset in [-0.25 / 16_000.0, 0.25 / 16_000.0] {
            let h = harness()
            feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
            h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
            for step in 0..<20 {
                let t = 1 + Double(step) / 10
                h.sessions[1].deliver?(CapturePacket(start: t, samples: hiss(t)))
            }
            var expected: [Float] = []
            for step in 0..<20 {
                let t = 1 + Double(step) / 10 + offset
                let samples = voice(t)
                expected += samples
                h.sessions[0].deliver?(CapturePacket(start: t, samples: samples))
            }
            h.router.queue.sync { h.router.flush() }
            XCTAssertEqual(h.events.map(\.reason), [.staticNoise])
            XCTAssertTrue(h.take == expected, "unaligned clocks must retain the exact base samples")
            h.router.stop(); h.router.queue.sync {}
        }
    }

    func testShortTakeWithLateBaseTailPreservesOriginalAtStop() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        for step in 0..<15 {
            let t = 1 + Double(step) / 10
            h.sessions[1].deliver?(CapturePacket(start: t, samples: hiss(t)))
        }
        h.router.queue.sync {}
        let original = h.take
        for step in 0..<14 {
            let t = 1 + Double(step) / 10
            h.sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
        }
        h.router.queue.sync { h.router.flush(); h.recording = false; h.router.setRecording(false) }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.replacements.isEmpty)
        XCTAssertTrue(h.take == original, "no last-word truncation to recover the earlier 1.4 seconds")
        h.sessions[0].deliver?(CapturePacket(start: 2.4, samples: voice(2.4)))
        h.router.queue.sync {}
        XCTAssertTrue(h.replacements.isEmpty, "late callbacks must not rewrite a closed take")
        XCTAssertTrue(h.take == original)
        h.router.stop(); h.router.queue.sync {}
    }

    func testLongStaticTakeWithLateBaseEvidenceIsRecoveredWhenFlushed() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        let expected = feedLateBase(h, steps: 32, base: voice, headset: hiss)
        h.router.queue.sync { h.router.flush(); h.recording = false; h.router.setRecording(false) }
        XCTAssertEqual(h.events.map(\.reason), [.staticNoise])
        XCTAssertEqual(h.replacements.count, 1)
        XCTAssertEqual(h.take, expected, "stop must preserve the full replacement without duplicating its tail")
        h.router.stop(); h.router.queue.sync {}
    }

    func testLateBaseEvidenceDoesNotReplaceWorkingHeadsetOrQuietRoom() {
        for workingHeadset in [false, true] {
            let h = harness()
            let headset: (Double) -> [Float] = workingHeadset ? voice : hiss
            let base: (Double) -> [Float] = workingHeadset ? voice : quiet
            feed(h, from: 0, seconds: 1, base: quiet, headset: headset)
            h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
            _ = feedLateBase(h, steps: 24, base: base, headset: headset)
            let original = h.take
            h.router.queue.sync { h.router.flush() }
            XCTAssertTrue(h.events.isEmpty)
            XCTAssertTrue(h.replacements.isEmpty)
            XCTAssertEqual(h.take, original)
            h.router.stop(); h.router.queue.sync {}
        }
    }

    func testLateBaseEvidenceWithMissingTailDoesNotTruncateTakeAtStop() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        for step in 0..<24 {
            let t = 1 + Double(step) / 10
            h.sessions[1].deliver?(CapturePacket(start: t, samples: hiss(t)))
        }
        h.router.queue.sync {}
        let original = h.take
        for step in 0..<20 {
            let t = 1 + Double(step) / 10
            h.sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
        }
        h.router.queue.sync { h.router.flush() }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.replacements.isEmpty)
        XCTAssertEqual(h.take, original)
        h.router.stop(); h.router.queue.sync {}
    }

    func testLateBaseEvidenceWithHistoryGapDoesNotSpliceOutMissingAudio() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        for step in 0..<24 {
            let t = 1 + Double(step) / 10
            h.sessions[1].deliver?(CapturePacket(start: t, samples: hiss(t)))
        }
        h.router.queue.sync {}
        let original = h.take
        for step in 0..<24 where step != 8 {
            let t = 1 + Double(step) / 10
            h.sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
        }
        h.router.queue.sync { h.router.flush() }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.replacements.isEmpty)
        XCTAssertEqual(h.take, original)
        h.router.stop(); h.router.queue.sync {}
    }

    func testStaticHeadsetSwitchesToTheMacMicMidTakeAndKeepsTheMacAudio() {
        let h = harness()
        XCTAssertEqual(h.sessions.map { $0.device?.uid }, [builtIn.uid, airPods.uid])
        // Before the take: both deliver, dictation audio comes from the headset.
        feed(h, from: 0, seconds: 1, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 4, base: voice, headset: hiss)
        XCTAssertEqual(h.events, [CaptureFallback(uid: airPods.uid, name: airPods.name, fallbackName: builtIn.name, reason: .staticNoise)])
        XCTAssertTrue(h.sessions[1].stopped, "the static stream is closed")
        XCTAssertEqual(h.sessions.count, 2, "not reopened during the same take")
        XCTAssertEqual(h.replacements.first?.index, 0, "the whole headset stretch is replaced")
        XCTAssertEqual(h.replacements.first?.source, builtIn.name)
        // The take is now exactly what the Mac's microphone heard from the take's start on.
        var expected: [Float] = []
        var t = 1.0
        while t < 5 - 1e-9 { expected += voice(t); t += 0.1 }
        XCTAssertEqual(h.take.count, expected.count)
        XCTAssertEqual(h.take, expected)
        h.router.queue.sync { h.recording = false; h.router.setRecording(false) }
        XCTAssertEqual(h.sessions.count, 3, "reopened (and verified again) after the take")
        h.router.stop(); h.router.queue.sync {}
    }

    func testSwitchHappensWithinTheTakeNotAtItsEnd() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 2.5, base: voice, headset: hiss)
        XCTAssertEqual(h.events.map(\.reason), [.staticNoise], "decided after about two seconds of static")
        h.router.stop(); h.router.queue.sync {}
    }

    func testHeadsetHissWhileNobodySpeaksIsLeftAlone() {
        let h = harness()
        feed(h, from: -1, seconds: 1, base: quiet, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 0, seconds: 5, base: quiet, headset: hiss)
        XCTAssertTrue(h.events.isEmpty, "the Mac heard no voice, so static proves nothing")
        XCTAssertFalse(h.sessions[1].stopped)
        h.router.stop(); h.router.queue.sync {}
    }

    func testWorkingHeadsetIsNeverSwitched() {
        let h = harness()
        feed(h, from: -1, seconds: 1, base: voice, headset: voice)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 0, seconds: 6, base: voice, headset: voice)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.replacements.isEmpty)
        h.router.stop(); h.router.queue.sync {}
    }

    func testNoJudgmentBetweenTakes() {
        let h = harness()
        feed(h, from: 0, seconds: 5, base: voice, headset: hiss)
        XCTAssertTrue(h.events.isEmpty)
        h.router.stop(); h.router.queue.sync {}
    }

    func testPinnedHeadsetGetsTheSameSwitch() {
        let h = harness(stayOn: false)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        XCTAssertTrue(h.events.isEmpty, "a pinned headset opens per take; 'not ready' is expected")
        feed(h, from: 0, seconds: 4, base: voice, headset: hiss)
        XCTAssertEqual(h.events.map(\.reason), [.staticNoise])
        // The headset opened after the Mac mic had started the take; its stretch is still replaced.
        XCTAssertEqual(h.replacements.count, 1)
        var expected: [Float] = []
        var t = 0.0
        while t < 4 - 1e-9 { expected += voice(t); t += 0.1 }
        XCTAssertEqual(h.take.count, expected.count)
        XCTAssertLessThan(zip(h.take, expected).map { abs($0 - $1) }.max() ?? 1, 1e-4)
        h.router.stop(); h.router.queue.sync {}
    }

    func testOnlyTheStaticRunIsReplacedAndGoodHeadsetAudioStays() {
        let h = harness()
        let headsetVoice: (Double) -> [Float] = { SyntheticAudio.voice(seconds: 0.1, peak: 0.2, offset: $0) }
        feed(h, from: 0, seconds: 1, base: voice, headset: headsetVoice)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 3, base: voice, headset: headsetVoice)
        feed(h, from: 4, seconds: 3, base: voice, headset: hiss)
        XCTAssertEqual(h.events.map(\.reason), [.staticNoise])
        let replaced = try? XCTUnwrap(h.replacements.first)
        // The replacement starts near 4 s into the host clock, i.e. about 3 s into the take.
        XCTAssertGreaterThan(replaced?.index ?? 0, 16_000 * 2)
        XCTAssertLessThanOrEqual(replaced?.index ?? .max, 16_000 * 3 + 1_600)
        // The first two seconds are still the headset's own (louder) voice.
        var headsetPart: [Float] = []
        var t = 1.0
        while t < 3 - 1e-9 { headsetPart += headsetVoice(t); t += 0.1 }
        XCTAssertLessThan(zip(h.take.prefix(headsetPart.count), headsetPart).map { abs($0 - $1) }.max() ?? 1, 1e-4)
        // And the take ends with what the Mac heard.
        var lastT = 4.0
        while lastT + 0.1 < 7 - 1e-9 { lastT += 0.1 } // the same steps `feed` takes
        XCTAssertLessThan(zip(h.take.suffix(1_600), voice(lastT)).map { abs($0 - $1) }.max() ?? 1, 1e-4)
        h.router.stop(); h.router.queue.sync {}
    }

    func testTwoStaticTakesInARowMarkTheStayOnHeadsetUnhealthy() {
        let h = harness()
        var health: [Bool] = []
        h.router.onHeadsetHealth = { _, healthy in health.append(healthy) }
        for take in 0..<2 {
            let start = Double(take) * 10
            feed(h, from: start, seconds: 1, base: voice, headset: hiss)
            h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
            feed(h, from: start + 1, seconds: 3, base: voice, headset: hiss)
            h.router.queue.sync { h.recording = false; h.router.setRecording(false) }
            XCTAssertEqual(health.filter { !$0 }.count, take == 0 ? 0 : 1, "take \(take)")
        }
        h.router.stop(); h.router.queue.sync {}
    }

    /// With a real clock the reopened headset delivers static for more than five seconds.
    /// That must not count as healthy while it has strikes, or Stay on's back-off never grows.
    func testStaticHeadsetIsNotReportedHealthyAgainWhileItHasStrikes() {
        let h = harness()
        var health: [Bool] = []
        h.router.onHeadsetHealth = { _, healthy in health.append(healthy) }
        // The clock moves with the audio, packet by packet, so the 1 Hz health check never
        // sees a jump.
        func run(from start: Double, steps: Int, base: @escaping (Double) -> [Float]) {
            for step in 0..<steps {
                let t = start + Double(step) * 0.1
                h.router.queue.sync { h.clock = t }
                feed(h, from: t, seconds: 0.1, base: base, headset: hiss)
            }
        }
        func take(at start: Double) {
            run(from: start, steps: 10, base: voice)
            h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
            run(from: start + 1, steps: 30, base: voice)
            h.router.queue.sync { h.recording = false; h.router.setRecording(false) }
        }
        take(at: 0)
        take(at: 4)
        XCTAssertEqual(health, [false], "unhealthy after two static takes")
        // After the takes the reopened headset keeps sending static for eight seconds.
        run(from: 8, steps: 80, base: quiet)
        XCTAssertEqual(health, [false], "no healthy report while strikes stand")
        h.router.stop(); h.router.queue.sync {}
    }

    func testShortTakesDoNotClearStrikes() {
        let h = harness()
        var health: [Bool] = []
        h.router.onHeadsetHealth = { _, healthy in health.append(healthy) }
        feed(h, from: 0, seconds: 1, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 3, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = false; h.router.setRecording(false) }
        // A one-second take on the reopened headset: too short to judge.
        feed(h, from: 5, seconds: 1, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 6, seconds: 1, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = false; h.router.setRecording(false) }
        feed(h, from: 8, seconds: 1, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 9, seconds: 3, base: voice, headset: hiss)
        XCTAssertEqual(health.filter { !$0 }.count, 1, "the second static take still counts as the second strike")
        h.router.stop(); h.router.queue.sync {}
    }

    func testHeadsetThatLeavesMidTakeIsAnnounced() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: voice)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 1, base: voice, headset: voice)
        h.router.configure(devices: [builtIn], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: airPods.uid)
        h.router.queue.sync {}
        XCTAssertEqual(h.events.map(\.reason), [.stopped])
        h.router.stop(); h.router.queue.sync {}
    }

    func testChoosingAnotherMicMidTakeIsNotAnnounced() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: voice)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 1, base: voice, headset: voice)
        h.router.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: nil)
        h.router.queue.sync {}
        XCTAssertTrue(h.events.isEmpty)
        h.router.stop(); h.router.queue.sync {}
    }

    /// "Yes, send it": 1.5 s on a static headset is judged when the take ends.
    func testShortStaticTakeIsSwitchedWhenItEnds() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 1.5, base: voice, headset: hiss)
        XCTAssertTrue(h.events.isEmpty, "too short to judge while it runs")
        h.router.queue.sync { h.router.flush(); h.recording = false; h.router.setRecording(false) }
        XCTAssertEqual(h.events.map(\.reason), [.staticNoise])
        XCTAssertEqual(h.replacements.first?.index, 0)
        var expected: [Float] = []
        var t = 1.0
        while t < 2.5 - 1e-9 { expected += voice(t); t += 0.1 }
        XCTAssertEqual(h.take.count, expected.count)
        XCTAssertLessThan(zip(h.take, expected).map { abs($0 - $1) }.max() ?? 1, 1e-4)
        h.router.stop(); h.router.queue.sync {}
    }

    func testShortStaticTakeWithNobodySpeakingIsLeftAlone() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: quiet, headset: hiss)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 1.5, base: quiet, headset: hiss)
        h.router.queue.sync { h.router.flush(); h.recording = false; h.router.setRecording(false) }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.replacements.isEmpty)
        h.router.stop(); h.router.queue.sync {}
    }

    func testSleepMidTakeShowsNoSwitchNotice() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: voice)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 1, base: voice, headset: voice)
        h.router.suspend(); h.router.queue.sync {}
        XCTAssertTrue(h.events.isEmpty)
        h.router.stop(); h.router.queue.sync {}
    }

    func testNotReadyThenStaticInTheSameTakeAreBothAnnounced() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: nil)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 3, base: voice, headset: hiss)
        XCTAssertEqual(h.events.map(\.reason), [.notReady, .staticNoise])
        h.router.stop(); h.router.queue.sync {}
    }

    func testStayOnHeadsetWithoutVerifiedAudioAtTheStartIsAnnounced() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: nil)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        XCTAssertEqual(h.events.map(\.reason), [.notReady])
        h.router.stop(); h.router.queue.sync {}
    }

    func testHeadsetThatStopsMidTakeIsAnnouncedOnce() {
        let h = harness()
        feed(h, from: 0, seconds: 1, base: voice, headset: voice)
        h.router.queue.sync { h.recording = true; h.router.setRecording(true) }
        feed(h, from: 1, seconds: 1, base: voice, headset: voice)
        h.sessions[1].fail?("route lost")
        h.router.queue.sync {}
        XCTAssertEqual(h.events.map(\.reason), [.stopped])
        h.router.stop(); h.router.queue.sync {}
    }

    func testNoticeCopyNamesBothMicrophones() {
        typealias Copy = StayOnNoticeCopy
        XCTAssertEqual(Copy.text(for: .fellBack(uid: "a", name: "Jamie’s AirPods Pro", usingName: "MacBook Pro Microphone", reason: .staticNoise)).message,
                       "AirPods Pro sounded like static. Switched to MacBook Pro Microphone.")
        XCTAssertEqual(Copy.text(for: .fellBack(uid: "a", name: "Jamie’s AirPods Pro", usingName: "MacBook Pro Microphone", reason: .stopped)).message,
                       "AirPods Pro stopped sending audio. Switched to MacBook Pro Microphone.")
        XCTAssertEqual(Copy.text(for: .fellBack(uid: "a", name: "Jamie’s AirPods Pro", usingName: "MacBook Pro Microphone", reason: .notReady)).message,
                       "AirPods Pro wasn't ready. Using MacBook Pro Microphone.")
        for reason in [HeadsetFallbackReason.staticNoise, .stopped, .notReady] {
            let text = Copy.text(for: .fellBack(uid: "a", name: "AirPods Pro", usingName: "MacBook Pro Microphone", reason: reason))
            XCTAssertFalse(text.message.contains("—"))
            XCTAssertNil(text.stayOnButton)
            XCTAssertFalse(text.undo)
        }
    }

    /// Through AudioRecorder: the WAV on disk and the returned samples both hold the Mac's audio.
    func testRecorderReplacesTheHeadsetStretchOnDiskAndInMemory() throws {
        var sessions: [ScriptedCapture] = []
        let recorder = AudioRecorder(factory: { let s = ScriptedCapture(); sessions.append(s); return s })
        recorder.capture.configure(devices: [builtIn, airPods], systemDefault: builtIn, pin: nil, prelisten: true, stayOn: airPods.uid)
        recorder.capture.start(); recorder.capture.queue.sync {}
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url); recorder.shutdown(); recorder.capture.queue.sync {} }
        func feed(from: Double, seconds: Double) {
            var t = from
            while t < from + seconds - 1e-9 {
                sessions[0].deliver?(CapturePacket(start: t, samples: voice(t)))
                if !sessions[1].stopped { sessions[1].deliver?(CapturePacket(start: t, samples: hiss(t))) }
                recorder.capture.queue.sync {}
                t += 0.1
            }
        }
        feed(from: 0, seconds: 1)
        try recorder.startRecording(to: url)
        feed(from: 1, seconds: 4)
        let result = try XCTUnwrap(recorder.stopRecording())
        // Pre-roll (0.5 s before the take) plus the take, all from the Mac's microphone.
        var expected: [Float] = []
        var t = 0.5
        while t < 5 - 1e-9 { expected += voice(t); t += 0.1 }
        XCTAssertEqual(result.samples.count, expected.count)
        XCTAssertLessThan(zip(result.samples, expected).map { abs($0 - $1) }.max() ?? 1, 1e-4,
                          "the Mac microphone's audio, sample for sample")
        let onDisk = try ProcessCommand.loadSamples(from: url)
        XCTAssertEqual(onDisk.count, expected.count)
        XCTAssertFalse(CaptureStaticJudge.isStatic(samples: onDisk))
    }
}

final class StaticTakeTests: XCTestCase {
    private final class EmptyEngine: TranscriptionEngine {
        let engineID = "parakeet-test"
        var keepModelLoaded = "auto"
        var supportsStreaming: Bool { false }
        var supportsPrompt: Bool { false }
        var isLoaded = true
        var lastDiagnostics: TranscriptionDiagnostics? { nil }
        func loadModel(modelID: String) async throws {}
        func unloadModel() async {}
        func startMemoryPressureMonitoring() {}
        func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String { "" }
        func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                                 onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("static-rescue-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        // A Whisper model "on disk": no Whisper run may follow a static take regardless.
        FileManager.default.createFile(atPath: root.appendingPathComponent("models/ggml-large-v3-turbo.bin").path, contents: Data())
        Config.configDirOverride = root
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private final class OneWordEngine: TranscriptionEngine {
        let engineID = "parakeet-test"
        var keepModelLoaded = "auto"
        var supportsStreaming: Bool { false }
        var supportsPrompt: Bool { false }
        var isLoaded = true
        var lastDiagnostics: TranscriptionDiagnostics? { nil }
        func loadModel(modelID: String) async throws {}
        func unloadModel() async {}
        func startMemoryPressureMonitoring() {}
        func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String { words }
        var words = "hello there"
        func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                                 onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    /// Three engine words on a long static take are left to the engine.
    func testStaticTakeKeepsThreeEngineWords() async throws {
        let samples = SyntheticAudio.staticNoise(seconds: 8, rms: 0.06)
        let url = root.appendingPathComponent("recording-2026-09-25-191813-test.wav")
        let writer = try WavWriter(url: url)
        try writer.append(samples); writer.close()
        let engine = OneWordEngine()
        engine.words = "hello there friend"
        let transcriber = Transcriber(engine: engine, modelID: "synthetic", language: "en")
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(statuses, [])
        XCTAssertEqual(text, "hello there friend", "three words are left to the engine")
    }

    func testOneOrTwoWordsReadOutOfStaticAreDropped() async throws {
        let samples = SyntheticAudio.staticNoise(seconds: 4, rms: 0.06)
        let url = root.appendingPathComponent("recording-2026-09-25-191802-test.wav")
        let writer = try WavWriter(url: url)
        try writer.append(samples); writer.close()
        let transcriber = Transcriber(engine: OneWordEngine(), modelID: "synthetic", language: "en")
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(text, "")
        XCTAssertEqual(statuses, [.staticNoise])
    }

    func testShortStaticTakeSaysStatic() async throws {
        let samples = SyntheticAudio.staticNoise(seconds: 1.3, rms: 0.06)
        let url = root.appendingPathComponent("recording-2026-09-25-191834-test.wav")
        let writer = try WavWriter(url: url)
        try writer.append(samples); writer.close()
        let transcriber = Transcriber(engine: EmptyEngine(), modelID: "synthetic", language: "en")
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(text, "")
        XCTAssertEqual(statuses, [.staticNoise])
    }

    func testEmptyStaticTakeSaysStatic() async throws {
        let samples = SyntheticAudio.staticNoise(seconds: 4, rms: 0.06)
        let url = root.appendingPathComponent("recording-2026-09-25-184507-test.wav")
        let writer = try WavWriter(url: url)
        try writer.append(samples); writer.close()
        let transcriber = Transcriber(engine: EmptyEngine(), modelID: "synthetic", language: "en")
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(text, "")
        XCTAssertEqual(statuses, [.staticNoise])
        XCTAssertEqual(Transcriber.TakeStatus.staticNoise.message, "Didn't catch that. The mic sounded like static.")
    }
}
