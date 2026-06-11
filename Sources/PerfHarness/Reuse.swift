// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.3 — Reuse-last-streaming-partial harness.
//
// Proves the two T2.3 acceptance claims over the short-clip corpus, with numbers (not vibes):
//
//   (1) NEAR-ZERO FINAL INFERENCE on a reuse. For each short clip we time, over ≥5 iterations:
//         finalInferMs — a fresh final whisper pass (whisper-cli, full threads = what T2.3 SKIPS)
//         reuseMs      — the reuse path's only work: TextPipeline.run over the saved partial
//                        (no engine call at all)
//       reuseMs being a tiny fraction of finalInferMs IS the latency win: the reuse path elides
//       the entire final inference.
//
//   (2) CORPUS ACCURACY DELTA < 1%. The reuse path inserts the STREAMING partial (half threads),
//       the final path inserts the FINAL pass (full threads) — both routed through the IDENTICAL
//       TextPipeline.run. We compute word-level divergence between the two FINAL (post-pipeline)
//       texts, aggregated over the corpus. This is the accuracy cost of reusing.
//
// Both inference paths are driven via whisper-cli (the production CLI fallback) to avoid the
// in-process Metal/GGML init constraint in non-GUI processes — identical to the T2.3-PRE
// Divergence measurement, the only structural variable being thread count (final = N cores,
// streaming = max(N/2, 1)), which mirrors transcribeLocked vs transcribeStreamingLocked.

import Foundation
import OpenWisprLib

enum Reuse {

    struct ClipResult {
        let clipName: String
        let actualSeconds: Double

        // (1) latency win
        let finalInferMedianMs: Double   // median fresh final-pass wall-clock (what reuse skips)
        let reuseMedianMs: Double        // median reuse-path work (TextPipeline only)
        let speedupX: Double             // finalInferMedianMs / max(reuseMedianMs, ε)

        // (2) accuracy delta — both texts post-TextPipeline
        let finalPipelineText: String    // final-pass raw → TextPipeline.run
        let reusePipelineText: String    // streaming-partial raw → TextPipeline.run
        let editDistance: Int            // word-level Levenshtein
        let finalWordCount: Int
        let divergencePct: Double        // editDistance / max(finalWordCount,1) * 100
    }

    /// Run the reuse measurement over the audio golden fixtures, slicing each to short clips.
    static func measure(
        fixturesDir: URL,
        shortDurationsSeconds: [Double] = [2.0, 3.0],
        iterations: Int,
        whisperPath: String,
        modelPath: String,
        fullThreads: Int,
        halfThreads: Int,
        workDir: URL
    ) -> [ClipResult]? {
        let wavFiles = Benchmark.fixtureWavs(in: fixturesDir)
        guard !wavFiles.isEmpty else {
            FileHandle.standardError.write(Data("reuse: no fixtures in \(fixturesDir.path)\n".utf8))
            return nil
        }

        // Pipeline input shape identical to AppDelegate.finalizeRecording (hybrid punctuation,
        // no glossary/context) so the post-processing matches production for both texts.
        func runPipeline(_ raw: String) -> String {
            let input = TextPipeline.Input(raw: raw, punctuationMode: .hybrid)
            return TextPipeline.run(input).finalText
        }

        var results: [ClipResult] = []

        for wav in wavFiles {
            let fullSamples: [Float]
            do {
                fullSamples = try ProcessCommand.loadSamples(from: wav)
            } catch {
                FileHandle.standardError.write(Data("reuse: loadSamples failed \(wav.lastPathComponent): \(error)\n".utf8))
                continue
            }
            let sampleRate = 16_000.0
            let totalSeconds = Double(fullSamples.count) / sampleRate

            for duration in shortDurationsSeconds {
                guard duration < totalSeconds else {
                    FileHandle.standardError.write(Data(
                        "reuse: skipping \(wav.lastPathComponent) @ \(duration)s (fixture is \(String(format: "%.1f", totalSeconds))s)\n".utf8))
                    continue
                }

                let nSamples = Int(duration * sampleRate)
                let clip = Array(fullSamples.prefix(nSamples))
                let actualSec = Double(clip.count) / sampleRate
                let clipName = "\(wav.deletingPathExtension().lastPathComponent)_\(Int(duration))s"
                let clipWAV = workDir.appendingPathComponent("\(clipName).wav")
                do {
                    try Divergence.writeFloat32WAV(samples: clip, sampleRate: 16_000, to: clipWAV)
                } catch {
                    FileHandle.standardError.write(Data("reuse: writeWAV failed \(clipName): \(error)\n".utf8))
                    continue
                }

                FileHandle.standardError.write(Data(
                    "reuse: \(clipName) (\(String(format: "%.2f", actualSec))s) — timing final(\(fullThreads)t) vs reuse over \(iterations) iters\n".utf8))

                // --- One streaming-pass (half threads) and one final-pass (full threads) text. ---
                let streamingRaw = Divergence.runWhisperCLI(
                    whisperPath: whisperPath, modelPath: modelPath, wavPath: clipWAV.path, threads: halfThreads)
                let finalRaw = Divergence.runWhisperCLI(
                    whisperPath: whisperPath, modelPath: modelPath, wavPath: clipWAV.path, threads: fullThreads)

                let finalPipelineText = runPipeline(finalRaw)
                let reusePipelineText = runPipeline(streamingRaw)

                // (2) accuracy delta on the POST-PIPELINE texts.
                let finalWords = Divergence.tokenize(finalPipelineText)
                let reuseWords = Divergence.tokenize(reusePipelineText)
                let dist = Divergence.wordEditDistance(finalWords, reuseWords)
                let finalCount = finalWords.count
                let divPct = finalCount > 0
                    ? Double(dist) / Double(finalCount) * 100.0
                    : (reuseWords.isEmpty ? 0.0 : 100.0)

                // --- (1) latency: median over `iterations` of (final whisper pass) vs (reuse = TextPipeline only). ---
                // Warm-up final pass discarded (cold model load / Metal pipeline).
                _ = Divergence.runWhisperCLI(whisperPath: whisperPath, modelPath: modelPath,
                                             wavPath: clipWAV.path, threads: fullThreads)
                var finalMs: [Double] = []
                var reuseMs: [Double] = []
                for _ in 0..<iterations {
                    let f0 = DispatchTime.now()
                    _ = Divergence.runWhisperCLI(whisperPath: whisperPath, modelPath: modelPath,
                                                 wavPath: clipWAV.path, threads: fullThreads)
                    finalMs.append(elapsedMs(since: f0))

                    // The reuse path's ENTIRE work: route the saved partial through TextPipeline.
                    // No engine call — this is exactly what AppDelegate does on a reuse.
                    let r0 = DispatchTime.now()
                    _ = runPipeline(streamingRaw)
                    reuseMs.append(elapsedMs(since: r0))
                }
                let finalMed = median(finalMs)
                let reuseMed = median(reuseMs)
                let speedup = finalMed / Swift.max(reuseMed, 0.0001)

                results.append(ClipResult(
                    clipName: clipName,
                    actualSeconds: actualSec,
                    finalInferMedianMs: finalMed,
                    reuseMedianMs: reuseMed,
                    speedupX: speedup,
                    finalPipelineText: finalPipelineText,
                    reusePipelineText: reusePipelineText,
                    editDistance: dist,
                    finalWordCount: finalCount,
                    divergencePct: divPct
                ))
            }
        }

        return results
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    // MARK: - Report rendering

    static func renderMarkdown(
        results: [ClipResult],
        iterations: Int,
        whisperPath: String,
        modelPath: String,
        fullThreads: Int,
        halfThreads: Int,
        machine: Fingerprint
    ) -> String {
        var out = ""
        out += "<!-- ai:processed | session: 5b06900b-1498-4764-a786-48f408c36626 | date: 2026-06-10 -->\n"
        out += "# T2.3 — Reuse Last Streaming Partial: Latency + Accuracy\n\n"
        out += "**Task:** prove (1) reusing the last streaming partial gives near-zero final-inference\n"
        out += "latency for short clips, and (2) the corpus accuracy delta (reused-partial vs final-pass\n"
        out += "text, both through TextPipeline) is < 1%.\n\n"

        out += "## Setup\n\n"
        out += "| Key | Value |\n|---|---|\n"
        out += "| model | `\(URL(fileURLWithPath: modelPath).lastPathComponent)` |\n"
        out += "| whisper binary | `\(URL(fileURLWithPath: whisperPath).lastPathComponent)` |\n"
        out += "| final-pass threads | \(fullThreads) (= `activeProcessorCount`) |\n"
        out += "| streaming threads | \(halfThreads) (= `max(activeProcessorCount/2, 1)`) |\n"
        out += "| iterations (median) | \(iterations) |\n"
        out += "| machine | \(machine.cpu) · \(machine.cores) cores · \(machine.arch) |\n"
        out += "| os | \(machine.os) |\n"
        out += "| clip count | \(results.count) |\n\n"

        out += "## (1) Latency — final inference SKIPPED on reuse\n\n"
        out += "`final infer` = a fresh whisper pass (what T2.3 elides). `reuse` = the reuse path's\n"
        out += "only work (TextPipeline.run over the saved partial; no engine). Medians over \(iterations) iters.\n\n"
        out += "| clip | dur | final infer (median ms) | reuse (median ms) | speedup |\n"
        out += "|---|---|---|---|---|\n"
        for r in results {
            out += "| `\(r.clipName)` | \(String(format: "%.1f", r.actualSeconds))s | \(String(format: "%.1f", r.finalInferMedianMs)) | \(String(format: "%.3f", r.reuseMedianMs)) | \(String(format: "%.0f", r.speedupX))× |\n"
        }
        let finalMedians = results.map { $0.finalInferMedianMs }.sorted()
        let reuseMedians = results.map { $0.reuseMedianMs }.sorted()
        let aggFinal = finalMedians.isEmpty ? 0 : Stat.medianOf(finalMedians)
        let aggReuse = reuseMedians.isEmpty ? 0 : Stat.medianOf(reuseMedians)
        out += "\n"
        out += "Aggregate median final inference: **\(String(format: "%.1f", aggFinal)) ms** "
        out += "→ reuse: **\(String(format: "%.3f", aggReuse)) ms** "
        out += "(**\(String(format: "%.0f", aggFinal / Swift.max(aggReuse, 0.0001)))× faster**; the entire final pass is skipped).\n\n"

        out += "## (2) Accuracy delta — reused-partial vs final-pass text (post-TextPipeline)\n\n"
        out += "Word-level divergence between the two FINAL texts. Threshold: < 1% aggregate.\n\n"
        out += "| clip | final-pipeline text | reuse-pipeline text | final words | edit dist | divergence % |\n"
        out += "|---|---|---|---|---|---|\n"
        for r in results {
            let fp = r.finalPipelineText.isEmpty ? "_(empty)_" : String(r.finalPipelineText.prefix(48)) + (r.finalPipelineText.count > 48 ? "…" : "")
            let rp = r.reusePipelineText.isEmpty ? "_(empty)_" : String(r.reusePipelineText.prefix(48)) + (r.reusePipelineText.count > 48 ? "…" : "")
            out += "| `\(r.clipName)` | \(fp) | \(rp) | \(r.finalWordCount) | \(r.editDistance) | \(String(format: "%.2f", r.divergencePct))% |\n"
        }
        out += "\n"

        let totalEdit = results.map { $0.editDistance }.reduce(0, +)
        let totalWords = results.map { $0.finalWordCount }.reduce(0, +)
        let aggDiv = totalWords > 0 ? Double(totalEdit) / Double(totalWords) * 100.0 : 0.0
        let identical = results.filter { $0.editDistance == 0 }.count

        out += "## Aggregate\n\n"
        out += "| Metric | Value |\n|---|---|\n"
        out += "| clips measured | \(results.count) |\n"
        out += "| clips with identical post-pipeline text | \(identical) / \(results.count) |\n"
        out += "| total final-pass words | \(totalWords) |\n"
        out += "| total edit distance | \(totalEdit) |\n"
        out += "| **aggregate accuracy delta** | **\(String(format: "%.4f", aggDiv))%** |\n\n"

        out += "## Verdict\n\n"
        if aggDiv < 1.0 {
            out += "**PASS** — aggregate accuracy delta \(String(format: "%.4f", aggDiv))% < 1% AND reuse skips the final inference "
            out += "(aggregate \(String(format: "%.1f", aggFinal)) ms → \(String(format: "%.3f", aggReuse)) ms). Both T2.3 acceptance claims met.\n"
        } else {
            out += "**FAIL** — aggregate accuracy delta \(String(format: "%.4f", aggDiv))% ≥ 1%. Reuse trades too much accuracy; do not ship.\n"
        }
        out += "\n---\n"
        out += "_Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626_\n"
        return out
    }
}
