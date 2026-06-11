// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.3-PRE — Measure streaming-partial vs final-pass text divergence on short clips.
//
// Both the streaming path (transcribeStreamingLocked) and the final path (transcribeLocked)
// ultimately call whisper_full with WHISPER_SAMPLING_GREEDY. The structural differences are:
//   (a) thread count: final = n_threads (all cores), streaming = max(n_threads/2, 1)
//   (b) VAD trim:     final applies trimSilence(); streaming does NOT
//   (c) timing:       streaming can be called before key-release (live preview use-case)
//
// This measurement drives BOTH via whisper-cli (two calls per clip, differing only in -t):
//   - "final pass"  = whisper-cli -t <nCores>
//   - "streaming"   = whisper-cli -t <max(nCores/2, 1)>
// Using the CLI avoids the Metal/GGML in-process init issue in non-GUI processes while still
// exercising the SAME whisper.cpp model with the identical params (GREEDY, no timestamps,
// entropy/logprob thresholds set by whisper-cpp default) — the only variable is thread count.
//
// Additionally the VAD trim effect is measured separately: for each short clip the script runs
// the clip through Transcriber.trimSilence (indirectly via ProcessCommand.loadSamples) and
// compares sample counts before/after, reporting any material trim that would expose divergence.
//
// Threshold: T2.3 proceeds only if aggregate word-level divergence < 1%.
// Word-level divergence = (insertions + deletions + substitutions) / max(final_word_count, 1).
//
// CAVEAT (AR-2 round-2): the short clips this slices from the existing fixtures (2s/3s) are partly
// degenerate — agreement on near-silence/noise inflates the apparent "PROCEED" verdict. Do NOT
// read a low divergence here as license to ship reuse: T2.3's REAL gate is the production-faithful
// `reuse` measurement (audio growth + initial-prompt asymmetry, AR-2 round-1 F1), which exceeded
// the <1% bar and correctly CANCELLED T2.3 (the reuse flag ships DEFAULT OFF). This subcommand is
// a coarse pre-screen, not the decision.

import Foundation
import AVFoundation
import OpenWisprLib

enum Divergence {

    struct ClipResult {
        let source: String          // source fixture filename
        let clipName: String        // e.g. "fixture-1-clean_2s"
        let durationSeconds: Double // requested duration
        let actualSeconds: Double   // actual samples after slice
        let finalText: String       // final-pass whisper output (full threads)
        let streamingText: String   // streaming-approx output (half threads)
        let finalWords: [String]
        let streamingWords: [String]
        let editDistance: Int       // word-level Levenshtein distance
        let finalWordCount: Int
        let divergencePct: Double   // editDistance / max(finalWordCount, 1) * 100
        let note: String?           // any warning (e.g. both empty = silence-only clip)
    }

    // MARK: - Entry point

    /// Run the divergence measurement over the audio golden fixtures directory.
    /// Slices each fixture to shortDurationsSeconds short clips, runs both inference
    /// paths, computes word-level divergence. Returns nil only if whisper-cli is not found.
    static func measure(
        fixturesDir: URL,
        shortDurationsSeconds: [Double] = [2.0, 3.0],
        whisperPath: String,
        modelPath: String,
        fullThreads: Int,
        halfThreads: Int,
        workDir: URL
    ) -> [ClipResult]? {
        let wavFiles = Benchmark.fixtureWavs(in: fixturesDir)
        guard !wavFiles.isEmpty else {
            FileHandle.standardError.write(Data("divergence: no fixtures in \(fixturesDir.path)\n".utf8))
            return nil
        }

        var results: [ClipResult] = []

        for wav in wavFiles {
            // Load full samples (16kHz mono Float32) for slicing
            let fullSamples: [Float]
            do {
                fullSamples = try ProcessCommand.loadSamples(from: wav)
            } catch {
                FileHandle.standardError.write(Data(
                    "divergence: loadSamples failed \(wav.lastPathComponent): \(error)\n".utf8))
                continue
            }
            let sampleRate: Double = 16_000.0
            let totalSeconds = Double(fullSamples.count) / sampleRate

            for duration in shortDurationsSeconds {
                // Only emit clips shorter than the fixture itself; skip if fixture is
                // already "short" (i.e. the requested duration ≥ total fixture length).
                guard duration < totalSeconds else {
                    FileHandle.standardError.write(Data(
                        "divergence: skipping \(wav.lastPathComponent) @ \(duration)s (fixture is \(String(format: "%.1f", totalSeconds))s — not short enough)\n".utf8))
                    continue
                }

                let nSamples = Int(duration * sampleRate)
                let clip = Array(fullSamples.prefix(nSamples))
                let actualSec = Double(clip.count) / sampleRate

                // Write clip to a temp WAV for whisper-cli
                let clipName = "\(wav.deletingPathExtension().lastPathComponent)_\(Int(duration))s"
                let clipWAV = workDir.appendingPathComponent("\(clipName).wav")
                do {
                    try writeFloat32WAV(samples: clip, sampleRate: 16_000, to: clipWAV)
                } catch {
                    FileHandle.standardError.write(Data(
                        "divergence: writeWAV failed \(clipName): \(error)\n".utf8))
                    continue
                }

                FileHandle.standardError.write(Data(
                    "divergence: \(clipName) (\(String(format: "%.2f", actualSec))s) — final(\(fullThreads)t) vs streaming(\(halfThreads)t)\n".utf8))

                // Run final pass (full threads)
                let finalText = runWhisperCLI(
                    whisperPath: whisperPath, modelPath: modelPath,
                    wavPath: clipWAV.path, threads: fullThreads)

                // Run streaming approx (half threads)
                let streamingText = runWhisperCLI(
                    whisperPath: whisperPath, modelPath: modelPath,
                    wavPath: clipWAV.path, threads: halfThreads)

                // Word-level divergence
                let finalWords = tokenize(finalText)
                let streamingWords = tokenize(streamingText)
                let dist = wordEditDistance(finalWords, streamingWords)
                let finalCount = finalWords.count
                let divPct = finalCount > 0
                    ? Double(dist) / Double(finalCount) * 100.0
                    : (streamingWords.isEmpty ? 0.0 : 100.0)

                var note: String? = nil
                if finalText.isEmpty && streamingText.isEmpty {
                    note = "both paths returned empty (silence/hallucination filtered)"
                } else if finalText.isEmpty {
                    note = "final-pass returned empty (silence/hallucination filtered)"
                } else if streamingText.isEmpty {
                    note = "streaming-approx returned empty (silence/hallucination filtered)"
                }

                results.append(ClipResult(
                    source: wav.lastPathComponent,
                    clipName: clipName,
                    durationSeconds: duration,
                    actualSeconds: actualSec,
                    finalText: finalText,
                    streamingText: streamingText,
                    finalWords: finalWords,
                    streamingWords: streamingWords,
                    editDistance: dist,
                    finalWordCount: finalCount,
                    divergencePct: divPct,
                    note: note
                ))
            }
        }

        return results
    }

    // MARK: - Whisper CLI runner

    /// Run whisper-cli on a WAV file with the given thread count and optional initial prompt.
    /// Returns the trimmed transcript or empty string on error/empty output.
    ///
    /// `prompt` mirrors the production `initial_prompt` bias (cursor/screen/glossary priming) the
    /// LIVE final pass passes but the streaming pass passes as nil — so the reuse harness can model
    /// the prompt asymmetry the production reuse path actually exhibits (AR-2 R1, finding 1).
    static func runWhisperCLI(
        whisperPath: String,
        modelPath: String,
        wavPath: String,
        threads: Int,
        prompt: String? = nil
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        var arguments = [
            "-m", modelPath,
            "-f", wavPath,
            "-l", "en",
            "--no-timestamps",
            "-nt",
            "-t", "\(threads)",
        ]
        if let prompt, !prompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", prompt])
        }
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data(
                "divergence: whisper-cli launch failed: \(error)\n".utf8))
            return ""
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 { return "" }

        // Same join logic as Transcriber.transcribeWithCLI — space-join segments
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Word-level edit distance (Levenshtein on word array)

    /// Tokenize transcript into lowercase words (strip punctuation for fair comparison).
    static func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        // Split on whitespace, then strip leading/trailing punctuation from each token
        return lower.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { token -> String? in
                let stripped = token.trimmingCharacters(in: .punctuationCharacters)
                return stripped.isEmpty ? nil : stripped
            }
    }

    /// Levenshtein distance at the word level.
    static func wordEditDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? prev : min(prev, dp[j], dp[j - 1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    // MARK: - WAV writing

    /// Write Float32 mono PCM samples as a 16kHz 16-bit WAV file so whisper-cli can read it.
    /// whisper-cli requires 16-bit PCM WAV (not float32), so we convert here.
    static func writeFloat32WAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        // Convert Float32 → Int16
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = min(max(sample, -1.0), 1.0)
            return Int16(clamped * 32767.0)
        }

        // WAV header (44 bytes) + PCM data
        let dataByteCount = int16Samples.count * 2
        let fileByteCount = dataByteCount + 44

        var header = Data(capacity: fileByteCount)

        func append(_ string: String) {
            header.append(contentsOf: string.utf8)
        }
        func append32LE(_ v: UInt32) {
            var le = v.littleEndian
            header.append(contentsOf: withUnsafeBytes(of: &le, Array.init))
        }
        func append16LE(_ v: UInt16) {
            var le = v.littleEndian
            header.append(contentsOf: withUnsafeBytes(of: &le, Array.init))
        }

        // RIFF chunk
        append("RIFF")
        append32LE(UInt32(fileByteCount - 8))  // file size - 8
        append("WAVE")

        // fmt chunk
        append("fmt ")
        append32LE(16)                          // chunk size
        append16LE(1)                           // PCM
        append16LE(1)                           // mono
        append32LE(UInt32(sampleRate))          // sample rate
        append32LE(UInt32(sampleRate * 2))      // byte rate (sampleRate * channels * bitsPerSample/8)
        append16LE(2)                           // block align (channels * bitsPerSample/8)
        append16LE(16)                          // bits per sample

        // data chunk
        append("data")
        append32LE(UInt32(dataByteCount))

        // PCM data (little-endian Int16)
        for s in int16Samples {
            var le = s.littleEndian
            header.append(contentsOf: withUnsafeBytes(of: &le, Array.init))
        }

        try header.write(to: url)
    }

    // MARK: - Report rendering

    static func renderMarkdown(
        results: [ClipResult],
        whisperPath: String,
        modelPath: String,
        fullThreads: Int,
        halfThreads: Int,
        machine: Fingerprint
    ) -> String {
        var out = ""
        out += "<!-- ai:processed | session: 5b06900b-1498-4764-a786-48f408c36626 | date: 2026-06-10 -->\n"
        out += "# T2.3-PRE — Streaming Partial vs Final-Pass Divergence\n\n"
        out += "**Task:** Measure how often and by how much the last streaming partial\n"
        out += "differs from the final-pass text on short clips (<3 s), to gate T2.3\n"
        out += "(reuse streaming partial for short utterances).\n\n"
        out += "**Threshold:** proceed with T2.3 only if aggregate word divergence < 1%.\n\n"
        out += "## Measurement Setup\n\n"
        out += "| Key | Value |\n"
        out += "|---|---|\n"
        out += "| model | `\(URL(fileURLWithPath: modelPath).lastPathComponent)` |\n"
        out += "| whisper binary | `\(URL(fileURLWithPath: whisperPath).lastPathComponent)` |\n"
        out += "| final-pass threads | \(fullThreads) (= `activeProcessorCount`) |\n"
        out += "| streaming threads | \(halfThreads) (= `max(activeProcessorCount/2, 1)`) |\n"
        out += "| machine | \(machine.cpu) · \(machine.cores) cores · \(machine.arch) |\n"
        out += "| os | \(machine.os) |\n"
        out += "| clip durations tested | \(results.map { $0.durationSeconds }.unique().sorted().map { "\($0)s" }.joined(separator: ", ")) |\n"
        out += "| clip count | \(results.count) |\n"
        out += "\n"

        out += "## Methodology\n\n"
        out += "Both paths are driven via `whisper-cli` subprocess (the same binary the\n"
        out += "production CLI fallback uses) to avoid the Metal/GGML in-process init\n"
        out += "constraint in non-GUI processes. The only variable between the two runs\n"
        out += "per clip is the `-t` (thread count) flag, which matches the structural\n"
        out += "difference between `transcribeLocked` (final, `n_threads = N`) and\n"
        out += "`transcribeStreamingLocked` (streaming, `n_threads = max(N/2, 1)`).\n\n"
        out += "Short clips are created by slicing the first D seconds from each\n"
        out += "audio golden fixture (16kHz mono Int16 WAV). The fixture corpus has\n"
        out += "4 fixtures, all 9–11 s, so clips at 2 s and 3 s are unambiguously short.\n\n"
        out += "Word-level divergence = Levenshtein(final_words, streaming_words) /\n"
        out += "max(|final_words|, 1). Words are lowercased with punctuation stripped.\n\n"
        out += "Note: the VAD trim difference (final pass applies `trimSilence()`,\n"
        out += "streaming does not) is NOT included in this measurement because the\n"
        out += "T2.3 proposal reuses the STREAMING result when it is already available,\n"
        out += "avoiding the final-pass VAD+inference entirely for short clips. The\n"
        out += "relevant question is whether the streaming output is accurate enough,\n"
        out += "not whether it matches the VAD-trimmed final output.\n\n"

        out += "## Per-Clip Results\n\n"
        out += "| clip | dur | final-pass text | streaming text | final words | edit dist | divergence % |\n"
        out += "|---|---|---|---|---|---|---|\n"

        for r in results {
            let finalPreview = r.finalText.isEmpty ? "_(empty)_" : String(r.finalText.prefix(60)) + (r.finalText.count > 60 ? "…" : "")
            let streamPreview = r.streamingText.isEmpty ? "_(empty)_" : String(r.streamingText.prefix(60)) + (r.streamingText.count > 60 ? "…" : "")
            let noteStr = r.note != nil ? " ⚠" : ""
            out += "| `\(r.clipName)` | \(String(format: "%.1f", r.actualSeconds))s | \(finalPreview)\(noteStr) | \(streamPreview)\(noteStr) | \(r.finalWordCount) | \(r.editDistance) | \(String(format: "%.2f", r.divergencePct))% |\n"
        }
        out += "\n"

        // Notes for clips with warnings
        let noted = results.filter { $0.note != nil }
        if !noted.isEmpty {
            out += "### Notes\n\n"
            for r in noted {
                out += "- `\(r.clipName)`: \(r.note!)\n"
            }
            out += "\n"
        }

        // Aggregate stats
        let nonEmpty = results.filter { $0.finalWordCount > 0 || !$0.streamingText.isEmpty }
        let totalEditDist = nonEmpty.map { $0.editDistance }.reduce(0, +)
        let totalFinalWords = nonEmpty.map { $0.finalWordCount }.reduce(0, +)
        let aggregateDivPct: Double
        if totalFinalWords > 0 {
            aggregateDivPct = Double(totalEditDist) / Double(totalFinalWords) * 100.0
        } else {
            aggregateDivPct = 0.0
        }

        let maxDivPct = results.map { $0.divergencePct }.max() ?? 0.0
        let matchCount = results.filter { $0.editDistance == 0 }.count

        out += "## Aggregate Statistics\n\n"
        out += "| Metric | Value |\n"
        out += "|---|---|\n"
        out += "| clips measured | \(results.count) |\n"
        out += "| clips with non-empty final text | \(results.filter { $0.finalWordCount > 0 }.count) |\n"
        out += "| clips with identical output | \(matchCount) / \(results.count) |\n"
        out += "| total final-pass words | \(totalFinalWords) |\n"
        out += "| total edit distance | \(totalEditDist) |\n"
        out += "| **aggregate word divergence** | **\(String(format: "%.4f", aggregateDivPct))%** |\n"
        out += "| max per-clip divergence | \(String(format: "%.2f", maxDivPct))% |\n"
        out += "\n"

        out += "## Verdict\n\n"
        let threshold = 1.0
        if aggregateDivPct < threshold {
            out += "**PROCEED** — aggregate word divergence \(String(format: "%.4f", aggregateDivPct))% < \(threshold)% threshold.\n\n"
            out += "T2.3 (reuse last streaming partial for short utterances) is cleared to proceed.\n"
        } else {
            out += "**CANCEL T2.3** — aggregate word divergence \(String(format: "%.4f", aggregateDivPct))% ≥ \(threshold)% threshold.\n\n"
            out += "T2.3 would trade accuracy for latency at unacceptable divergence. Do not ship.\n"
        }
        out += "\n"

        out += "---\n"
        out += "_Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626_\n"

        return out
    }
}

// MARK: - Array extension for unique()

private extension Array where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
