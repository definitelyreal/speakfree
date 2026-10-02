// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import FluidAudio
import XCTest
@testable import SpeakFreeLib

/// Opt-in local model test: public synthetic audio only, existing CTC cache only, no download.
/// Timings are diagnostics on the executing host, never performance assertions or baselines.
final class VocabularyBoostProbabilityParityTests: XCTestCase {
    func test_cachedCTC_probabilitiesAndCorrectionsMatch_withoutUnusedKeywordSpotting() async throws {
        guard ProcessInfo.processInfo.environment["SPEAKFREE_CTC_PARITY_TESTS"] == "1" else {
            throw XCTSkip("Set SPEAKFREE_CTC_PARITY_TESTS=1 for cached-model synthetic parity")
        }
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard CtcModels.modelsExist(at: directory) else {
            throw XCTSkip("Existing CTC cache required; this test never downloads models")
        }
        let models = try await CtcModels.loadDirect(from: directory)
        let spotter = CtcKeywordSpotter(models: models)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        var specs = [VocabularyBoost.TermSpec(text: "Robot", aliases: ["robut"])]
        for color in ["Amber", "Azure", "Coral", "Silver", "Golden", "Violet"] {
            for object in ["Garden", "Harbor", "Planet", "Forest", "Lantern", "Valley"] {
                specs.append(.init(text: color + object))
            }
        }
        let vocabulary = VocabularyBoost.makeContext(specs: specs, tokenizer: tokenizer)
        XCTAssertEqual(vocabulary.terms.count, 37)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocabulary, ctcModelDirectory: directory)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("AudioFixtures/fixture-3-spoken-period-end.wav")
        let speech = try ProcessCommand.loadSamples(from: fixture)
        let words = ["The", "little", "green", "robut", "is", "ready", "period."]
        let duration = Double(speech.count) / 16000
        // Warm the same loaded model before either paired arm. No live settings/vocabulary.
        let controlA = try await VocabularyBoost.logProbabilities(audio: speech, spotter: spotter)
        let controlB = try await VocabularyBoost.logProbabilities(audio: speech, spotter: spotter)
        print("CTC_REPEAT same_path_max_log_probability_delta=\(maximumDelta(controlA.logProbs, controlB.logProbs))")
        var acceptedCorrections = 0
        for repeats in [1, 70] {
            let audio = Array(repeating: speech, count: repeats).flatMap { $0 }
            let transcript = Array(repeating: words.joined(separator: " "), count: repeats).joined(separator: " ")
            var timings: [TokenTiming] = []
            for repeatIndex in 0..<repeats {
                let offset = Double(repeatIndex) * duration
                for (index, word) in words.enumerated() {
                    let start = offset + Double(index) * duration / 7
                    let end = offset + Double(index + 1) * duration / 7
                    timings.append(TokenTiming(token: "▁" + word, tokenId: index,
                        startTime: start, endTime: end, confidence: 0.1))
                }
            }
            // Reverse order for the second pair to expose simple warm-cache ordering effects.
            for baselineFirst in [true, false] {
                var full: CtcKeywordSpotter.SpotKeywordsResult!
                var minimal: CtcKeywordSpotter.SpotKeywordsResult!
                var baselineSeconds = 0.0
                var candidateSeconds = 0.0
                for oldPath in [baselineFirst, !baselineFirst] {
                    let start = ProcessInfo.processInfo.systemUptime
                    if oldPath {
                        full = try await spotter.spotKeywordsWithLogProbs(
                            audioSamples: audio, customVocabulary: vocabulary, minScore: nil)
                        baselineSeconds = ProcessInfo.processInfo.systemUptime - start
                    } else {
                        minimal = try await VocabularyBoost.logProbabilities(audio: audio, spotter: spotter)
                        candidateSeconds = ProcessInfo.processInfo.systemUptime - start
                    }
                }
                XCTAssertFalse(full.logProbs.isEmpty)
                XCTAssertEqual(full.logProbs.map(\.count), minimal.logProbs.map(\.count))
                // Independent native inference can differ even on the SAME path (control
                // above; upstream's unwritten MLMultiArray padding is a separate open issue).
                // Record numeric drift; never turn it into a changed-input accuracy claim.
                let probabilityDelta = maximumDelta(full.logProbs, minimal.logProbs)
                XCTAssertEqual(full.frameDuration, minimal.frameDuration)
                XCTAssertEqual(full.totalFrames, minimal.totalFrames)
                XCTAssertTrue(minimal.detections.isEmpty)
                let baseline = legacyCompletion(batchText: transcript, tokenTimings: timings,
                    spot: full, rescorer: rescorer, vocabulary: vocabulary)
                let cachedCandidate = VocabularyBoost.applyLogProbabilities(batchText: transcript,
                    tokenTimings: timings, spot: full, rescorer: rescorer, vocabulary: vocabulary)
                let candidate = VocabularyBoost.applyLogProbabilities(batchText: transcript,
                    tokenTimings: timings, spot: minimal, rescorer: rescorer, vocabulary: vocabulary)
                XCTAssertEqual(baseline.text, candidate.text)
                XCTAssertEqual(baseline.rescoredRaw, candidate.rescoredRaw)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                // Same cached probabilities must preserve every output field, including scores.
                XCTAssertEqual(baseline.text, cachedCandidate.text)
                XCTAssertEqual(baseline.rescoredRaw, cachedCandidate.rescoredRaw)
                XCTAssertEqual(try encoder.encode(baseline.decisions), try encoder.encode(cachedCandidate.decisions))
                // Native pairs must preserve the actual replacements/acceptance decisions;
                // floating-point score wording may vary with the independent inference.
                let baselineDecisions: [[String]] = baseline.decisions.map {
                    [$0.original, $0.replacement, String($0.accepted)]
                }
                let candidateDecisions: [[String]] = candidate.decisions.map {
                    [$0.original, $0.replacement, String($0.accepted)]
                }
                XCTAssertEqual(baselineDecisions, candidateDecisions)
                let accepted = candidate.decisions.filter { $0.accepted }.count
                acceptedCorrections += accepted
                print(String(format: "CTC_PARITY compute=native seconds=%.2f terms=%d frames=%d old_spotting=%.4f probabilities_only=%.4f old_detections=%d accepted=%d probability_max_delta=%.6f baseline_first=%@",
                    Double(audio.count) / 16000, vocabulary.terms.count, minimal.totalFrames,
                    baselineSeconds, candidateSeconds, full.detections.count,
                    accepted, probabilityDelta, baselineFirst.description))
            }
        }
        XCTAssertGreaterThan(acceptedCorrections, 0, "Parity must exercise real guarded replacements, not only unchanged output")
    }

    private func maximumDelta(_ a: [[Float]], _ b: [[Float]]) -> Float {
        XCTAssertEqual(a.count, b.count)
        var largest: Float = 0
        for (left, right) in zip(a, b) {
            XCTAssertEqual(left.count, right.count)
            for (x, y) in zip(left, right) {
                XCTAssertTrue(x.isFinite && y.isFinite)
                largest = max(largest, abs(x - y))
            }
        }
        return largest
    }

    /// Frozen pre-optimization completion path (daa5d59): full vocabulary + same guards.
    /// This reference uses a shared cached CTC result so native repeat variability cannot
    /// hide a vocabulary loss, score change or replacement change in the refactored seam.
    private func legacyCompletion(batchText: String, tokenTimings: [TokenTiming],
                                  spot: CtcKeywordSpotter.SpotKeywordsResult, rescorer: VocabularyRescorer,
                                  vocabulary: CustomVocabularyContext) -> VocabularyBoost.Output {
        guard !spot.logProbs.isEmpty else {
            return .init(text: batchText, decisions: [], rescoredRaw: batchText)
        }
        let rescored = rescorer.ctcTokenRescore(transcript: batchText, tokenTimings: tokenTimings,
            logProbs: spot.logProbs, frameDuration: spot.frameDuration)
        guard rescored.wasModified else {
            return .init(text: batchText, decisions: [], rescoredRaw: rescored.text)
        }
        let terms = Dictionary(vocabulary.terms.map { ($0.textLowercased, $0) },
            uniquingKeysWith: { first, _ in first })
        let proposals = rescored.replacements.compactMap { item -> VocabularyBoost.ProposedReplacement? in
            guard let replacement = item.replacementWord else { return nil }
            return .init(original: item.originalWord, replacement: replacement,
                score: item.replacementScore, reason: item.reason)
        }
        let (text, decisions) = VocabularyBoost.spliceAcceptedReplacements(batchText: batchText,
            rescoredText: rescored.text, replacements: proposals, termByText: terms)
        return .init(text: text, decisions: decisions, rescoredRaw: rescored.text)
    }

}
