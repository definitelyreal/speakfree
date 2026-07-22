// Claude · 2026-07-22 · Session: vocab-boost-eval worktree loop
//
// vocab-eval — offline A/B harness for Parakeet vocabulary boosting.
//
// For each wav it can produce, in one process (models loaded once):
//   tdt         production batch TDT decode (3s silence pad — byte-identical logic to
//               ParakeetEngine's batch path)
//   sliding     sliding-window decode, NO vocabulary (base-quality comparison vs tdt)
//   slideboost  sliding-window decode + vocabulary biasing (the 2026-07-03 disabled design)
//   batchboost  batch TDT + CTC rescorer overlay + real-word guard (VocabularyBoost)
//
// Usage:
//   vocab-eval run --paths tdt,batchboost --out results.jsonl --model parakeet-tdt-0.6b-v2 \
//       [--vocab-file ~/.config/speakfree/vocabulary.txt] [--alias-file curated.json] \
//       [--unguarded] wav1 wav2 ...   (or --wav-list file-with-paths)
//
// Emits one JSON object per wav on --out (JSONL). Everything is ai-suggestion:unverified.

import AVFoundation
import Foundation
import FluidAudio
import SpeakFreeLib

// MARK: - Plumbing

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("vocab-eval: \(msg)\n".utf8))
    exit(2)
}

func flagValue(_ flag: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func boolFlag(_ flag: String, _ args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

func log(_ msg: String) {
    FileHandle.standardError.write(Data("vocab-eval: \(msg)\n".utf8))
}

// MARK: - Audio decode (16k mono Float32) — same contract as ProcessCommand.loadSamples

func loadSamples(_ url: URL) throws -> [Float] {
    try ProcessCommand.loadSamples(from: url)
}

// Copies of ParakeetEngine's fileprivate helpers (kept in exact sync with 130f970 behavior).
func trimTrailingSilence(_ s: [Float]) -> [Float] {
    let frame = 1600
    let margin = 3200
    let threshold: Float = 0.006
    guard s.count > frame else { return s }
    var i = s.count - frame
    while i >= 0 {
        var sum: Float = 0
        for j in i..<(i + frame) { sum += s[j] * s[j] }
        if (sum / Float(frame)).squareRoot() > threshold {
            return Array(s.prefix(min(s.count, i + frame + margin)))
        }
        i -= frame
    }
    return s
}

func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
        let ch = buf.floatChannelData?[0]
    else { return nil }
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
    return buf
}

/// ParakeetEngine's batch pad: up to 3s of trailing silence, capped at the 15s single chunk.
func padForBatch(_ samples: [Float]) -> [Float] {
    let trailingSilenceSamples = 48_000
    let maxSingleChunkSamples = 240_000
    var audio = samples
    let availablePad = max(0, maxSingleChunkSamples - audio.count)
    let pad = min(trailingSilenceSamples, availablePad)
    if pad > 0 { audio += [Float](repeating: 0, count: pad) }
    return audio
}

// MARK: - Result row

struct Row: Encodable {
    let wav: String
    let seconds: Double
    var tdt: String?
    var tdtMs: Int?
    var sliding: String?
    var slidingMs: Int?
    var slideboost: String?
    var slideboostMs: Int?
    var batchboost: String?
    var batchboostRaw: String?  // rescorer output before the guard
    var batchboostMs: Int?
    var prefilterSkipped: Bool?
    var decisions: [VocabularyBoost.Decision]?
    var error: String?
}

// MARK: - Sliding-window decode (replica of ParakeetEngine.transcribeSliding, be1257f..130f970)

func transcribeSliding(
    models: AsrModels, ctc: CtcModels?, vocab: CustomVocabularyContext?, audio: [Float]
) async throws -> String {
    let fedAudio = trimTrailingSilence(audio)

    let sw = SlidingWindowAsrManager(config: .streaming)
    try await sw.loadModels(models)
    if let ctc, let vocab {
        try await sw.configureVocabularyBoosting(vocabulary: vocab, ctcModels: ctc)
    }

    let updates = await sw.transcriptionUpdates
    let collector = Task { () -> String in
        var confirmed: [String] = []
        var bestVolatile = ""
        var bestVolatileConfidence: Float = -1
        for await u in updates {
            let t = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if u.isConfirmed {
                confirmed.append(t)
            } else if u.confidence > bestVolatileConfidence {
                bestVolatileConfidence = u.confidence
                bestVolatile = t
            }
        }
        var parts = confirmed
        if !bestVolatile.isEmpty { parts.append(bestVolatile) }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    try await sw.startStreaming(source: .microphone)
    let chunk = 16_000
    var i = 0
    while i < fedAudio.count {
        let end = min(i + chunk, fedAudio.count)
        if let buf = makeBuffer(from: Array(fedAudio[i..<end])) {
            await sw.streamAudio(buf)
        }
        i = end
    }
    let finishText = (try await sw.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
    await sw.cancel()
    let collected = await collector.value
    return collected.count > finishText.count ? collected : finishText
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "run" else {
    fail("usage: vocab-eval run --paths tdt,sliding,slideboost,batchboost --out results.jsonl [--model id] [--vocab-file f] [--alias-file f] [--unguarded] [--wav-list f] wav...")
}
args.removeFirst()

let pathsCSV = flagValue("--paths", &args) ?? "tdt,batchboost"
let outPath = flagValue("--out", &args) ?? "results.jsonl"
let modelID = flagValue("--model", &args) ?? "parakeet-tdt-0.6b-v2"
let home = FileManager.default.homeDirectoryForCurrentUser
let vocabFile = flagValue("--vocab-file", &args)
    ?? home.appendingPathComponent(".config/speakfree/vocabulary.txt").path
let aliasFile = flagValue("--alias-file", &args)
let unguarded = boolFlag("--unguarded", &args)
let noPrefilter = boolFlag("--no-prefilter", &args)
let wavListFile = flagValue("--wav-list", &args)

var wavs = args.filter { !$0.hasPrefix("--") }
if let wavListFile {
    guard let list = try? String(contentsOfFile: wavListFile, encoding: .utf8) else {
        fail("cannot read --wav-list \(wavListFile)")
    }
    wavs += list.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}
guard !wavs.isEmpty else { fail("no wav files given") }

let paths = Set(pathsCSV.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
let needCtc = !paths.isDisjoint(with: ["slideboost", "batchboost"])
let needSliding = !paths.isDisjoint(with: ["sliding", "slideboost"])
let needBatch = !paths.isDisjoint(with: ["tdt", "batchboost"])

// Never touch live config: point Config at an isolated scratch dir.
let scratchConfig = FileManager.default.temporaryDirectory
    .appendingPathComponent("vocab-eval-config-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: scratchConfig, withIntermediateDirectories: true)
Config.configDirOverride = scratchConfig

let runner = Task { () -> Int32 in
    do {
        guard ParakeetModelManager.shared.isModelDownloaded(modelID) else {
            fail("model \(modelID) not downloaded")
        }
        log("loading TDT models (\(modelID))…")
        let models = try await ParakeetModelManager.shared.loadedModels(modelID)

        var ctcModels: CtcModels?
        var vocabContext: CustomVocabularyContext?
        var spotter: CtcKeywordSpotter?
        var rescorer: VocabularyRescorer?
        if needCtc {
            log("loading CTC keyword-spotter…")
            let priorOffline = DownloadUtils.enforceOffline
            DownloadUtils.enforceOffline = false
            defer { DownloadUtils.enforceOffline = priorOffline }
            let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m))
            let aliases = aliasFile.map {
                VocabularyBoost.loadCuratedAliases(from: URL(fileURLWithPath: $0))
            } ?? [:]
            let specs = VocabularyBoost.loadTermSpecs(
                vocabularyFile: URL(fileURLWithPath: vocabFile), curatedAliases: aliases)
            let ctx = VocabularyBoost.makeContext(specs: specs, tokenizer: tokenizer)
            log("vocabulary: \(ctx.terms.count) CTC-tokenized terms (\(aliases.count) with curated aliases)")
            let sp = CtcKeywordSpotter(models: ctc)
            ctcModels = ctc
            vocabContext = ctx
            spotter = sp
            rescorer = try await VocabularyRescorer.create(
                spotter: sp, vocabulary: ctx,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m))
        }

        let batchManager: AsrManager? = needBatch ? AsrManager(config: .default) : nil
        if let batchManager {
            try await batchManager.loadModels(models)
        }

        let outURL = URL(fileURLWithPath: outPath)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        defer { try? outHandle.close() }
        let encoder = JSONEncoder()

        var done = 0
        for wav in wavs {
            let url = URL(fileURLWithPath: (wav as NSString).expandingTildeInPath)
            var row = Row(wav: url.path, seconds: 0)
            do {
                let samples = try loadSamples(url)
                row = Row(wav: url.path, seconds: Double(samples.count) / 16000.0)
                let padded = padForBatch(samples)

                var batchResult: ASRResult?
                if let batchManager {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    var state = TdtDecoderState.make(decoderLayers: await batchManager.decoderLayerCount)
                    let r = try await batchManager.transcribe(padded, decoderState: &state, language: nil)
                    batchResult = r
                    if paths.contains("tdt") {
                        row.tdt = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        row.tdtMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    }
                }

                if paths.contains("sliding") {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    row.sliding = try await transcribeSliding(
                        models: models, ctc: nil, vocab: nil, audio: padded)
                    row.slidingMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                }

                if paths.contains("slideboost") {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    row.slideboost = try await transcribeSliding(
                        models: models, ctc: ctcModels, vocab: vocabContext, audio: padded)
                    row.slideboostMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                }

                if paths.contains("batchboost"), let batchResult, let spotter, let rescorer,
                    let vocabContext {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let batchText = batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let boosted = try await VocabularyBoost.boost(
                        batchText: batchText,
                        tokenTimings: batchResult.tokenTimings ?? [],
                        audio: padded,
                        spotter: spotter, rescorer: rescorer, vocabulary: vocabContext,
                        usePrefilter: !noPrefilter)
                    row.batchboost = unguarded ? boosted.rescoredRaw : boosted.text
                    row.batchboostRaw = boosted.rescoredRaw
                    row.prefilterSkipped = boosted.prefilterSkipped
                    row.decisions = boosted.decisions
                    row.batchboostMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                }
            } catch {
                row.error = "\(error)"
            }

            let data = try encoder.encode(row)
            outHandle.write(data)
            outHandle.write(Data("\n".utf8))
            done += 1
            if done % 10 == 0 || done == wavs.count {
                log("processed \(done)/\(wavs.count)")
            }
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("vocab-eval: fatal \(error)\n".utf8))
        return 1
    }
}

// Block main thread on the async runner (CLI process).
let sema = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1
Task {
    exitCode = await runner.value
    sema.signal()
}
sema.wait()
exit(exitCode)
