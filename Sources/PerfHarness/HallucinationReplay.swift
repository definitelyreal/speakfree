// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-10-04
//
// Replays WhisperHallucinationGuard over archived takes, with the production code.
//
// Manifest: JSON array of {"id": String, "wav": path, "cases": [{"name": String,
// "whisper": String, "parakeet": String or null}]}. Each case asks: if Whisper had returned
// `whisper` on this audio and Parakeet `parakeet`, would the guard refuse it?
// Output JSON: per take the audio verdict, per case block and reason. No text is copied into
// the output, but the manifest holds dictation text: keep both out of the repository.

import Foundation
import SpeakFreeLib

enum HallucinationReplay {
    struct Case: Decodable {
        let name: String
        let whisper: String
        let parakeet: String?
    }

    struct Take: Decodable {
        let id: String
        let wav: String
        let cases: [Case]
    }

    struct CaseResult: Encodable {
        let name: String
        let block: Bool
        let reason: String?
    }

    struct TakeResult: Encodable {
        let id: String
        let seconds: Double
        let floorRMS: Float
        let speechBandRange: Float
        let isStatic: Bool
        let noiseOnly: Bool
        let leansNoise: Bool
        let cases: [CaseResult]
        var error: String?
    }

    static func run(args: [String]) -> Int32 {
        guard args.count >= 2 else {
            print("usage: perf-harness hallucination-replay <manifest.json> <out.json>")
            return 2
        }
        let takes: [Take]
        do {
            takes = try JSONDecoder().decode([Take].self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
        } catch {
            print("hallucination-replay: cannot read manifest \(args[0]): \(error)")
            return 1
        }
        var results: [TakeResult] = []
        results.reserveCapacity(takes.count)
        for (index, take) in takes.enumerated() {
            let samples: [Float]
            do { samples = try ProcessCommand.loadSamples(from: URL(fileURLWithPath: take.wav)) } catch {
                results.append(TakeResult(id: take.id, seconds: 0, floorRMS: 0, speechBandRange: 0, isStatic: false,
                                          noiseOnly: false, leansNoise: false, cases: [], error: "\(error)"))
                continue
            }
            let noise = WhisperHallucinationGuard.noiseVerdict(samples)
            let cases = take.cases.map { item -> CaseResult in
                let verdict = WhisperHallucinationGuard.assess(
                    whisperText: item.whisper, noise: noise, parakeetText: item.parakeet)
                return CaseResult(name: item.name, block: verdict.block, reason: verdict.reason)
            }
            results.append(TakeResult(id: take.id, seconds: noise.seconds, floorRMS: noise.floorRMS,
                                      speechBandRange: noise.speechBandRange, isStatic: noise.isStatic,
                                      noiseOnly: noise.isNoiseOnly, leansNoise: noise.leansNoise, cases: cases))
            if (index + 1) % 1000 == 0 { print("hallucination-replay: \(index + 1)/\(takes.count)") }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: args[1]))
        } catch {
            print("hallucination-replay: cannot write \(args[1]): \(error)")
            return 1
        }
        print("hallucination-replay: \(results.count) takes written to \(args[1])")
        return 0
    }
}
