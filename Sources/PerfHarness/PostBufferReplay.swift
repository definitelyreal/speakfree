// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22
//
// Speed loop W1: replay the post-release wait over real archived takes.
//
// For each take (WAV + the sample index at key release) this simulates the app's live 30 ms poll
// loop with the production PostBufferPolicy, once with today's fixed thresholds and once per
// noise-relative candidate, and reports how long each would have waited. With --asr it then runs
// Parakeet on the audio each policy would have kept and compares the words, so a candidate that
// clips a real trailing word shows up as a lost-word take. The engine is called directly (not
// Transcriber) so no whisper-cli fallback re-reads the untruncated WAV from disk.
//
// Manifest: JSON array of {"id": String, "wav": path, "releaseSample": Int}.
// Output JSON has timings and word COUNTS only; with --words it also includes the differing
// tail words for private inspection (never commit that output).

import Foundation
import SpeakFreeLib

enum PostBufferReplay {
    struct Take: Decodable {
        let id: String
        let wav: String
        let releaseSample: Int
    }

    struct Variant {
        let name: String
        let silenceRatio: Float?
        let speechRatio: Float?
        /// Control arm: today's fixed decision, cut this many ms earlier (timer-jitter scale).
        var controlShiftMs: Int = 0
    }

    struct Decision: Encodable {
        let waitMs: Double
        let cutSample: Int
        let tailExhausted: Bool
        let extended: Bool
    }

    struct TakeResult: Encodable {
        let id: String
        let audioSeconds: Double
        let releaseSample: Int
        let noiseFloor: Float
        let decisions: [String: Decision]
        var asr: [String: AsrCompare] = [:]
    }

    struct AsrCompare: Encodable {
        let baselineWords: Int
        let candidateWords: Int
        let identical: Bool
        /// Baseline words from the first divergence onward (conservative upper bound).
        let lostTailWords: Int
        /// The last two words differ: the signature of a clipped ending.
        let endChanged: Bool
        let baselineTail: String?
        let candidateTail: String?
    }

    static let windowMs = PostBufferPolicy.defaultWindowMs
    static let capMs = PostBufferPolicy.defaultExtendedCapMs

    /// Mirror of AppDelegate.runAdaptivePostBuffer: poll every window, ask the policy, stop when
    /// the decided wait or the cap has elapsed. Audio after the WAV's end is unknown; if the
    /// policy still wants more when the tail runs out the take is marked exhausted and cut at
    /// the end of what was recorded (which is what the app itself kept).
    static func simulate(tail: [Float], release: Int, thresholds: PostBufferPolicy.Thresholds) -> Decision {
        let windowSamples = Int(windowMs / 1000.0 * 16_000.0)
        var tick = 1
        while true {
            let elapsed = Double(tick) * windowMs
            let observedCount = min(tail.count, tick * windowSamples)
            let observed = Array(tail[0..<observedCount])
            let decided = PostBufferPolicy.decideWaitMs(
                trailingSamples: observed, windowMs: windowMs,
                silenceThreshold: thresholds.silence, capMs: PostBufferPolicy.defaultCapMs,
                speechThreshold: thresholds.speech)
            let rms = PostBufferPolicy.windowRMSValues(samples: observed, windowSamples: windowSamples)
            let extended = rms.contains { $0 >= thresholds.speech }
            if PostBufferPolicy.postBufferShouldFinalize(elapsedMs: elapsed, decidedMs: decided, capMs: capMs) {
                return Decision(waitMs: elapsed, cutSample: release + observedCount,
                                tailExhausted: false, extended: extended)
            }
            if tick * windowSamples >= tail.count {
                return Decision(waitMs: elapsed, cutSample: release + tail.count,
                                tailExhausted: true, extended: extended)
            }
            tick += 1
        }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func compare(_ base: String, _ cand: String, includeWords: Bool) -> AsrCompare {
        let b = words(base), c = words(cand)
        var common = 0
        while common < min(b.count, c.count), b[common] == c[common] { common += 1 }
        // Conservative: every baseline word after the first divergence counts as lost.
        let lost = b == c ? 0 : b.count - common
        return AsrCompare(
            baselineWords: b.count, candidateWords: c.count, identical: b == c, lostTailWords: lost,
            endChanged: Array(b.suffix(2)) != Array(c.suffix(2)),
            baselineTail: includeWords && b != c ? b.suffix(max(1, b.count - common)).joined(separator: " ") : nil,
            candidateTail: includeWords && b != c ? c.suffix(max(1, c.count - common)).joined(separator: " ") : nil)
    }

    static func run(args: [String]) -> Int32 {
        guard let manifestPath = value(for: "--manifest", in: args) else { fail("postbuffer-replay needs --manifest") }
        let outPath = value(for: "--out", in: args)
        let doASR = args.contains("--asr")
        let includeWords = args.contains("--words")
        let model = value(for: "--model", in: args) ?? "parakeet-tdt-0.6b-v2"
        let ratioSpec = value(for: "--ratios", in: args) ?? "1.5:2.0"
        var variants = [Variant(name: "fixed", silenceRatio: nil, speechRatio: nil)]
        for pair in ratioSpec.split(separator: ",") {
            let p = pair.split(separator: ":").compactMap { Float($0) }
            guard p.count == 2 else { fail("bad --ratios entry '\(pair)' (want silence:speech)") }
            variants.append(Variant(name: "rel-\(p[0])-\(p[1])", silenceRatio: p[0], speechRatio: p[1]))
        }
        for ms in (value(for: "--controls", in: args) ?? "").split(separator: ",").compactMap({ Int($0) }) {
            variants.append(Variant(name: "control-minus-\(ms)ms", silenceRatio: nil, speechRatio: nil,
                                    controlShiftMs: ms))
        }

        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: manifestPath)) } catch { fail("read manifest: \(error)") }
        let takes: [Take]
        do { takes = try JSONDecoder().decode([Take].self, from: data) } catch { fail("parse manifest: \(error)") }

        var engine: ParakeetEngine?
        if doASR {
            let e = ParakeetEngine()
            do { try Benchmark.blocking { try await e.loadModel(modelID: model) } } catch { fail("load \(model): \(error)") }
            engine = e
        }

        var results: [TakeResult] = []
        for (i, take) in takes.enumerated() {
            let samples: [Float]
            do { samples = try ProcessCommand.loadSamples(from: URL(fileURLWithPath: take.wav)) } catch {
                FileHandle.standardError.write(Data("skip \(take.id): \(error)\n".utf8)); continue
            }
            guard take.releaseSample > 0, take.releaseSample < samples.count else {
                FileHandle.standardError.write(Data("skip \(take.id): release outside audio\n".utf8)); continue
            }
            let pre = Array(samples[0..<take.releaseSample])
            let tail = Array(samples[take.releaseSample...])
            let floor = PostBufferPolicy.noiseFloor(preReleaseSamples: pre)
            var decisions: [String: Decision] = [:]
            for v in variants {
                let t = v.silenceRatio.map {
                    PostBufferPolicy.noiseRelativeThresholds(noiseFloor: floor, silenceRatio: $0, speechRatio: v.speechRatio!)
                } ?? PostBufferPolicy.fixedThresholds
                var d = simulate(tail: tail, release: take.releaseSample, thresholds: t)
                if v.controlShiftMs > 0 {
                    let cut = max(take.releaseSample, d.cutSample - v.controlShiftMs * 16)
                    d = Decision(waitMs: d.waitMs - Double(v.controlShiftMs), cutSample: cut,
                                 tailExhausted: d.tailExhausted, extended: d.extended)
                }
                decisions[v.name] = d
            }
            var result = TakeResult(id: take.id, audioSeconds: Double(samples.count) / 16_000,
                                    releaseSample: take.releaseSample, noiseFloor: floor, decisions: decisions)
            if let engine, let base = decisions["fixed"] {
                var cache: [Int: String] = [:]
                func text(_ cut: Int) -> String {
                    if let t = cache[cut] { return t }
                    let t = (try? Benchmark.blocking {
                        try await engine.transcribe(samples: Array(samples[0..<cut]), language: "en",
                                                    prompt: nil, suppressRegex: nil)
                    }) ?? ""
                    cache[cut] = t
                    return t
                }
                for v in variants.dropFirst() {
                    guard let d = decisions[v.name] else { continue }
                    if d.cutSample >= base.cutSample {
                        result.asr[v.name] = AsrCompare(baselineWords: -1, candidateWords: -1, identical: true,
                                                        lostTailWords: 0, endChanged: false,
                                                        baselineTail: nil, candidateTail: nil)
                    } else {
                        result.asr[v.name] = compare(text(base.cutSample), text(d.cutSample), includeWords: includeWords)
                    }
                }
            }
            results.append(result)
            if (i + 1) % 25 == 0 {
                FileHandle.standardError.write(Data("replayed \(i + 1)/\(takes.count)\n".utf8))
            }
        }

        // Summary table on stdout.
        print("takes replayed: \(results.count)")
        for v in variants {
            let waits = results.compactMap { $0.decisions[v.name]?.waitMs }.sorted()
            func pct(_ p: Double) -> Double { waits.isEmpty ? .nan : waits[min(waits.count - 1, Int(Double(waits.count - 1) * p))] }
            let ext = results.filter { $0.decisions[v.name]?.extended == true }.count
            let exhausted = results.filter { $0.decisions[v.name]?.tailExhausted == true }.count
            var line = String(format: "%-16@ wait p50 %4.0f ms  p90 %4.0f ms  mean %4.0f ms  extended %d  tail-exhausted %d",
                              v.name as NSString, pct(0.5), pct(0.9),
                              waits.isEmpty ? .nan : waits.reduce(0, +) / Double(waits.count), ext, exhausted)
            if doASR, v.name != "fixed" {
                let cmp = results.compactMap { $0.asr[v.name] }
                let changed = cmp.filter { !$0.identical }.count
                let ends = cmp.filter { $0.endChanged }.count
                line += "  asr changed \(changed)  ending changed \(ends)"
            }
            print(line)
        }

        if let outPath {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try enc.encode(results).write(to: URL(fileURLWithPath: outPath)) } catch { fail("write out: \(error)") }
        }
        return 0
    }
}
