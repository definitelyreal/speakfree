// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
// ai-suggestion:unverified · session:unknown · 2026-08-24
import Foundation
import FluidAudio
import CoreML

/// Optional engine capability used by Transcriber to carry the resolved user mode without
/// overloading a lossy ASR prompt or changing every transcription backend's public contract.
protocol ConfidencePunctuationCorrectingEngine: TranscriptionEngine {
    func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                    enablePunctuationCommandCorrection: Bool) async throws -> String
    /// Same, plus which model instance produced this very take (read from the call, not from
    /// shared engine state, so a concurrent take cannot mislabel it).
    func transcribeReportingPath(samples: [Float], language: String, prompt: String?,
                                 suppressRegex: String?, enablePunctuationCommandCorrection: Bool)
        async throws -> (text: String, inferencePath: String)
}

extension ConfidencePunctuationCorrectingEngine {
    func transcribeReportingPath(samples: [Float], language: String, prompt: String?,
                                 suppressRegex: String?, enablePunctuationCommandCorrection: Bool)
        async throws -> (text: String, inferencePath: String) {
        let text = try await transcribe(
            samples: samples, language: language, prompt: prompt, suppressRegex: suppressRegex,
            enablePunctuationCommandCorrection: enablePunctuationCommandCorrection)
        return (text, engineID)
    }
}

/// Wraps FluidAudio's Parakeet TDT ASR for in-process transcription on the Apple Neural Engine.
///
/// Conforms to `TranscriptionEngine`. FluidAudio is `async/await` end-to-end (its `AsrManager`
/// is an `actor`), so the protocol's async surface maps directly — no serial-queue shim is needed,
/// unlike `WhisperEngine`. Audio currency is `[Float]` @ 16 kHz mono Float32, exactly what
/// `AudioRecorder` already produces, so the Parakeet path needs zero conversion glue.
///
/// Batch-only for v1: `supportsStreaming = false`. Live preview is unsupported.
///
/// ## Concurrency model
/// All mutable model state (the `AsrManager`, the loaded model id, and the in-flight transcription
/// counter) is owned by a private `actor Core`. The actor serializes lifecycle so a `transcribe`
/// can never run against a manager that `unload` is tearing down, and two concurrent `load`s can
/// never both build a manager (load/unload share a FIFO gate across suspension points). The outer
/// class is a thin facade that delegates to `Core` and maintains an NSLock-guarded `isLoaded`
/// mirror for the synchronous protocol getter.
public final class ParakeetEngine: TranscriptionEngine, ConfidencePunctuationCorrectingEngine {

    // MARK: - Audio constraints

    /// FluidAudio audio constraints (mirror `ASRConstants`). 3 s of trailing silence is appended
    /// so the TDT decoder can flush its final tokens — the old 1 s pad silently truncated the
    /// tail clause (see transcribe()). 240k samples = the 15 s single-chunk encoder cap.
    /// Internal, not private, so tests assert against these exact production values instead of
    /// mirroring them (the mirrors drifted once already).
    static let trailingSilenceSamples = 48_000
    static let maxSingleChunkSamples = 240_000

    /// Target length after the trailing-silence pad: pad up to `trailingSilenceSamples`, but
    /// never past the single-chunk cap — longer clips keep as much pad as fits.
    static func paddedSampleCount(_ count: Int) -> Int {
        count + min(trailingSilenceSamples, max(0, maxSingleChunkSamples - count))
    }

    // MARK: - Pad-hallucination strip (2026-07-21)

    /// Tokens that BEGIN this far after the real audio ends are decoding the synthetic
    /// pad, not speech. Margin absorbs TDT emission-time skew for a genuine last word.
    static let padHallucinationMarginSeconds = 0.3
    /// Never strip more than this many words — a timing anomaly must not delete real
    /// content. Observed hallucinations are 1-3 words ("here.", "being carried down.").
    static let padHallucinationMaxWords = 6

    // MARK: - Confidence/gap confabulation gate (P2)

    static let confabulationGapSeconds = 1.0
    static let confabulationMeanConfidence: Float = 0.52
    static let confabulationMaxConfidence: Float = 0.70
    static let confabulationTokenConfidence: Float = 0.50
    static let confabulationMaxWords = 8

    struct ConfidenceStripResult: Equatable {
        let text: String
        let removedTokenCount: Int
    }

    /// Remove a trailing phrase only when three independent signs agree: it begins after a long
    /// decoder-time gap, the whole suffix is weak, and several of its tokens are weak. A single
    /// low-confidence final word is kept. This is intentionally asymmetric: a visible invention is
    /// preferable to swallowing plausible speech unless the whole tail has the confabulation shape.
    static func strippingLowConfidenceTail(
        text: String, timings: [TokenTiming]?
    ) -> ConfidenceStripResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timings, timings.count >= 4 else {
            return ConfidenceStripResult(text: trimmed, removedTokenCount: 0)
        }

        // Search oldest boundary first. A confabulated tail can itself contain several long gaps;
        // choosing the newest one would leave its first invented word behind. Punctuation pieces
        // are retained in the suffix confidence
        // calculation because they are decoder decisions too, but at least three lexical pieces
        // are required before any transcript text may be removed.
        for cut in 1..<timings.count {
            let gap = timings[cut].startTime - timings[cut - 1].endTime
            guard gap >= confabulationGapSeconds else { continue }
            let suffix = Array(timings[cut...])
            let lexicalCount = suffix.filter {
                !$0.token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.isEmpty
            }.count
            guard lexicalCount >= 3, lexicalCount <= confabulationMaxWords else { continue }
            let confidences = suffix.map(\.confidence)
            let mean = confidences.reduce(0, +) / Float(confidences.count)
            let weakCount = confidences.filter { $0 < confabulationTokenConfidence }.count
            guard mean < confabulationMeanConfidence,
                  confidences.max() ?? 1 < confabulationMaxConfidence,
                  weakCount * 2 >= confidences.count else { continue }

            let droppedNorm = normalizedWordKey(suffix.map(\.token).joined())
            guard !droppedNorm.isEmpty else { continue }
            var words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            var peeled: [Substring] = []
            while let last = words.last, peeled.count < confabulationMaxWords {
                peeled.insert(last, at: 0)
                words.removeLast()
                if normalizedWordKey(peeled.joined(separator: " ")) == droppedNorm {
                    let kept = words.joined(separator: " ")
                    guard !kept.isEmpty else { break }
                    return ConfidenceStripResult(text: kept, removedTokenCount: suffix.count)
                }
            }
        }
        return ConfidenceStripResult(text: trimmed, removedTokenCount: 0)
    }

    // MARK: - Voice-activity endpointing (P3)

    static let vadMinimumTailTrimSeconds = 1.0
    /// 50 ms RMS windows for the true-silence gate.
    static let energyWindowSamples = 800
    /// A 50 ms window at or above this RMS could be quiet speech. Measured 2026-08-14:
    /// soft dictation can sit at 0.003–0.016 RMS and be inseparable from room tone
    /// (0.003–0.004), while genuine silence (mic idle) measures 0.0002–0.0004 — a clean 4x gap
    /// on either side of this threshold.
    static let trueSilenceRMSThreshold: Float = 0.0015

    /// Silero segmentation settings for tail endpointing. Values are unchanged from f30cb6c:
    /// 0.15 s minimum speech, 0.75 s minimum silence, no maximum, 0.20 s padding.
    ///
    /// FluidAudio's initializer carries a DEBUG-only `assert(speechPadding <= minSpeechDuration)`
    /// ("typically", not a correctness rule; release builds never evaluate it). Passing 0.20
    /// padding there trapped every debug build of `speakfree process` (crash 2026-09-22 9:34pm
    /// PT, VadTypes.swift:63). Build with legal values, then set the intended padding on the
    /// public property, so debug and release behave identically to the shipped settings.
    static var endpointingSegmentationConfig: VadSegmentationConfig {
        var config = VadSegmentationConfig(
            minSpeechDuration: 0.15, minSilenceDuration: 0.75,
            maxSpeechDuration: .infinity, speechPadding: 0.15)
        // Relies on FluidAudio validating only in init (checked in 0.15.1: plain `var`, no
        // didSet). When bumping FluidAudio, re-check VadTypes.swift; a setter check or a
        // precondition would bring this trap back, in release builds for a precondition.
        config.speechPadding = 0.20
        return config
    }

    /// Preserve the beginning/pre-roll and every internal pause; trim only a long non-speech tail
    /// after Silero's final speech segment. Empty/no-result VAD is a conservative no-op.
    ///
    /// True-silence gate (2026-08-14): Silero can stop detecting a quiet voice mid-take —
    /// one regression take lost 36.25 s of REAL speech (whisper hears it to the end) because
    /// the cut trusted the model alone. Quiet speech can be energy-inseparable from room tone, so no
    /// detector can find speech the VAD missed; what energy CAN prove is absence. The tail is
    /// now trimmed only when every 50 ms window in it sits at digital-silence level. Room-tone
    /// tails (where soft speech could hide) are never trimmed — the 3 s flush pad makes the kept
    /// audio near-free, and the stage was verified speed-neutral anyway (f30cb6c).
    static func endpointedSamples(_ samples: [Float], segments: [VadSegment]) -> [Float] {
        guard let last = segments.last else { return samples }
        let end = max(0, min(last.endSample(sampleRate: 16_000), samples.count))
        let removable = samples.count - end
        guard end >= FinalizePipeline.minSamples,
              Double(removable) / 16_000.0 >= vadMinimumTailTrimSeconds,
              tailIsTrueSilence(samples, from: end) else { return samples }
        return Array(samples[..<end])
    }

    /// True when every window, including the final partial window, is below the
    /// true-silence threshold. Unusable samples cannot establish silence.
    static func tailIsTrueSilence(_ samples: [Float], from start: Int) -> Bool {
        var i = max(0, start)
        while i < samples.count {
            let end = min(i + energyWindowSamples, samples.count)
            var acc: Float = 0
            for s in samples[i..<end] { acc += s * s }
            let rms = (acc / Float(end - i)).squareRoot()
            if !rms.isFinite || rms >= trueSilenceRMSThreshold {
                return false
            }
            i = end
        }
        return true
    }

    /// Drop trailing words the decoder invented over the appended silence pad
    /// (2026-07-21 corpus, confirmed against whisper-large-v3-turbo on the same wavs:
    /// "layout issues" → "layout issues here.", "sending an email" → "…email
    /// carrier."). We KNOW where real audio ends — the pad is ours — so tokens whose
    /// startTime falls beyond it are pad artifacts. Conservative on both sides: the
    /// dropped tokens must textually match the transcript's tail (the punctuation
    /// layer may reformat), and oversized strips are refused.
    static func strippingPadHallucination(
        text: String, timings: [TokenTiming]?, realAudioSeconds: Double
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timings, !timings.isEmpty, realAudioSeconds > 0 else { return trimmed }
        let threshold = realAudioSeconds + padHallucinationMarginSeconds
        var cut = timings.count
        while cut > 0, timings[cut - 1].startTime >= threshold { cut -= 1 }
        guard cut < timings.count else { return trimmed }

        let droppedNorm = normalizedWordKey(timings[cut...].map(\.token).joined())
        guard !droppedNorm.isEmpty else { return trimmed }

        // Peel whole words off the transcript tail until they normalize to exactly
        // the dropped tokens; bail if no clean match within the size cap.
        var words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        var peeled: [Substring] = []
        while let last = words.last, peeled.count < padHallucinationMaxWords {
            peeled.insert(last, at: 0)
            words.removeLast()
            if normalizedWordKey(peeled.joined(separator: " ")) == droppedNorm {
                let kept = words.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return kept.isEmpty ? trimmed : kept
            }
        }
        return trimmed
    }

    /// Lowercased alphanumerics only — tolerant of the punctuation layer's formatting
    /// and of BPE word-boundary markers in raw token pieces.
    private static func normalizedWordKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Confidence-guided punctuation-command correction

    /// The result stays inspectable so corpus tests can prove which acoustic token caused an edit.
    /// Production logs only these bounded token-level decisions, never the full transcript.
    struct PunctuationCommandCorrection: Equatable {
        let original: String
        let replacement: String
        let confidence: Float
        let takeMedian: Float
        let gapBefore: TimeInterval
        let startTime: TimeInterval
    }

    struct PunctuationCommandCorrectionResult: Equatable {
        let text: String
        let corrections: [PunctuationCommandCorrection]
    }

    /// A collision word must be both an acoustic outlier and command-shaped. The absolute ceiling
    /// prevents a merely relative dip in an otherwise weak take from rewriting real English; the
    /// ratio catches the observed 0.381-in-a-1.0-median garbles that a fixed 0.3 threshold misses.
    static let punctuationCommandAbsoluteConfidenceCeiling: Float = 0.60
    static let punctuationCommandMedianRatioCeiling: Float = 0.65
    static let punctuationCommandPauseSeconds: TimeInterval = 0.20

    private struct ConfidenceWord {
        let surface: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float
    }

    private static let punctuationCollisionLexicon: [String: String] = [
        // comma -- every entry here is a real-word collision; non-word spellings stay in
        // TextPostProcessor where they do not need acoustic confidence.
        "gamma": ",", "coma": ",", "comment": ",", "common": ",",
        "come": ",", "comes": ",", "coming": ",", "count": ",",
        // period
        "paired": ".", "pierre": ".",
        // question mark
        "questioner": "?", "questionnaire": "?",
        // colon
        "column": ":", "cologne": ":",
    ]

    /// Real-word meanings that stay literal even when the recognizer also emits a pause or
    /// sentence boundary. These are deliberately phrase-level fences for corpus-observed and
    /// user-specified collisions, not a general language model hidden inside the corrector.
    private static let punctuationCollisionFollowingWordGuards: [String: Set<String>] = [
        "gamma": ["correction", "ray", "rays", "radiation"],
        "paired": ["the", "with", "sock", "socks", "sample", "samples", "test", "tests"],
        "count": ["the", "on", "up", "down", "vote", "votes"],
        "common": ["sense", "law", "knowledge", "practice", "mistake", "mistakes",
                   "issue", "issues", "problem", "problems", "ground"],
        "comment": ["on", "about"],
        "questioner": ["asked", "asks", "said", "says"],
        "questionnaire": ["response", "responses", "result", "results", "survey", "data"],
        "pierre": ["arrived", "went", "said", "says", "is", "was"],
        "cologne": ["smells", "scent", "bottle", "brand"],
        "come": ["on", "up"], "comes": ["on", "up"], "coming": ["on", "up"],
    ]
    private static let punctuationCollisionPrecedingWordGuards: [String: Set<String>] = [
        "column": ["first", "second", "third", "fourth", "last", "next", "left", "right"],
    ]

    /// Convert only confidence-qualified real-word homophones. Literal command words and safe
    /// non-word garbles are deliberately absent: TextPostProcessor owns those without confidence.
    static func correctingPunctuationCommandHomophones(
        text: String, timings: [TokenTiming]?
    ) -> PunctuationCommandCorrectionResult {
        guard let timings, !timings.isEmpty, !text.isEmpty else {
            return PunctuationCommandCorrectionResult(text: text, corrections: [])
        }

        let timingWords = punctuationConfidenceWords(from: timings)
        guard !timingWords.isEmpty else {
            return PunctuationCommandCorrectionResult(text: text, corrections: [])
        }

        let tokenized = VocabularyBoost.tokenizePreservingGaps(text)
        let originalWords = tokenized.words
        var words = originalWords
        var gaps = tokenized.gaps
        let textKeys = originalWords.map(normalizedWordKey)
        let alignment = alignTimingWords(timingWords, to: textKeys)
        // Tail/pad stripping happens before this pass, while FluidAudio timings still describe
        // the pre-strip decode. Base the take median only on words that survived into `text` so a
        // stripped synthetic tail cannot make a real token look like an outlier.
        let alignedTimingIndices = timingWords.indices.filter { alignment[$0] != nil }
        guard !alignedTimingIndices.isEmpty else {
            return PunctuationCommandCorrectionResult(text: text, corrections: [])
        }
        let sorted = alignedTimingIndices.map { timingWords[$0].confidence }.sorted()
        let median: Float = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        guard median > 0 else {
            return PunctuationCommandCorrectionResult(text: text, corrections: [])
        }
        let hasConfidenceQualifiedCollision = alignedTimingIndices.contains { timingIndex in
            let word = timingWords[timingIndex]
            let key = normalizedWordKey(word.surface)
            return punctuationCollisionLexicon[key] != nil
                && word.confidence < punctuationCommandAbsoluteConfidenceCeiling
                && word.confidence / median < punctuationCommandMedianRatioCeiling
        }
        guard hasConfidenceQualifiedCollision else {
            return PunctuationCommandCorrectionResult(text: text, corrections: [])
        }

        let clauseMarks: Set<Character> = [".", ",", "!", "?", ";", ":"]
        let closingMarks: Set<Character> = ["\"", "'", "’", "”", ")", "]", "}"]
        func hasTrailingClauseMark(_ word: String) -> Bool {
            guard let last = word.reversed().first(where: { !closingMarks.contains($0) }) else {
                return false
            }
            return clauseMarks.contains(last)
        }
        var deletedWordIndices = Set<Int>()
        var corrections: [PunctuationCommandCorrection] = []

        for timingIndex in timingWords.indices {
            let timingWord = timingWords[timingIndex]
            let key = normalizedWordKey(timingWord.surface)
            guard let replacement = punctuationCollisionLexicon[key],
                  let textIndex = alignment[timingIndex],
                  timingWord.confidence < punctuationCommandAbsoluteConfidenceCeiling,
                  timingWord.confidence / median < punctuationCommandMedianRatioCeiling else { continue }

            let gapBefore = timingIndex > 0
                ? max(0, timingWord.startTime - timingWords[timingIndex - 1].endTime) : 0
            let paused = gapBefore >= punctuationCommandPauseSeconds
            let previousIndex = textIndex > 0 ? textIndex - 1 : nil
            let previousKey = previousIndex.map { normalizedWordKey(originalWords[$0]) } ?? ""
            let nextKey = textIndex + 1 < originalWords.count
                ? normalizedWordKey(originalWords[textIndex + 1]) : ""
            if punctuationCollisionFollowingWordGuards[key]?.contains(nextKey) == true { continue }
            if punctuationCollisionPrecedingWordGuards[key]?.contains(previousKey) == true { continue }
            if key == "column", nextKey.count == 1 { continue }

            let candidatePunctuated = hasTrailingClauseMark(originalWords[textIndex])
            // A grammatical determiner/possessive normally makes the collision a noun. Allow only
            // article shapes that are themselves ungrammatical: "an" before this consonant
            // lexicon, or utterance-final "a paired." (the adjective cannot stand as that noun).
            // Broad a/that + punctuation exceptions corrupt ordinary "a comment, which..." prose.
            let articleBefore = previousKey == "a" || previousKey == "an"
            let strongInsertedArticleShape = previousKey == "an"
                || (previousKey == "a" && key == "paired" && candidatePunctuated
                    && nextKey.isEmpty)
            if articleBefore && !strongInsertedArticleShape { continue }
            let hardLiteralNounMarker: Set<String> = [
                "the", "my", "your", "his", "her", "its", "our", "their",
            ]
            if hardLiteralNounMarker.contains(previousKey) { continue }
            let demonstrativeMarker: Set<String> = ["this", "that", "these", "those"]
            let studyGammaCommandShape = key == "gamma" && previousKey == "this"
                && candidatePunctuated && ["whether", "if"].contains(nextKey)
            if demonstrativeMarker.contains(previousKey),
               !studyGammaCommandShape { continue }
            let articleInsertion = strongInsertedArticleShape
            let clauseBoundary = previousIndex.map { hasTrailingClauseMark(originalWords[$0]) } ?? false
            guard paused || clauseBoundary || articleInsertion else { continue }

            // "come" is the dominant collision family. One generic slot signal is not enough:
            // require two independent shape signals, with punctuation on the candidate itself
            // counting as the observed isolated-command signature ("Sure, come, I'd...").
            if key == "come" || key == "comes" || key == "coming" {
                let strength = [paused, clauseBoundary, articleInsertion, candidatePunctuated]
                    .filter { $0 }.count
                guard strength >= 2 else { continue }
            }

            // Spoken punctuation outranks the engine's auto-punctuation at the boundary.
            if clauseBoundary, let previousIndex {
                var closingSuffix = ""
                while let last = words[previousIndex].last, closingMarks.contains(last) {
                    closingSuffix.insert(last, at: closingSuffix.startIndex)
                    words[previousIndex].removeLast()
                }
                while let last = words[previousIndex].last, clauseMarks.contains(last) {
                    words[previousIndex].removeLast()
                }
                words[previousIndex] += closingSuffix
            }
            if articleInsertion, let previousIndex {
                deletedWordIndices.insert(previousIndex)
                gaps[previousIndex] = ""
                gaps[previousIndex + 1] = ""
            }
            gaps[textIndex] = ""
            words[textIndex] = replacement
            corrections.append(PunctuationCommandCorrection(
                original: timingWord.surface, replacement: replacement,
                confidence: timingWord.confidence, takeMedian: median, gapBefore: gapBefore,
                startTime: timingWord.startTime))
        }

        guard !corrections.isEmpty else {
            return PunctuationCommandCorrectionResult(text: text, corrections: [])
        }
        var corrected = gaps[0]
        for index in words.indices {
            if !deletedWordIndices.contains(index) { corrected += words[index] }
            corrected += gaps[index + 1]
        }
        return PunctuationCommandCorrectionResult(text: corrected, corrections: corrections)
    }

    /// A word whose weakest lexical token scores below this is reported as unsure in the
    /// dictation trace. Same ceiling the punctuation-command corrector treats as an outlier.
    static let unsureWordConfidenceCeiling: Float = 0.60

    /// Words below `unsureWordConfidenceCeiling`, in spoken order, punctuation trimmed.
    static func lowConfidenceWords(from timings: [TokenTiming]) -> [DictationTrace.WordScore] {
        punctuationConfidenceWords(from: timings).compactMap { w in
            guard w.confidence < unsureWordConfidenceCeiling else { return nil }
            let word = w.surface.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            return word.isEmpty ? nil : DictationTrace.WordScore(word: word, score: w.confidence)
        }
    }

    private static func punctuationConfidenceWords(from timings: [TokenTiming]) -> [ConfidenceWord] {
        var words: [ConfidenceWord] = []
        var surface = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var lexicalConfidences: [Float] = []

        func flush() {
            guard !normalizedWordKey(surface).isEmpty, !lexicalConfidences.isEmpty else { return }
            words.append(ConfidenceWord(
                surface: surface, startTime: start, endTime: end,
                confidence: lexicalConfidences.min() ?? 1))
        }

        for timing in timings {
            let raw = timing.token
            guard !raw.isEmpty, raw != "<blank>", raw != "<pad>" else { continue }
            let startsWord = raw.first == "▁" || raw.first?.isWhitespace == true
            if startsWord, !surface.isEmpty {
                flush(); surface = ""; lexicalConfidences = []
            }
            let piece = String(raw.drop(while: { $0 == "▁" || $0.isWhitespace }))
            guard !piece.isEmpty else { continue }
            if surface.isEmpty { start = timing.startTime }
            surface += piece
            end = timing.endTime
            if piece.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                lexicalConfidences.append(timing.confidence)
            }
        }
        flush()
        return words
    }

    /// LCS word alignment. Vocabulary boosting may change unrelated words, so timing and final-
    /// text indices are not assumed equal; a candidate is edited only when its original normalized
    /// word still participates in the monotonic alignment. The cap keeps malformed huge results
    /// from turning this bounded correction pass into an unbounded quadratic allocation.
    private static func alignTimingWords(
        _ timingWords: [ConfidenceWord], to textKeys: [String]
    ) -> [Int: Int] {
        let timingKeys = timingWords.map { normalizedWordKey($0.surface) }
        let n = timingKeys.count, m = textKeys.count
        guard n <= VocabularyBoost.maxBoostWords, m <= VocabularyBoost.maxBoostWords else {
            return [:]
        }
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i][j] = timingKeys[i] == textKeys[j]
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var result: [Int: Int] = [:]
        var i = 0, j = 0
        while i < n, j < m {
            if !timingKeys[i].isEmpty, timingKeys[i] == textKeys[j] {
                result[i] = j
                i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    // MARK: - Core (owns all mutable model state)

    /// Serializes all model lifecycle and transcription against a single owner. Every mutable
    /// field lives here; nothing outside the actor touches the manager.
    private actor Core {

        /// FluidAudio's loaded ASR manager (actor). `nil` until `load` succeeds.
        private var manager: AsrManager?

        /// Ingredients for the custom-vocabulary BATCH-ANCHORED boost path (VocabularyBoost).
        /// Populated in the background by `setupVocabBoosting` when a `custom-vocabulary.json`
        /// gate file is present and the CTC keyword-spotter loads; all nil otherwise (→
        /// `transcribe` returns the plain batch result). Ported from vocab-boost-eval
        /// (2026-07-22): the sliding-window design was retired — its base decode diverges
        /// from batch at window seams (~2.5% of words), so it could never guarantee
        /// production parity. The boost runs ON TOP of the batch result and can only
        /// change explicitly-accepted vocab spans.
        private var vocabSpotter: CtcKeywordSpotter?
        private var vocabRescorer: VocabularyRescorer?
        private var vocabContext: CustomVocabularyContext?
        private var vocabTermCount = 0
        /// Owned background work: unload and model replacement cancel AND drain these handles.
        private var vocabSetupTask: Task<Void, Never>?
        private var vadManager: VadManager?
        private var vadSetupTask: Task<Void, Never>?
        private var auxiliaryGeneration: UInt64 = 0

        /// The model identifier currently loaded, e.g. "parakeet-tdt-0.6b-v3". `nil` when unloaded.
        private var loadedModelID: String?

        /// CPU-only copy of the model that serves dictations while the Neural Engine model is
        /// still being prepared at first start (see ParakeetFirstStart.swift). Never used once
        /// `manager` is loaded; released right after. `standInActive` counts its in-flight takes
        /// so release waits for them, the same discipline as `active` for `manager`.
        private var standIn: AsrManager?
        private var standInModelID: String?
        private var standInActive = 0

        /// Bumped by every unload, under the lifecycle gate. Background loads (first-start
        /// preparation, the Neural Engine retry) pass the value they started with and are
        /// refused once an unload has run, so nothing loads into a discarded engine.
        private var unloadEpoch: UInt64 = 0
        var epoch: UInt64 { unloadEpoch }

        /// Count of transcriptions currently in flight. `unload` (and a model-replacing `load`)
        /// drains this to 0 before tearing the manager down so an in-flight `transcribe` never sees
        /// a cleaned-up manager. Note: incrementing `active` does NOT by itself protect the manager
        /// across the `await mgr.transcribe` suspension — the actor is released at every await, so a
        /// teardown could interleave. Protection comes from the `tearingDown` gate (no new transcribe
        /// starts once teardown begins) plus the drain (teardown waits for `active == 0`).
        private var active = 0

        /// Set true at the START of any teardown (unload, or a model-replacing load) and cleared
        /// once teardown completes. While set, no new `transcribe` may begin, which lets the drain
        /// loop reach `active == 0` and guarantees no transcribe holds a reference to a manager that
        /// is about to be `cleanup()`'d.
        private var tearingDown = false

        // Actor reentrancy does not serialize an entire async lifecycle operation. Hold this
        // FIFO gate across native loads/cleanup so unload drains an earlier load, and a later load
        // cannot publish a new manager/task while unload is suspended. Same-model loads remain
        // idempotent after acquiring the gate.
        private var lifecycleBusy = false
        private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

        private func acquireLifecycle() async {
            if lifecycleBusy {
                await withCheckedContinuation { lifecycleWaiters.append($0) }
            } else {
                lifecycleBusy = true
            }
        }

        private func releaseLifecycle() {
            if lifecycleWaiters.isEmpty {
                lifecycleBusy = false
            } else {
                lifecycleWaiters.removeFirst().resume()
            }
        }

        /// Notifies the outer facade so it can update its NSLock-guarded `isLoaded` mirror.
        private let onLoadedChange: @Sendable (Bool) -> Void
        private let onDiagnostics: @Sendable (TranscriptionDiagnostics?) -> Void

        private let onStandInChange: @Sendable (Bool) -> Void

        init(onLoadedChange: @escaping @Sendable (Bool) -> Void,
             onDiagnostics: @escaping @Sendable (TranscriptionDiagnostics?) -> Void,
             onStandInChange: @escaping @Sendable (Bool) -> Void = { _ in }) {
            self.onLoadedChange = onLoadedChange
            self.onDiagnostics = onDiagnostics
            self.onStandInChange = onStandInChange
        }

        var isLoaded: Bool { manager != nil }

        func isLoaded(modelID: String) -> Bool { manager != nil && loadedModelID == modelID }

        /// True when a take for `modelID` could start now on either instance.
        func canTranscribe(modelID: String) -> Bool {
            guard !tearingDown else { return false }
            return (manager != nil && loadedModelID == modelID)
                || (standIn != nil && standInModelID == modelID)
        }

        // MARK: CPU stand-in (first start)

        /// Load the CPU-only stand-in unless the Neural Engine model (or a stand-in) is already
        /// there. Holds the lifecycle gate so it cannot race a load or unload. Returns true when
        /// a stand-in was published.
        func loadStandIn(modelID: String, ifEpoch epoch: UInt64,
                         shouldStart: @Sendable () -> Bool = { true }) async throws -> Bool {
            await acquireLifecycle()
            defer { releaseLifecycle() }
            try Task.checkCancellation()
            guard epoch == unloadEpoch, shouldStart(), manager == nil, standIn == nil else { return false }
            guard ParakeetModelManager.shared.isModelDownloaded(modelID) else {
                throw TranscriptionEngineError.modelAssetsMissing(modelID)
            }
            let models: AsrModels
            do {
                models = try await ParakeetModelManager.shared.loadDownloadedModels(modelID, cpuOnly: true)
            } catch let error as TranscriptionEngineError {
                throw error
            } catch {
                throw TranscriptionEngineError.modelLoadFailed(modelID)
            }
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            // Canceled while native loading ran (engine discarded): never publish.
            if Task.isCancelled || manager != nil || tearingDown {
                await mgr.cleanup()
                return false
            }
            standIn = mgr
            standInModelID = modelID
            onStandInChange(true)
            return true
        }

        func releaseStandIn() async {
            await acquireLifecycle()
            defer { releaseLifecycle() }
            await releaseStandInHoldingGate()
        }

        /// Caller holds the lifecycle gate. Unpublish first so no new take picks the stand-in,
        /// then wait for its in-flight takes before freeing it.
        private func releaseStandInHoldingGate() async {
            guard let old = standIn else { return }
            standIn = nil
            standInModelID = nil
            onStandInChange(false)
            while standInActive > 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
            await old.cleanup()
            DiagnosticLogger.shared.log(
                "ParakeetEngine: CPU stand-in released (resident \(processResidentMB()) MB)")
        }

        // MARK: Load (single-flight)

        func load(modelID: String, ifEpoch epoch: UInt64? = nil) async throws {
            await acquireLifecycle()
            defer { releaseLifecycle() }
            // Queue admission itself is noncancellable; a canceled load releases its slot before
            // starting any native work. Unload deliberately completes cleanup despite cancellation.
            try Task.checkCancellation()
            if let epoch, epoch != unloadEpoch { throw CancellationError() }
            try await performLoad(modelID: modelID)
        }

        private func performLoad(modelID: String) async throws {
            // Re-check inside the (now serialized) load: a prior single-flight load may have already
            // satisfied this request while we were queued.
            if loadedModelID == modelID, manager != nil { return }

            // Preflight: never trigger a 600MB download inside the transcribe path. Acquisition
            // happens via the Settings download UI; if assets aren't present, surface the error.
            guard ParakeetModelManager.shared.isModelDownloaded(modelID) else {
                throw TranscriptionEngineError.modelAssetsMissing(modelID)
            }

            DiagnosticLogger.shared.log("ParakeetEngine: loading model \(modelID)")
            let loadStart = CFAbsoluteTimeGetCurrent()

            // Unit 5 owns download + cache + load. Prefer the load-only entry point (Unit B); fall
            // back to `loadedModels` until that method lands.
            let models: AsrModels
            do {
                models = try await ParakeetModelManager.shared.loadedModels(modelID)
            } catch let error as ASRError {
                throw ParakeetEngine.map(error, modelID: modelID)
            } catch let error as TranscriptionEngineError {
                throw error
            } catch {
                throw TranscriptionEngineError.modelLoadFailed(modelID)
            }

            let mgr = AsrManager(config: .default)
            do {
                try await mgr.loadModels(models)
            } catch let error as ASRError {
                throw ParakeetEngine.map(error, modelID: modelID)
            } catch {
                throw TranscriptionEngineError.modelLoadFailed(modelID)
            }

            // Tear down a previously-loaded (different) manager before replacing it, so its CoreML
            // state isn't leaked. Same discipline as `unload`: an in-flight `transcribe` captured the
            // old manager via `let mgr = manager` and keeps using it across the `await mgr.transcribe`
            // suspension, so we must (1) gate new transcribes, (2) publish the mirror false, (3) drain
            // active to 0, (4) cleanup the OLD manager — all BEFORE assigning the new one.
            if let old = manager {
                tearingDown = true
                onLoadedChange(false)
                while active > 0 { await Task.yield() }
                await drainAuxiliarySetup()
                manager = nil
                loadedModelID = nil
                vocabSpotter = nil; vocabRescorer = nil; vocabContext = nil; vocabTermCount = 0
                vadManager = nil
                await old.cleanup()
                tearingDown = false
            }

            manager = mgr
            loadedModelID = modelID

            let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
            DiagnosticLogger.shared.log("ParakeetEngine: model loaded in \(String(format: "%.2f", loadTime))s")
            onLoadedChange(true)

            // Optional models become ready in the background; their tasks remain owned until
            // unload/model replacement has drained them, even when native setup ignores cancel.
            startAuxiliarySetup(
                vocabulary: { generation in
                    await self.setupVocabBoosting(models: models, forModelID: modelID,
                                                  generation: generation)
                },
                endpointing: { generation in
                    await self.setupEndpointing(forModelID: modelID, generation: generation)
                })
        }

        private func startAuxiliarySetup(
            vocabulary: @escaping @Sendable (UInt64) async -> Void,
            endpointing: @escaping @Sendable (UInt64) async -> Void
        ) {
            auxiliaryGeneration &+= 1
            let generation = auxiliaryGeneration
            vocabSetupTask = Task { await vocabulary(generation) }
            vadSetupTask = Task { await endpointing(generation) }
        }

        private func auxiliarySetupCanPublish(_ generation: UInt64) -> Bool {
            generation == auxiliaryGeneration && !tearingDown && !Task.isCancelled
        }

        private func drainAuxiliarySetup() async {
            auxiliaryGeneration &+= 1
            let vocabulary = vocabSetupTask
            let endpointing = vadSetupTask
            vocabulary?.cancel()
            endpointing?.cancel()
            // Cancellation is cooperative; CoreML compilation may still be inside native code.
            // Await completion before clearing ownership or cleaning up its supporting manager.
            await vocabulary?.value
            await endpointing?.value
            vocabSetupTask = nil
            vadSetupTask = nil
        }

        private func setupEndpointing(forModelID: String, generation: UInt64) async {
            guard auxiliarySetupCanPublish(generation) else { return }
            do {
                // Silero is tiny. Keep it off the Neural Engine so it cannot evict or contend
                // with Parakeet + the CTC vocabulary graph. Dogfood 2026-08-13 showed a fast
                // median but random 1.2–5.7s release tails after adding an ANE-backed VAD.
                let config = VadConfig(defaultThreshold: 0.85, debugMode: false, computeUnits: .cpuOnly)
                let vad: VadManager
                if ParakeetEngine.sileroModelCached() {
                    // Cached (every Mac that has run it once): load offline, in parallel with the
                    // vocabulary setup, exactly as before. No gate, no network.
                    vad = try await VadManager(config: config)
                } else if ParakeetEngine.sileroFetchFailed.value {
                    throw TranscriptionEngineError.modelLoadFailed("silero-vad (fetch already failed this session)")
                } else {
                    // Missing: FluidAudio is pinned offline, so without the sanctioned gate a Mac that
                    // never had Silero cached could never fetch it and silently ran without
                    // endpointing (reproduced 2026-09-24 with an empty model cache: "required models
                    // missing for silero-vad"). One attempt per session so an unreachable network
                    // cannot hold the shared download gate on every model load.
                    do {
                        vad = try await ParakeetModelManager.shared.withSanctionedDownload {
                            try await VadManager(config: config)
                        }
                    } catch {
                        // A cancelled fetch (model switch mid-download) says nothing about the network.
                        if !(error is CancellationError) && !Task.isCancelled {
                            ParakeetEngine.sileroFetchFailed.value = true
                        }
                        throw error
                    }
                }
                guard auxiliarySetupCanPublish(generation), loadedModelID == forModelID,
                      manager != nil else { return }
                vadManager = vad
                DiagnosticLogger.shared.log("ParakeetEngine: Silero endpointing ready")
            } catch {
                guard auxiliarySetupCanPublish(generation) else { return }
                DiagnosticLogger.shared.log(
                    "ParakeetEngine: endpointing unavailable — \(error.localizedDescription); using full audio")
                vadManager = nil
            }
        }

        /// Try to configure batch-anchored custom-vocabulary boosting. Gated on a
        /// `custom-vocabulary.json` (FluidAudio `CustomVocabularyConfig` format) existing in the
        /// active config dir — machines opt in by creating it; everything else stays batch-only.
        /// Terms come from `vocabulary.txt` (the user's curated list; punctuation command words
        /// excluded); the gate file contributes curated garble ALIASES (e.g. "xander" → Zander),
        /// which are the only channel through which a real English word may be rescored.
        /// Downloads the ~110MB CTC keyword-spotter model on first use. Any failure logs and
        /// leaves the ingredients nil, so `transcribe` returns the plain batch result.
        private func setupVocabBoosting(models: AsrModels, forModelID: String,
                                        generation: UInt64) async {
            guard auxiliarySetupCanPublish(generation) else { return }
            vocabSpotter = nil; vocabRescorer = nil; vocabContext = nil; vocabTermCount = 0

            let dictURL = Config.configDir.appendingPathComponent("custom-vocabulary.json")
            guard FileManager.default.fileExists(atPath: dictURL.path) else { return }
            do {
                DiagnosticLogger.shared.log("ParakeetEngine: loading CTC keyword-spotter for vocab boosting")
                // FluidAudio is pinned offline (speakfree owns all downloads). The CTC
                // fetch goes through the SAME serialized gate as the Parakeet weights:
                // the save/restore-to-captured-prior it replaced could latch
                // enforceOffline=false forever under overlapping setups, and two
                // concurrent 110MB fetches could corrupt the shared cache dir
                // (verifier, 2026-07-22). Cached after first fetch; offline failure is
                // non-fatal (outer catch → plain batch path).
                let ctc = try await ParakeetModelManager.shared.withSanctionedDownload {
                    try await CtcModels.downloadAndLoad(variant: .ctc110m)
                }
                guard auxiliarySetupCanPublish(generation) else { return }
                // Tokenize each term for the CTC keyword spotter (`.load()` leaves ctcTokenIds
                // nil and nothing is ever spotted — dogfood 2026-07-02).
                let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
                let aliases = VocabularyBoost.loadCuratedAliases(from: dictURL)
                let specs = VocabularyBoost.loadTermSpecs(
                    vocabularyFile: Config.vocabularyFile, curatedAliases: aliases)
                let context = VocabularyBoost.makeContext(specs: specs, tokenizer: tokenizer)
                guard !context.terms.isEmpty else {
                    DiagnosticLogger.shared.log("ParakeetEngine: vocab boosting idle — no usable terms")
                    return
                }
                let spotter = CtcKeywordSpotter(models: ctc)
                let rescorer = try await VocabularyRescorer.create(
                    spotter: spotter, vocabulary: context,
                    ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m))

                // Commit only if this model is still the loaded one (a reload may have raced).
                guard auxiliarySetupCanPublish(generation), loadedModelID == forModelID,
                      manager != nil else { return }
                vocabSpotter = spotter
                vocabRescorer = rescorer
                vocabContext = context
                vocabTermCount = context.terms.count
                DiagnosticLogger.shared.log("ParakeetEngine: vocab boosting ready (\(context.terms.count) CTC-tokenized terms, batch-anchored)")
            } catch {
                guard auxiliarySetupCanPublish(generation) else { return }
                DiagnosticLogger.shared.log("ParakeetEngine: vocab boosting unavailable — \(error.localizedDescription); using batch path")
                vocabSpotter = nil; vocabRescorer = nil; vocabContext = nil; vocabTermCount = 0
            }
        }

        // MARK: Transcribe

        func transcribe(samples: [Float], language: String,
                        enablePunctuationCommandCorrection: Bool) async throws
            -> (text: String, path: ParakeetInferencePath) {
            // Gate on `tearingDown` BEFORE bumping `active` so no transcribe begins once a teardown
            // (unload or model-replacing load) has started. This is what lets the drain loop finish.
            // The Neural Engine model always wins once loaded; the CPU stand-in only serves takes
            // made while it is still being prepared at first start.
            let mgr: AsrManager
            let modelID: String
            let path: ParakeetInferencePath
            if !tearingDown, let loaded = manager, let id = loadedModelID {
                (mgr, modelID, path) = (loaded, id, .neuralEngine)
                active += 1
            } else if !tearingDown, let cpu = standIn, let id = standInModelID {
                (mgr, modelID, path) = (cpu, id, .cpuStandIn)
                standInActive += 1
            } else {
                throw TranscriptionEngineError.modelNotLoaded
            }
            defer {
                if path == .neuralEngine { active -= 1 } else { standInActive -= 1 }
            }

            // Test seam: SPEAKFREE_WAIT_ENDPOINTING=1 awaits the background Silero setup (see
            // SPEAKFREE_WAIT_VOCAB below) so an offline A/B never scores its first takes without
            // endpointing. No-op in the app.
            if ProcessInfo.processInfo.environment["SPEAKFREE_WAIT_ENDPOINTING"] == "1", vadManager == nil {
                await vadSetupTask?.value
                FileHandle.standardError.write(
                    Data("SPEAKFREE_WAIT_ENDPOINTING: Silero ready = \(vadManager != nil)\n".utf8))
            }

            // Trailing-silence pad. Parakeet's TDT decoder needs trailing audio to "flush"
            // its final tokens — with too little, it stops early and SILENTLY DROPS the last
            // clause (verified 2026-06-12: a 7.8s clip lost its final clause, "and happy to send a reply"
            // with the old 1s pad; ~3s recovers it). The pad is near-free: it's silence and
            // the ANE encoder cost is ~flat regardless of length (measured ~110ms at both
            // 7.8s and 10.8s). Pad up to `trailingSilenceSamples`, but never past the
            // single-chunk cap so longer clips keep as much pad as fits (FluidAudio
            // auto-chunks anything beyond the cap).
            var speechSamples = samples
            let vadStart = CFAbsoluteTimeGetCurrent()
            if let vadManager {
                do {
                    let segments = try await vadManager.segmentSpeech(
                        samples,
                        config: ParakeetEngine.endpointingSegmentationConfig)
                    speechSamples = ParakeetEngine.endpointedSamples(samples, segments: segments)
                } catch {
                    DiagnosticLogger.shared.log(
                        "ParakeetEngine: endpointing failed — \(error.localizedDescription); using full audio")
                }
            }
            let vadElapsed = CFAbsoluteTimeGetCurrent() - vadStart
            let vadTrimmedSeconds = Double(samples.count - speechSamples.count) / 16_000.0
            if vadTrimmedSeconds > 0 {
                DiagnosticLogger.shared.log(String(
                    format: "ParakeetEngine: VAD trimmed %.2fs trailing non-speech", vadTrimmedSeconds))
            }

            var audio = speechSamples
            let pad = ParakeetEngine.paddedSampleCount(audio.count) - audio.count
            if pad > 0 {
                audio += [Float](repeating: 0, count: pad)
            }

            // Language hint: v3 forwards an explicit Language for concrete codes (including "en");
            // nil only for auto/empty codes or v2 (English-only, ignores the hint).
            let isV3 = EngineCatalog.versionString(forParakeetModelID: modelID) != "v2"
            let hint = ParakeetEngine.languageHint(for: language, isV3: isV3)

            // Test seam (A/B benchmarking): a short-lived CLI `process` run normally races the
            // background vocab setup and silently benchmarks the batch path instead.
            // SPEAKFREE_WAIT_VOCAB=1 awaits setup and reports the engaged path on stderr so every
            // benchmark run self-verifies which decode path produced its output. No-op in the app.
            if ProcessInfo.processInfo.environment["SPEAKFREE_WAIT_VOCAB"] == "1" {
                await vocabSetupTask?.value
                FileHandle.standardError.write(
                    Data("SPEAKFREE_WAIT_VOCAB: vocab terms ready = \(vocabTermCount)\n".utf8))
            }

            // Build a fresh decoder state sized to the loaded model's LSTM layer count.
            var decoderState = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)

            let result: ASRResult
            let asrStart = CFAbsoluteTimeGetCurrent()
            do {
                result = try await mgr.transcribe(audio, decoderState: &decoderState, language: hint)
            } catch let error as ASRError {
                throw ParakeetEngine.map(error, modelID: modelID)
            } catch {
                throw TranscriptionEngineError.transcriptionFailed
            }
            let asrElapsed = CFAbsoluteTimeGetCurrent() - asrStart

            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Batch-anchored vocab boost, once its background setup has populated the
            // ingredients. Runs the CTC rescorer over the FINISHED batch result and splices
            // in only guard-accepted vocabulary spans, so worst case (veto everything,
            // rescorer error, prefilter skip) is exactly the production batch text.
            // Ordering: boost BEFORE the pad strip — the boost was validated with
            // batchText exactly matching the token timings; the strip below only peels
            // tail words and refuses on any mismatch, so a boosted tail word merely
            // declines the strip (conservative keep).
            let vocabStart = CFAbsoluteTimeGetCurrent()
            if let spotter = vocabSpotter, let rescorer = vocabRescorer, let ctx = vocabContext {
                do {
                    let boosted = try await VocabularyBoost.boost(
                        batchText: text,
                        tokenTimings: result.tokenTimings ?? [],
                        audio: audio,
                        spotter: spotter, rescorer: rescorer, vocabulary: ctx)
                    let applied = boosted.decisions.filter { $0.accepted }
                    if !applied.isEmpty {
                        DiagnosticLogger.shared.log(
                            "ParakeetEngine: vocab boost applied \(applied.count) replacement(s): "
                                + applied.map { "'\($0.original)'→'\($0.replacement)'" }
                                    .joined(separator: ", "))
                    }
                    text = boosted.text
                } catch {
                    DiagnosticLogger.shared.log(
                        "ParakeetEngine: vocab boost failed (\(error.localizedDescription)) — using batch text")
                }
            }
            let vocabElapsed = CFAbsoluteTimeGetCurrent() - vocabStart
            let inferenceElapsed = vadElapsed + asrElapsed + vocabElapsed
            if inferenceElapsed >= 0.75 {
                DiagnosticLogger.shared.log(String(
                    format: "ParakeetEngine: slow stages VAD=%.2fs ASR=%.2fs vocab=%.2fs",
                    vadElapsed, asrElapsed, vocabElapsed))
            }

            // Strip words the decoder hallucinated over the silence pad we appended
            // (counts only in the log — never transcript content).
            let confidenceStrip = ParakeetEngine.strippingLowConfidenceTail(
                text: text, timings: result.tokenTimings)
            if confidenceStrip.removedTokenCount > 0 {
                DiagnosticLogger.shared.log(
                    "ParakeetEngine: stripped low-confidence tail (\(confidenceStrip.removedTokenCount) timing tokens)")
            }
            text = confidenceStrip.text

            let stripped = ParakeetEngine.strippingPadHallucination(
                text: text, timings: result.tokenTimings,
                realAudioSeconds: Double(speechSamples.count) / 16_000.0)
            if stripped.count != text.count {
                DiagnosticLogger.shared.log(String(
                    format: "ParakeetEngine: stripped pad hallucination (%d chars past %.2fs)",
                    text.count - stripped.count, Double(speechSamples.count) / 16_000.0))
            }
            let punctuationCorrection = enablePunctuationCommandCorrection
                ? ParakeetEngine.correctingPunctuationCommandHomophones(
                    text: stripped, timings: result.tokenTimings)
                : PunctuationCommandCorrectionResult(text: stripped, corrections: [])
            if !punctuationCorrection.corrections.isEmpty {
                DiagnosticLogger.shared.log(
                    "ParakeetEngine: confidence-guided punctuation corrected "
                        + punctuationCorrection.corrections.map {
                            String(format: "'%@'→'%@' (%.3f/%.3f, gap %.2fs)",
                                   $0.original, $0.replacement, $0.confidence,
                                   $0.takeMedian, $0.gapBefore)
                        }.joined(separator: ", "))
            }
            let minConfidence = result.tokenTimings?.map(\.confidence).min()
            let uncertain = result.confidence < 0.5 || (minConfidence.map { $0 < 0.3 } ?? false)
            onDiagnostics(TranscriptionDiagnostics(
                aggregateConfidence: result.confidence,
                minimumTokenConfidence: minConfidence,
                lowConfidenceTailTokensRemoved: confidenceStrip.removedTokenCount,
                vadTrimmedSeconds: vadTrimmedSeconds,
                uncertain: uncertain,
                lowConfidenceWords: ParakeetEngine.lowConfidenceWords(from: result.tokenTimings ?? []),
                inferencePath: path.rawValue))
            if uncertain {
                DiagnosticLogger.shared.log(String(
                    format: "ParakeetEngine: uncertain take (aggregate %.3f, min-token %.3f)",
                    result.confidence, minConfidence ?? -1))
            }
            return (punctuationCorrection.text, path)
        }

        // Synthetic setup seam: exercise the same lifecycle gate/task ownership without loading
        // a native model. Tests can hold noncooperative setup at a barrier, then call public unload.
        func loadAuxiliarySetupForTesting(
            vocabulary: @escaping @Sendable () async -> Void,
            endpointing: @escaping @Sendable () async -> Void,
            onAttempt: @Sendable () -> Void,
            onReady: @escaping @Sendable (String) -> Void
        ) async throws {
            onAttempt()
            await acquireLifecycle()
            defer { releaseLifecycle() }
            try Task.checkCancellation()
            await drainAuxiliarySetup()
            startAuxiliarySetup(
                vocabulary: { generation in
                    await vocabulary()
                    if await self.auxiliarySetupCanPublish(generation) { onReady("vocabulary") }
                }, endpointing: { generation in
                    await endpointing()
                    if await self.auxiliarySetupCanPublish(generation) { onReady("endpointing") }
                })
        }

        var lifecycleStateForTesting: (auxiliaryTasks: Int, queuedOperations: Int, tearingDown: Bool) {
            ((vocabSetupTask == nil ? 0 : 1) + (vadSetupTask == nil ? 0 : 1),
             lifecycleWaiters.count, tearingDown)
        }

        // MARK: Unload

        func unload() async {
            await acquireLifecycle()
            defer { releaseLifecycle() }
            unloadEpoch &+= 1
            // Gate new transcribes first, then publish the mirror false SYNCHRONOUSLY before niling
            // the manager — this closes the stale-mirror window where isLoaded == true but the
            // manager is already gone. Only then drain in-flight transcriptions and cleanup, so none
            // observe a cleaned-up manager.
            tearingDown = true
            onLoadedChange(false)
            while active > 0 { await Task.yield() }
            await drainAuxiliarySetup()
            let m = manager
            manager = nil
            loadedModelID = nil
            vocabSpotter = nil; vocabRescorer = nil; vocabContext = nil; vocabTermCount = 0
            vadManager = nil
            await m?.cleanup()
            await releaseStandInHoldingGate()
            tearingDown = false
            DiagnosticLogger.shared.log("ParakeetEngine: model unloaded")
        }
    }

    // MARK: - Facade state

    /// The serialized owner of all model state. Lazily wired so it can capture `self`'s mirror
    /// updater without an initializer ordering problem.
    private var core: Core!
    private let diagnosticsLock = NSLock()
    private var diagnosticsMirror: TranscriptionDiagnostics?

    /// Guards `keepModelLoaded` and the `isLoadedMirror` — the only fields the synchronous protocol
    /// surface touches. The actor owns everything else.
    private let stateLock = NSLock()

    /// Synchronous mirror of `Core.isLoaded`, updated under `stateLock` after a load/unload
    /// completes. The protocol's sync `isLoaded` getter reads this; it can lag a load/unload that is
    /// still in flight, which is the intended "has a model finished loading" semantics.
    private var isLoadedMirror = false

    /// How the model should be managed: "auto", "always", "off". Stored for parity with
    /// `WhisperEngine`; FluidAudio caches the compiled CoreML models on disk, so reload is cheap.
    private var keepModelLoadedStorage = "auto"

    /// Mirror of "a CPU stand-in is published", under `stateLock`.
    private var standInMirror = false

    // First-start preparation (ParakeetFirstStart.swift). All under `stateLock`.
    private struct Preparation {
        let id: UUID
        let modelID: String
        let signal: PreparationSignal
        var helper: CompileHelperHandle?
        var standInTask: Task<Void, Never>?
        var canceled = false
    }
    private var preparation: Preparation?
    /// The latest `prepareModel` phase callback, so a later Neural Engine retry can report
    /// `.ready`. Under `stateLock`, like the retry bookkeeping below.
    private var phaseHandler: (@Sendable (ModelPreparationPhase) -> Void)?
    private var neuralEngineRetry: Task<Void, Never>?
    private var lastNeuralEngineAttempt: CFAbsoluteTime = 0
    private var neuralEngineRetries = 0
    /// A failure that repeats every time is not retried forever (each try is a full compile).
    static let maxNeuralEngineRetries = 3
    /// After a failed Neural Engine load the CPU stand-in keeps serving; the Neural Engine load
    /// is retried in the background at the next dictation at most this often (10 minutes).
    let neuralEngineRetryIntervalSeconds: CFAbsoluteTime

    /// Starts the compile helper. Nil (tests, CLI, tools) keeps today's in-process load.
    let compileHelper: CompileHelperStarting?
    /// How long the helper may run before we assume it is compiling and load the CPU stand-in.
    /// A warm load takes about 0.2-0.3 s, so a helper still running at 1 s is compiling.
    let standInDelaySeconds: Double
    /// The stand-in holds about 1.2 GB resident (measured on a 64 GB M3 Max) for the length of
    /// the compile, alongside the compile itself; skip it on Macs with 8 GB or less.
    let standInAllowed: Bool
    /// Test seam: how many times a stand-in load was started.
    let standInAttemptsForTesting = LockedCounter()
    /// Test seam: replaces `prepareModel`'s Neural Engine load (to make it fail).
    let neuralEngineLoadForTesting: (@Sendable (String) async throws -> Void)?

    public convenience init() {
        self.init(compileHelper: ProcessCompileHelper.forRunningApp())
    }

    init(compileHelper: CompileHelperStarting?,
         standInDelaySeconds: Double = 1.0,
         standInAllowed: Bool = ProcessInfo.processInfo.physicalMemory > 8 * 1_073_741_824,
         neuralEngineLoadForTesting: (@Sendable (String) async throws -> Void)? = nil,
         neuralEngineRetryIntervalSeconds: CFAbsoluteTime = 600) {
        self.compileHelper = compileHelper
        self.neuralEngineRetryIntervalSeconds = neuralEngineRetryIntervalSeconds
        self.neuralEngineLoadForTesting = neuralEngineLoadForTesting
        self.standInDelaySeconds = standInDelaySeconds
        self.standInAllowed = standInAllowed
        self.core = Core(onLoadedChange: { [weak self] loaded in
            guard let self else { return }
            self.stateLock.lock()
            self.isLoadedMirror = loaded
            self.stateLock.unlock()
        }, onDiagnostics: { [weak self] diagnostics in
            // Runs inside the caller's task, so the take's own recorder gets exactly this
            // pass's diagnostics (see TakeRecorder).
            TakeRecorder.current?.engineDiagnostics = diagnostics
            guard let self else { return }
            self.diagnosticsLock.lock()
            self.diagnosticsMirror = diagnostics
            self.diagnosticsLock.unlock()
        }, onStandInChange: { [weak self] present in
            guard let self else { return }
            self.stateLock.lock()
            self.standInMirror = present
            self.stateLock.unlock()
        })
    }

    // MARK: - TranscriptionEngine identity

    public var engineID: String { "parakeet" }
    public var lastDiagnostics: TranscriptionDiagnostics? {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return diagnosticsMirror
    }

    public var supportsStreaming: Bool { false }

    /// Parakeet has no prompt/initial-text knob — `transcribe`'s `prompt` is ignored, so
    /// prompt-building work (screen-context OCR) must be skipped for this engine.
    public var supportsPrompt: Bool { false }

    public var isLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isLoadedMirror
    }

    /// Synchronous critical section on `stateLock` (callable from async code).
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// True when a take could start right now: the Neural Engine model is loaded, or the CPU
    /// stand-in is serving while it is prepared.
    public var canTranscribeNow: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isLoadedMirror || standInMirror
    }

    public var keepModelLoaded: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return keepModelLoadedStorage
        }
        set {
            stateLock.lock()
            keepModelLoadedStorage = newValue
            stateLock.unlock()
        }
    }

    // MARK: - Model Lifecycle

    /// Ensure the FluidAudio models for `modelID` are downloaded + loaded, then construct and load
    /// an `AsrManager`. Idempotent and single-flight: concurrent calls coalesce, and a no-op if the
    /// same model is already loaded.
    ///
    /// - Parameter modelID: "parakeet-tdt-0.6b-v2" or "parakeet-tdt-0.6b-v3".
    ///
    /// While `prepareModel` is running for the same model this waits until a take can run (CPU
    /// stand-in or Neural Engine ready) instead of starting a second, in-process compile, which
    /// would also block the stand-in's load.
    public func loadModel(modelID: String) async throws {
        let signal = withState {
            preparation.flatMap { $0.modelID == modelID && !$0.canceled ? $0.signal : nil }
        }
        if let signal { await signal.wait() }
        // A CPU stand-in that is serving (during preparation, or kept after a failed Neural
        // Engine load) takes the dictation now; the take never waits on a compile.
        if await core.canTranscribe(modelID: modelID) {
            await retryNeuralEngineIfDue(modelID)
            return
        }
        try await core.load(modelID: modelID)
        // Clears a "failed" menu line left by the launch-time preparation.
        let handler = withState { phaseHandler }
        handler?(.ready)
    }

    /// While the CPU stand-in is serving after a failed Neural Engine load, retry that load in
    /// the background (at most every 10 minutes and 3 times per session, triggered by a
    /// dictation). On success the stand-in is released and the menu clears. The dictation
    /// itself never waits for it.
    private func retryNeuralEngineIfDue(_ modelID: String) async {
        let core: Core = self.core
        // Read first: an unload after this point makes the retry's load refuse itself.
        let epoch = await core.epoch
        let now = CFAbsoluteTimeGetCurrent()
        // The retry task is created and stored in one critical section, so its own clean-up
        // (which takes the same lock) can never run before the handle is stored.
        withState {
            guard !isLoadedMirror, preparation == nil, neuralEngineRetry == nil,
                  neuralEngineRetries < Self.maxNeuralEngineRetries,
                  now - lastNeuralEngineAttempt >= neuralEngineRetryIntervalSeconds else { return }
            lastNeuralEngineAttempt = now
            neuralEngineRetries += 1
            neuralEngineRetry = Task.detached(priority: .utility) { [weak self] in
                do {
                    try await core.load(modelID: modelID, ifEpoch: epoch)
                    await core.releaseStandIn()
                    DiagnosticLogger.shared.log("ParakeetEngine: Neural Engine load succeeded on retry; CPU stand-in released")
                    if let self {
                        let handler = self.withState { self.phaseHandler }
                        handler?(.ready)
                    }
                } catch {
                    DiagnosticLogger.shared.log(
                        "ParakeetEngine: Neural Engine retry failed (\(error.localizedDescription)); CPU stand-in keeps serving")
                }
                if let self { self.withState { self.neuralEngineRetry = nil } }
            }
        }
    }

    /// First load of a launch, run in the background at app start (and so after every update).
    /// Compiles for the Neural Engine in a helper process while a CPU-only stand-in serves any
    /// dictation, then loads the now-warm Neural Engine model in-process and releases the
    /// stand-in. Without a helper (tests, CLI) this is the plain in-process load. `onPhase` gets
    /// every phase change for the menu. Safe to call again: a loaded model returns `.ready`.
    public func prepareModel(modelID: String,
                             onPhase: @escaping @Sendable (ModelPreparationPhase) -> Void = { _ in }) async {
        // Registered before anything is awaited, so a take that arrives now waits for this
        // preparation instead of starting its own in-process compile.
        let id = UUID()
        let signal = PreparationSignal()
        withState {
            if let previous = preparation { previous.helper?.cancel(); previous.standInTask?.cancel() }
            preparation = Preparation(id: id, modelID: modelID, signal: signal)
            phaseHandler = onPhase
        }
        func isCurrent() -> Bool {
            withState { preparation?.id == id && preparation?.canceled == false }
        }
        func finish() async {
            withState { if preparation?.id == id { preparation = nil } }
            await signal.fire()
        }

        if await core.isLoaded(modelID: modelID) {
            await finish()
            onPhase(.ready)
            return
        }
        // Every load below is refused if an unload runs after this point (engine discarded).
        let epoch = await core.epoch
        let start = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String { String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start) }
        guard let helper = compileHelper?.start(modelID: modelID) else {
            onPhase(.preparing(standInReady: false))
            var loaded = false
            if isCurrent() { loaded = (try? await loadNeuralEngine(modelID, epoch: epoch)) != nil }
            let canceled = !isCurrent()
            await finish()
            if !canceled { onPhase(loaded ? .ready : .failed) }
            return
        }
        withState { if preparation?.id == id { preparation?.helper = helper } }
        if !isCurrent() { helper.cancel() }  // unloaded while the helper was starting
        DiagnosticLogger.shared.log("ParakeetEngine: compile helper started for \(modelID)")
        onPhase(.preparing(standInReady: false))

        let helperDone = LockedCounter()
        let allowed = standInAllowed
        let attempts = standInAttemptsForTesting
        let core: Core = self.core
        // Loads the stand-in and announces it. `shouldStart` is re-checked under the engine's
        // lifecycle gate, so a helper that finished meanwhile never queues the Neural Engine
        // load behind an unneeded 1.2 GB CPU load.
        let loadStandIn: @Sendable (@escaping @Sendable () -> Bool) async -> Void = { shouldStart in
            guard allowed else {
                DiagnosticLogger.shared.log("ParakeetEngine: CPU stand-in skipped (8 GB of memory or less)")
                return
            }
            attempts.increment()
            let standInStart = CFAbsoluteTimeGetCurrent()
            do {
                if try await core.loadStandIn(modelID: modelID, ifEpoch: epoch, shouldStart: shouldStart) {
                    DiagnosticLogger.shared.log(String(format: "ParakeetEngine: CPU stand-in ready in %.2f s (resident %d MB)",
                        CFAbsoluteTimeGetCurrent() - standInStart, processResidentMB()))
                    onPhase(.preparing(standInReady: true))
                    await signal.fire()
                }
            } catch is CancellationError {
                return  // preparation moved on (helper finished or engine discarded)
            } catch {
                DiagnosticLogger.shared.log(
                    "ParakeetEngine: CPU stand-in unavailable (\(error.localizedDescription))")
            }
        }
        let delay = standInDelaySeconds
        let standInBegan = LockedCounter()
        let standInTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // A helper that finished within the delay found a warm cache: no stand-in needed.
            guard !Task.isCancelled, !helperDone.isSet else { return }
            standInBegan.set()
            await loadStandIn { !helperDone.isSet }
        }
        withState { if preparation?.id == id { preparation?.standInTask = standInTask } }

        let compiled = await helper.wait()
        helperDone.set()
        DiagnosticLogger.shared.log(
            "ParakeetEngine: compile helper \(compiled ? "finished" : "failed or stopped") after \(elapsed()) s")
        // A stand-in still sitting out its delay is not waited for: after a successful helper
        // the warm Neural Engine load follows at once, and after a failed one the stand-in is
        // loaded right below. One already loading is allowed to finish.
        if !standInBegan.isSet { standInTask.cancel() }
        await standInTask.value

        var loaded = false
        if isCurrent() {
            if !compiled, await !core.canTranscribe(modelID: modelID) {
                // The in-process compile below would block a stand-in load for its whole
                // duration, so load the stand-in first; its inference is not blocked by it.
                await loadStandIn { true }
            }
            // Warm after a successful helper (about 0.2 s); after a failed one, the old
            // in-process compile. Refused (epoch) if the engine was unloaded meanwhile.
            if isCurrent() {
                loaded = (try? await loadNeuralEngine(modelID, epoch: epoch)) != nil
            }
        }
        let canceled = !isCurrent()
        // Release only once the Neural Engine model is there. After a failed load a working
        // stand-in keeps serving; unload (the only other way out) releases it itself.
        if loaded, !canceled { await core.releaseStandIn() }
        let standInKept = await core.canTranscribe(modelID: modelID) && !loaded
        if standInKept { withState { lastNeuralEngineAttempt = CFAbsoluteTimeGetCurrent() } }
        await finish()
        guard !canceled else { return }
        DiagnosticLogger.shared.log(
            "ParakeetEngine: first-start preparation \(loaded ? "ready" : (standInKept ? "failed, CPU stand-in kept" : "failed")) after \(elapsed()) s")
        onPhase(loaded ? .ready : (standInKept ? .cpuFallback : .failed))
    }

    /// The Neural Engine load of `prepareModel`; tests can make it fail.
    private func loadNeuralEngine(_ modelID: String, epoch: UInt64) async throws {
        if let override = neuralEngineLoadForTesting {
            try await override(modelID)
        } else {
            try await core.load(modelID: modelID, ifEpoch: epoch)
        }
    }

    /// Release the FluidAudio models and drop the manager. Waits for in-flight loads,
    /// transcriptions, and optional model setup before teardown. Stops a running first-start
    /// preparation (its helper process is terminated).
    public func unloadModel() async {
        withState {
            if preparation != nil {
                preparation?.canceled = true
                preparation?.helper?.cancel()
                preparation?.standInTask?.cancel()
            }
            neuralEngineRetry?.cancel()
        }
        await core.unload()
    }

    func loadAuxiliarySetupForTesting(
        vocabulary: @escaping @Sendable () async -> Void,
        endpointing: @escaping @Sendable () async -> Void,
        onAttempt: @Sendable () -> Void = {},
        onReady: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        try await core.loadAuxiliarySetupForTesting(vocabulary: vocabulary, endpointing: endpointing,
                                                   onAttempt: onAttempt, onReady: onReady)
    }

    var lifecycleStateForTesting: (auxiliaryTasks: Int, queuedOperations: Int, tearingDown: Bool) {
        get async { await core.lifecycleStateForTesting }
    }

    /// No-op. FluidAudio runs on the Apple Neural Engine via CoreML and manages its own memory;
    /// it does not contend with whisper.cpp's Metal/GPU path and exposes no memory-pressure hook
    /// analogous to `WhisperEngine`'s context teardown. Unloading is driven explicitly via
    /// `unloadModel()` and the keep-loaded policy at the `Transcriber` layer.
    public func startMemoryPressureMonitoring() {}

    // MARK: - Transcription

    /// True when every Silero model bundle FluidAudio's VadManager loads is on disk. Existence
    /// only; a corrupt bundle still fails the offline load and logs "endpointing unavailable".
    static func sileroModelCached(
        modelsDirectory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio/Models")
    ) -> Bool {
        guard let modelsDirectory else { return false }
        let dir = modelsDirectory.appendingPathComponent(Repo.vad.folderName)
        return ModelNames.VAD.requiredModels.allSatisfy { name in
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(name).appendingPathComponent("coremldata.bin").path)
        }
    }

    /// Set after one failed Silero fetch so later model loads skip the network (per process).
    static let sileroFetchFailed = LockedFlag()

    /// Transcribe `[Float]` 16 kHz mono samples. Parakeet has no ASR equivalent of whisper's
    /// prompt / token suppression, but their spoken-punctuation mode signal gates the confidence
    /// corrector so Off mode remains byte-faithful to Parakeet's lexical output.
    ///
    /// - Parameter language: short language code ("en", "fr", …) or "auto". The hint is only
    ///   forwarded to FluidAudio for v3 (multilingual); v2 is English-only and ignores it.
    public func transcribe(samples: [Float],
                           language: String,
                           prompt: String?,
                           suppressRegex: String?) async throws -> String {
        try await transcribe(
            samples: samples, language: language, prompt: prompt,
            suppressRegex: suppressRegex, enablePunctuationCommandCorrection: false)
    }

    /// Transcriber's Parakeet-specific path carries the resolved punctuation mode explicitly.
    /// Keeping it separate from the ASR prompt matters because prompt-budget truncation can remove
    /// the spoken-punctuation instruction while the user's mode is still Hybrid.
    func transcribe(samples: [Float],
                    language: String,
                    prompt: String?,
                    suppressRegex: String?,
                    enablePunctuationCommandCorrection: Bool) async throws -> String {
        try await core.transcribe(
            samples: samples, language: language,
            enablePunctuationCommandCorrection: enablePunctuationCommandCorrection).text
    }

    func transcribeReportingPath(samples: [Float], language: String, prompt: String?,
                                 suppressRegex: String?, enablePunctuationCommandCorrection: Bool)
        async throws -> (text: String, inferencePath: String) {
        let result = try await core.transcribe(
            samples: samples, language: language,
            enablePunctuationCommandCorrection: enablePunctuationCommandCorrection)
        return (result.text, result.path.rawValue)
    }

    /// Parakeet (batch `AsrManager`) does not support live preview. Streaming would require
    /// FluidAudio's separate `StreamingAsrManager` / `SlidingWindowAsrManager`.
    public func transcribeStreaming(samples: [Float],
                                    language: String,
                                    prompt: String?,
                                    suppressRegex: String?,
                                    onPartialResult: @escaping (String) -> Void) async throws -> String {
        throw TranscriptionEngineError.streamingUnsupported
    }

    // MARK: - Helpers

    /// Compute the FluidAudio `Language?` hint. For v3, returns an explicit `Language(rawValue:)` on
    /// the region-stripped code for any concrete code (including "en"); returns nil only for
    /// auto/empty codes. Always nil for v2 (English-only, ignores it).
    /// Internal so tests exercise the real rule instead of a mirror.
    static func languageHint(for language: String, isV3: Bool) -> Language? {
        guard isV3 else { return nil }
        let code = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty, code != "auto" else { return nil }
        let primary = stripRegionSubtag(code)
        return Language(rawValue: primary)
    }

    /// Strip an IETF region subtag: "en-US"/"en_US" → "en".
    static func stripRegionSubtag(_ code: String) -> String {
        if let primary = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            return String(primary)
        }
        return code
    }

    /// Map FluidAudio `ASRError` into speakfree's engine-agnostic `TranscriptionEngineError`.
    private static func map(_ error: ASRError, modelID: String) -> TranscriptionEngineError {
        switch error {
        case .notInitialized:
            return .modelNotLoaded
        case .modelLoadFailed, .modelCompilationFailed:
            return .modelLoadFailed(modelID)
        case .invalidAudioData,
             .processingFailed,
             .unsupportedPlatform,
             .streamingConversionFailed,
             .fileAccessFailed:
            return .transcriptionFailed
        }
    }
}

/// A thread-safe Bool for process-wide latches read from actor and nonisolated code.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Lock-guarded counter, used as a set-once flag ("the helper has exited") and as the
/// stand-in attempt count.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func set() { lock.lock(); count = max(count, 1); lock.unlock() }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
