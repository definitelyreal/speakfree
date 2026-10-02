// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Perf round 2: paired engine evaluation. Loads ParakeetEngine once and transcribes a list of
// WAVs through the production engine path (Silero endpointing, 3 s pad, TDT decode, vocabulary
// boost when the config dir has one, tail strips), recording text, word count, and time per take.
// Used to compare FluidAudio versions (build the harness twice, run the same manifest) and input
// transforms for the Parakeet empty-output investigation.
//
// Manifest: JSON array of {"id": String, "wav": path}. Output JSON holds TRANSCRIPT TEXT, so it
// must go to a private, gitignored path (build/). Config: whatever Config.configDir resolves to;
// pass SPEAKFREE_CONFIG_DIR to pin it (an empty dir = raw model, no user vocabulary).
//
// --transform (applied to the samples before the engine, repeatable as a comma list):
//   drop-ms:N         drop the first N ms (the pre-roll)
//   rms:X             scale so whole-take RMS = X (level normalization)
//   peak:X            scale so peak = X

import Foundation
import SpeakFreeLib

enum TranscribeBatch {
    struct Item: Decodable { let id: String; let wav: String }

    struct Result: Encodable {
        let id: String
        /// Length after transforms.
        let audioSeconds: Double
        let clippedSamples: Int
        let text: String
        let words: Int
        let ms: Double
        let error: String?
    }

    enum Transform {
        case dropMs(Double), rms(Float), peak(Float)
    }

    /// Parse before the model loads so a typo fails in milliseconds, not after a 20 s load.
    static func parse(_ specs: [String]) -> [Transform] {
        specs.map { t in
            let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let v = Double(parts[1]), v.isFinite, v >= 0 else {
                fail("bad --transform '\(t)' (want drop-ms:N, rms:X or peak:X with a finite value >= 0)")
            }
            switch parts[0] {
            case "drop-ms": guard v <= 3_600_000 else { fail("drop-ms must be at most one hour") }; return .dropMs(v)
            case "rms": guard v > 0, v <= 1 else { fail("rms target must be in (0, 1]") }; return .rms(Float(v))
            case "peak": guard v > 0, v <= 1 else { fail("peak target must be in (0, 1]") }; return .peak(Float(v))
            default: fail("unknown --transform kind '\(parts[0])' (drop-ms | rms | peak)")
            }
        }
    }

    /// Apply transforms; returns the samples and how many were clipped to [-1, 1] (a level A/B
    /// that clips is confounded, so the count is reported per take).
    static func apply(_ transforms: [Transform], to input: [Float]) -> (samples: [Float], clipped: Int) {
        var s = input
        var clipped = 0
        func scale(_ g: Float) {
            s = s.map { x in
                let y = x * g
                if y > 1 || y < -1 { clipped += 1; return max(-1, min(1, y)) }
                return y
            }
        }
        for t in transforms {
            switch t {
            case .dropMs(let ms): s = Array(s.dropFirst(min(s.count, Int(ms * 16.0))))
            case .rms(let target):
                let rms = PostBufferPolicy.rms(s[...])
                if rms > 0 { scale(target / rms) }
            case .peak(let target):
                let peak = s.map { abs($0) }.max() ?? 0
                if peak > 0 { scale(target / peak) }
            }
        }
        return (s, clipped)
    }

    /// Output holds transcript text: refuse a path inside the repo unless it is under the
    /// gitignored build/ or .build/ folders.
    static func checkPrivateOutput(_ path: String) {
        // Resolve symlinks (a symlinked checkout can point into a synced folder) and compare without case,
        // since the disk is case-insensitive.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let out = (url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path).lowercased()
        let root = Ratchet.repoRoot().resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard out.hasPrefix(root + "/") else { return }
        let rel = String(out.dropFirst(root.count + 1))
        guard rel.hasPrefix("build/") || rel.hasPrefix(".build/") else {
            fail("--out \(path) is inside the repo but not under build/ or .build/; transcripts must stay out of git")
        }
    }

    static func words(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func run(args: [String]) -> Int32 {
        guard let manifest = value(for: "--manifest", in: args) else { fail("transcribe-batch needs --manifest") }
        guard let outPath = value(for: "--out", in: args) else { fail("transcribe-batch needs --out (a private path)") }
        let model = value(for: "--model", in: args) ?? "parakeet-tdt-0.6b-v2"
        let transformSpecs = (value(for: "--transform", in: args) ?? "").split(separator: ",").map(String.init)
        let transforms = parse(transformSpecs)
        checkPrivateOutput(outPath)
        if args.contains("--wait-vocab") { setenv("SPEAKFREE_WAIT_VOCAB", "1", 1) }
        // Always score with endpointing ready (or its failure reported), never a startup race.
        setenv("SPEAKFREE_WAIT_ENDPOINTING", "1", 1)

        let items: [Item]
        do { items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: manifest))) }
        catch { fail("read manifest: \(error)") }

        FileHandle.standardError.write(Data("transcribe-batch: config dir \(Config.configDir.path), model \(model), \(items.count) takes, transforms \(transformSpecs)\n".utf8))
        let engine = ParakeetEngine()
        let loadStart = DispatchTime.now()
        do { try Benchmark.blocking { try await engine.loadModel(modelID: model) } } catch { fail("load \(model): \(error)") }
        let loadMs = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1e6
        FileHandle.standardError.write(Data(String(format: "transcribe-batch: model loaded in %.0f ms\n", loadMs).utf8))

        var results: [Result] = []
        var warmed = false
        for (i, item) in items.enumerated() {
            let samples: [Float]
            let clipped: Int
            do { (samples, clipped) = apply(transforms, to: try ProcessCommand.loadSamples(from: URL(fileURLWithPath: item.wav))) }
            catch {
                results.append(Result(id: item.id, audioSeconds: 0, clippedSamples: 0, text: "", words: 0, ms: 0,
                                      error: "decode: \(error)"))
                continue
            }
            if !warmed {
                _ = try? Benchmark.blocking { try await engine.transcribe(samples: samples, language: "en", prompt: nil, suppressRegex: nil) }
                warmed = true
            }
            let t0 = DispatchTime.now()
            var text = ""
            var err: String?
            do { text = try Benchmark.blocking { try await engine.transcribe(samples: samples, language: "en", prompt: nil, suppressRegex: nil) } }
            catch { err = "\(error)" }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            results.append(Result(id: item.id, audioSeconds: Double(samples.count) / 16_000, clippedSamples: clipped, text: text,
                                  words: words(text), ms: ms, error: err))
            if (i + 1) % 50 == 0 { FileHandle.standardError.write(Data("transcribe-batch: \(i + 1)/\(items.count)\n".utf8)) }
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(results).write(to: URL(fileURLWithPath: outPath)) } catch { fail("write \(outPath): \(error)") }
        let empty = results.filter { $0.error == nil && $0.words == 0 }.count
        let times = results.filter { $0.error == nil }.map(\.ms).sorted()
        func pct(_ p: Double) -> Double { times.isEmpty ? .nan : times[min(times.count - 1, Int(Double(times.count - 1) * p))] }
        print(String(format: "takes %d  errors %d  empty %d  engine ms p50 %.0f p90 %.0f  load %.0f ms",
                     results.count, results.filter { $0.error != nil }.count, empty, pct(0.5), pct(0.9), loadMs))
        // Non-zero when nothing could be scored, so a broken run cannot pass as a result.
        return times.isEmpty ? 1 : 0
    }
}
