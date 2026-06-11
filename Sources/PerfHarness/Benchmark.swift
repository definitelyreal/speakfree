// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.0 — The benchmark runner. Drives the SAME production seams the app uses:
//   * ProcessCommand.loadSamples  — decode wav → 16 kHz mono Float32 (the engine audio currency)
//   * Transcriber.transcribe      — the in-process engine path (whisper.cpp / Parakeet-CoreML),
//                                   identical to AppDelegate.finalizeRecording's transcription
//   * TextPipeline.run            — the post-processing the app runs before insertion
//
// Per fixture we measure, over ≥5 iterations (median reported):
//   inferenceMs — engine wall-clock only
//   endToEndMs  — simulated key-release → text-ready:
//                   postBuffer (flat 300 ms today; the T2.1 target to shrink)
//                 + inference
//                 + TextPipeline post-processing
//                 + the inserter's shouldPrependSpace gate is NOT included (headless: no AX cursor)
//
// The first ("warm-up") iteration is run and DISCARDED before timing so cold model-load /
// Metal-pipeline / ANE-compile cost doesn't pollute the steady-state median.

import Foundation
import OpenWisprLib

enum Benchmark {

    /// The post-key-release CAP (worst case). PLAN T2.1: the FLAT policy always pays this; the
    /// ADAPTIVE policy stops on ~150ms trailing silence and only pays up to this cap. The harness
    /// records the per-fixture wait so the adaptive win shows up in endToEnd medians.
    static let postBufferMs: Double = PostBufferPolicy.defaultCapMs

    /// Post-key-release buffer policy under test.
    enum PostBuffer: String {
        case flat       // legacy 300ms tax on every dictation (the BEFORE baseline)
        case adaptive   // stop on ~150ms trailing silence, hard cap 300ms (T2.1)
    }

    /// The trailing-audio window the live app actually polls after key release: the LAST `capMs`
    /// of the recording approximates the tail captured between key-release and finalize. The
    /// adaptive policy is scored over exactly this slice via the SAME PostBufferPolicy the app uses.
    static func adaptiveBufferMs(forSamples samples: [Float], sampleRate: Double = 16_000.0) -> Double {
        let capMs = PostBufferPolicy.defaultCapMs
        let tailSamples = Int((capMs / 1000.0) * sampleRate)
        let tail = samples.count > tailSamples ? Array(samples.suffix(tailSamples)) : samples
        return PostBufferPolicy.decideWaitMs(trailingSamples: tail, sampleRate: sampleRate)
    }

    struct EngineSpec {
        let engineID: String     // "whisper" | "parakeet"
        let model: String        // "tiny.en" | "parakeet-tdt-0.6b-v3"
        let language: String
    }

    /// Resolve the fixtures directory (Tests/OpenWisprTests/AudioFixtures) relative to the repo
    /// root. The harness binary lives in .build/…; we locate the repo by walking up from the
    /// source file path, then fall back to CWD.
    static func fixturesDir() -> URL {
        // #filePath = …/Sources/PerfHarness/Benchmark.swift → repo root is 3 levels up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PerfHarness
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
        let fromSource = repoRoot
            .appendingPathComponent("Tests/OpenWisprTests/AudioFixtures")
        if FileManager.default.fileExists(atPath: fromSource.path) { return fromSource }
        // Fallback: CWD-relative (when run from the repo root).
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/OpenWisprTests/AudioFixtures")
    }

    static func fixtureWavs(in dir: URL) -> [URL] {
        let manifest = dir.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let names = arr.compactMap { $0["wav"] as? String }
            if !names.isEmpty {
                return names.map { dir.appendingPathComponent($0) }
            }
        }
        // Fallback: any *.wav in the directory, sorted.
        let all = (try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.path < $1.path }
    }

    /// Run the benchmark for one engine over all fixtures. `iterations` is the number of TIMED
    /// iterations (a warm-up iteration is run and discarded first). Returns nil if the engine's
    /// model isn't available (so callers can skip parakeet when its CoreML assets are absent).
    static func runEngine(_ spec: EngineSpec, fixtures: [URL], iterations: Int,
                          postBuffer: PostBuffer = .flat) -> EngineReport? {
        precondition(iterations >= 5, "T2.0 requires medians over ≥5 iterations")

        let engine = EngineFactory.make(config: configForEngine(spec))
        // Guard: confirm the engine id we got matches what we asked for (env override safety).
        guard engine.engineID == spec.engineID else {
            FileHandle.standardError.write(Data(
                "perf-harness: engine factory returned \(engine.engineID), expected \(spec.engineID)\n".utf8))
            return nil
        }
        let transcriber = Transcriber(engine: engine, modelID: spec.model, language: spec.language)

        // Whisper's in-process ggml/Metal backend cannot init a device outside the GUI app
        // process (devices=0 → GGML_ABORT), exactly as ProcessCommand documents. So for whisper
        // we drive the SAME production fallback the golden tests + `process` command use: the
        // whisper-cli subprocess (samples=nil → Transcriber.transcribeWithCLI), which runs the
        // identical whisper.cpp model where the device IS available. Parakeet runs in-process on
        // the ANE (samples required) and works here.
        let usesInProcessSamples = spec.engineID == "parakeet"

        var fixtureResults: [FixtureResult] = []

        for wav in fixtures {
            guard FileManager.default.fileExists(atPath: wav.path) else {
                FileHandle.standardError.write(Data("perf-harness: missing fixture \(wav.lastPathComponent)\n".utf8))
                return nil
            }
            let samples: [Float]
            do {
                samples = try ProcessCommand.loadSamples(from: wav)
            } catch {
                FileHandle.standardError.write(Data("perf-harness: decode failed \(wav.lastPathComponent): \(error)\n".utf8))
                return nil
            }
            guard !samples.isEmpty else {
                FileHandle.standardError.write(Data("perf-harness: empty samples \(wav.lastPathComponent)\n".utf8))
                return nil
            }
            let audioSeconds = Double(samples.count) / 16_000.0
            // Whisper → CLI path (samples=nil); Parakeet → in-process ANE (samples required).
            let transcribeSamples: [Float]? = usesInProcessSamples ? samples : nil

            // T2.1 — the post-key-release wait baked into THIS fixture's e2e. Flat = the 300ms cap
            // on every dictation; adaptive = the SAME PostBufferPolicy decision the app runs over
            // this fixture's trailing audio (≤cap). The fixture's tail stands in for the live tail
            // captured between key-release and finalize.
            let fixtureBufferMs: Double = (postBuffer == .adaptive)
                ? adaptiveBufferMs(forSamples: samples)
                : postBufferMs

            // Warm-up (discarded): cold model load / Metal-pipeline / ANE compile.
            var lastTranscript = ""
            do {
                lastTranscript = try blocking {
                    try await transcriber.transcribe(audioURL: wav, samples: transcribeSamples, prompt: nil)
                }
            } catch {
                FileHandle.standardError.write(Data("perf-harness: warm-up transcribe failed \(wav.lastPathComponent): \(error)\n".utf8))
                return nil
            }

            var inferenceSamplesMs: [Double] = []
            var endToEndSamplesMs: [Double] = []

            for _ in 0..<iterations {
                // --- inference (engine only) ---
                let t0 = DispatchTime.now()
                let raw: String
                do {
                    raw = try blocking {
                        try await transcriber.transcribe(audioURL: wav, samples: transcribeSamples, prompt: nil)
                    }
                } catch {
                    FileHandle.standardError.write(Data("perf-harness: transcribe failed \(wav.lastPathComponent): \(error)\n".utf8))
                    return nil
                }
                let inferenceMs = elapsedMs(since: t0)
                lastTranscript = raw

                // --- post-processing (TextPipeline, the app's pre-insertion path) ---
                let p0 = DispatchTime.now()
                let input = TextPipeline.Input(raw: raw, punctuationMode: .hybrid)
                _ = TextPipeline.run(input).finalText
                let postProcMs = elapsedMs(since: p0)

                inferenceSamplesMs.append(inferenceMs)
                // Simulated key-release → text-ready latency (per-fixture post-buffer + infer + post).
                endToEndSamplesMs.append(fixtureBufferMs + inferenceMs + postProcMs)
            }

            fixtureResults.append(FixtureResult(
                fixture: wav.lastPathComponent,
                audioSeconds: audioSeconds,
                transcript: lastTranscript,
                inferenceMs: Stat(samplesMs: inferenceSamplesMs),
                endToEndMs: Stat(samplesMs: endToEndSamplesMs),
                postBufferMs: fixtureBufferMs
            ))
        }

        // Release the model so a subsequent engine (parakeet after whisper) starts clean.
        blockingVoid { await transcriber.unloadModel() }

        guard !fixtureResults.isEmpty else { return nil }
        return EngineReport(
            engine: spec.engineID,
            model: spec.model,
            postBufferMs: postBufferMs,
            postBufferPolicy: postBuffer.rawValue,
            fixtures: fixtureResults
        )
    }

    // MARK: - Config + concurrency bridges

    /// Build a Config that pins the requested model/engine. We don't read the user's config
    /// (which may point at base.en / parakeet) — the harness must be deterministic.
    private static func configForEngine(_ spec: EngineSpec) -> Config {
        var cfg = Config.load()
        cfg.engine = spec.engineID
        cfg.modelSize = spec.model
        cfg.parakeetModel = spec.engineID == "parakeet" ? spec.model : cfg.parakeetModel
        cfg.language = spec.language
        // EngineFactory honors SPEAKFREE_ENGINE ahead of config.engine; clear it so the
        // per-spec config.engine wins regardless of the ambient environment.
        unsetenv("SPEAKFREE_ENGINE")
        return cfg
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(ns) / 1_000_000.0
    }

    /// Run an async throwing closure to completion from this synchronous harness.
    static func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    static func blockingVoid(_ work: @escaping () async -> Void) {
        let sem = DispatchSemaphore(value: 0)
        Task { await work(); sem.signal() }
        sem.wait()
    }
}
