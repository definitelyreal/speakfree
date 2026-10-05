// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-10-04
import Foundation

/// Decides whether text from a Whisper rescue or Whisper engine is very likely invented.
///
/// On 2026-10-04 (7:54 to 8:10pm PT, an airplane cabin) the empty-take Whisper rescue typed
/// "*Dramatic music*", "Thank you.", "- Thank you.", "- I'm gonna use your space." and
/// "- Do you have somebody to do this? - Yes." into Claude. Parakeet had heard nothing in every
/// one of those takes. These are Whisper's well-known outputs on noise: stock video phrases,
/// sound descriptions in brackets or asterisks, and subtitle dialogue dashes.
///
/// Three kinds of evidence are combined. In rescue mode, outputs composed entirely of stock
/// phrases are refused unless Parakeet agrees, even on voiced audio. This deliberately trades
/// missed short replies for fewer invented inserts; audio-only thresholds remain heuristic:
/// 1. The words: the whole output is a stock phrase or a sound tag (`isStockPhrase`), or starts
///    with a subtitle dialogue dash.
/// 2. Parakeet: it returned nothing (or one word) on the same take, or something different.
/// 3. The audio: `NoiseVerdict`. The MacBook microphone in the cabin recorded a loud level
///    that never dipped (10th-percentile 0.12 to 0.14 RMS) with a speech band (300 to
///    3,400 Hz) that barely rose and fell (90th/10th percentile 1.29 to 1.42). Real speech in a
///    loud room still rises and falls in that band (1.9 to 3.0 on 2026-08-13, same microphone,
///    same level). The existing static judge covers headset hiss.
///
/// Phrase list: a hand-picked subset of the "Bag of Hallucinations" from Barański et al.,
/// "Investigation of Whisper ASR Hallucinations Induced by Non-Speech Audio" (ICASSP 2025),
/// github.com/DSP-AGH/ICASSP2025_Whisper_Hallucination, MIT License, Copyright (c) 2025 Digital
/// Signal Processing Group. Only entries that are video or caption artifacts or sound words are
/// kept; everyday phrases on that list ("I don't know", "here we go") are left out because
/// they are also things people dictate. The bracket, asterisk and music-note forms follow the
/// non-speech symbols that OpenAI Whisper's tokenizer suppresses (github.com/openai/whisper,
/// MIT License, Copyright (c) 2022 OpenAI).
public enum WhisperHallucinationGuard {
    public struct Verdict: Equatable {
        public let block: Bool
        /// Short reason for the log, nil when the text may insert.
        public let reason: String?
        public let noise: NoiseVerdict
    }

    /// Audio evidence over a whole take (16 kHz samples).
    public struct NoiseVerdict: Equatable {
        /// The existing static judge (headset hiss: no low band, many crossings, flat).
        public let isStatic: Bool
        /// 10th-percentile level of 100 ms windows, full band: the quietest the take ever got.
        public let floorRMS: Float
        /// 90th/10th percentile level of 50 ms windows in the 300 to 3,400 Hz speech band.
        public let speechBandRange: Float
        public let seconds: Double

        /// No speech envelope: static, or loud throughout with a flat speech band.
        public var isNoiseOnly: Bool {
            isStatic || (seconds >= minimumSeconds && floorRMS >= loudFloorRMS
                         && speechBandRange < flatSpeechBandRange)
        }
        /// A looser reading, used only together with a stock phrase or a dialogue dash.
        public var leansNoise: Bool {
            isStatic || (seconds >= minimumSeconds && floorRMS >= leaningFloorRMS
                         && speechBandRange < leaningSpeechBandRange)
        }

        public var summary: String {
            String(format: "floor %.3f, speech-band range %.2f, %.1f s%@", floorRMS, speechBandRange,
                   seconds, isStatic ? ", static" : "")
        }
    }

    // Thresholds set on the recordings folder (2026-10-04, `perf-harness hallucination-replay`
    // over the 22,179 takes with text). `isNoiseOnly` holds for 9 of them: the 2026-09-25
    // AirPods static takes and the 2026-10-04 cabin takes (all Whisper inventions), one more
    // Parakeet-empty take, and two low-confidence airplane takes from 2026-08-19 where Parakeet
    // did type text (this guard never touches Parakeet's own text). It holds for none of the
    // 8,673 takes Parakeet scored 0.9 or higher; neither does `leansNoise`.
    static let minimumSeconds: Double = 1.5
    static let loudFloorRMS: Float = 0.05
    static let flatSpeechBandRange: Float = 1.45
    static let leaningFloorRMS: Float = 0.03
    static let leaningSpeechBandRange: Float = 1.6

    /// - Parameters:
    ///   - whisperText: what Whisper returned.
    ///   - samples: the take, 16 kHz mono.
    ///   - parakeetText: what Parakeet returned on the same take, or nil when Parakeet did not
    ///     run (Whisper is the chosen engine).
    public static func assess(whisperText: String, samples: [Float], parakeetText: String?) -> Verdict {
        assess(whisperText: whisperText, noise: noiseVerdict(samples), parakeetText: parakeetText)
    }

    public static func assess(whisperText: String, noise: NoiseVerdict, parakeetText: String?) -> Verdict {
        let stripped = stripDialogueDash(whisperText)
        guard !normalized(stripped).isEmpty || isSoundTag(stripped) else {
            return Verdict(block: false, reason: nil, noise: noise)
        }
        let stock = isStockPhrase(stripped)
        let dash = hasDialogueDash(whisperText)
        guard let parakeetText else {
            // Whisper is the chosen engine: no second opinion, so the audio has to carry it.
            if stock && noise.leansNoise {
                return Verdict(block: true, reason: "stock phrase on noise", noise: noise)
            }
            // Static: the same two-word bar Parakeet takes get (Transcriber drops <= 2 words).
            if noise.isStatic && normalized(stripped).split(separator: " ").count <= 2 {
                return Verdict(block: true, reason: "a word or two read out of static", noise: noise)
            }
            if dash && noise.isNoiseOnly {
                return Verdict(block: true, reason: "subtitle dash on noise", noise: noise)
            }
            return Verdict(block: false, reason: nil, noise: noise)
        }
        let parakeetNormalized = normalized(parakeetText)
        // Parakeet heard the same words: real speech, whatever the room sounded like.
        if !parakeetNormalized.isEmpty, parakeetNormalized == normalized(stripped) {
            return Verdict(block: false, reason: nil, noise: noise)
        }
        let parakeetNearEmpty = parakeetNormalized.split(separator: " ").count <= 1

        if stock {
            return Verdict(block: true, reason: "stock phrase Parakeet did not hear", noise: noise)
        }
        if parakeetNearEmpty && noise.isNoiseOnly {
            return Verdict(block: true, reason: "noise only and Parakeet heard nothing", noise: noise)
        }
        if parakeetNearEmpty && dash && noise.leansNoise {
            return Verdict(block: true, reason: "subtitle dash on noise and Parakeet heard nothing", noise: noise)
        }
        return Verdict(block: false, reason: nil, noise: noise)
    }

    // MARK: - Text

    /// Sentence or clause ends for the stock check: ". ", "! ", ", " and so on, or the end
    /// ("Amara.org" stays whole; "Thank you, bye." is two stock clauses).
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?…,]+(?:\s+|$)|\n"#)
    /// A dash (hyphen, the U+2010 to U+2015 dashes, or the U+2212 minus sign), then either a
    /// space and a word, or straight into a capital letter or quote ("-Do you", "—I'm").
    private static let leadingDash = try! NSRegularExpression(
        pattern: #"^\s*[-\x{2010}-\x{2015}\x{2212}]+(?:\s+(?=[\p{L}"'\x{201C}\x{2018}])|(?=[\p{Lu}"'\x{201C}\x{2018}]))"#)

    /// True when the text opens like a subtitle line: a dash, a space, then a word. Not a
    /// minus sign ("- 5 degrees") and not a dictated list (two or more lines starting "- ").
    public static func hasDialogueDash(_ text: String) -> Bool {
        guard !isDashedList(text) else { return false }
        return leadingDash.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isDashedList(_ text: String) -> Bool {
        text.components(separatedBy: "\n").filter { leadingDash.firstMatch(
            in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.count >= 2
    }

    /// Removes one leading subtitle dialogue dash ("- Thank you." -> "Thank you."). A minus
    /// sign ("-5", "- 5 degrees") and a dictated dashed list are kept.
    public static func stripDialogueDash(_ text: String) -> String {
        guard !isDashedList(text) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return leadingDash.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Lowercased words only, the form the phrase list uses ("I'm" -> "i m").
    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastWasSpace = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar); lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" "); lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let soundLabels: Set<String> = [
        "music", "dramatic music", "upbeat music", "background music", "outro music",
        "applause", "laughter", "laughing", "clapping", "silence", "noise", "background noise",
        "blank audio", "inaudible", "no speech", "click", "clicking", "sigh", "sighs", "sighing",
        "clears throat", "bell rings", "bells chiming", "birds chirp", "siren blares", "fans roar",
    ]

    /// Only recognized sound labels inside [], (), or ** count as sound tags. Wrapping an
    /// ordinary sentence is formatting, not evidence of hallucination. Music-note notation
    /// retains the existing caption rule.
    static func isSoundTag(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let tag = #"\[[^\[\]]*\]|\([^()]*\)|\*[^*]+\*|[♪♫♬♩]+(?:[^♪♫♬♩]*[♪♫♬♩]+)?"#
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let regex = try? NSRegularExpression(pattern: tag) else { return false }
        let matches = regex.matches(in: trimmed, range: range)
        guard !matches.isEmpty, matches.allSatisfy({ match in
            guard let r = Range(match.range, in: trimmed) else { return false }
            let piece = String(trimmed[r])
            if let first = piece.first, "♪♫♬♩".contains(first) { return true }
            return soundLabels.contains(normalized(String(piece.dropFirst().dropLast())))
        }) else { return false }
        let rest = regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
        return normalized(rest).isEmpty
    }

    /// The whole output (after a leading dialogue dash) is a sound tag, or every sentence in it
    /// is a stock phrase or a caption credit ("Thank you.", "Thank you. Thank you.", "- Bye.").
    public static func isStockPhrase(_ text: String) -> Bool {
        let body = stripDialogueDash(text)
        if isSoundTag(body) { return true }
        let marked = sentenceEnd.stringByReplacingMatches(
            in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "\n")
        let sentences = marked.components(separatedBy: "\n")
            .map { normalized(stripDialogueDash($0)) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return false }
        return sentences.allSatisfy { sentence in
            stockPhrases.contains(sentence) || creditPrefixes.contains {
                sentence == $0 || sentence.hasPrefix($0 + " ")
            }
        }
    }

    /// Normalized forms (see `normalized`). Video and caption artifacts, single-word fillers
    /// Whisper is known for, and sound words.
    static let stockPhrases: Set<String> = [
        // Fillers (the existing Transcriber list) and closers.
        "you", "thank you", "thank you very much", "thank you so much", "thanks", "bye", "bye bye",
        "the end", "music", "applause", "laughter", "silence", "noise", "blank audio",
        // Bag of Hallucinations: video outros and intros.
        "thanks for watching", "thank you for watching", "a thank you for watching",
        "thank you so much for watching", "thanks for listening", "thank you for listening",
        "please subscribe to my channel", "like and subscribe", "don t forget to subscribe",
        "don t forget to like and subscribe", "see you next time", "we ll see you next time",
        "see you in the next video", "we ll be right back", "so until next time bye for now",
        "welcome to my channel", "hello everyone welcome to my channel",
        "hi guys welcome back to my channel", "welcome to another episode of the",
        "hello and welcome to another episode of the", "outro music", "audio jungle", "audiojungle",
        // Bag of Hallucinations: sound words.
        "woof", "beeping", "bell rings", "bells chiming", "birds chirp", "siren blares",
        "fans roar", "shh", "pfft", "vroom", "grr rr",
    ]

    /// Caption credits Whisper copies from subtitle files.
    static let creditPrefixes: [String] = [
        "subtitles by", "captions by", "captioned by", "closed captioning", "transcription by",
        "transcribed by", "translated by", "translation by",
    ]

    // MARK: - Audio

    public static func noiseVerdict(_ samples: [Float]) -> NoiseVerdict {
        let windows = CaptureStaticJudge.windows(of: samples)
        let isStatic = CaptureStaticJudge.isStatic(windows, minimumWindows: CaptureStaticJudge.wholeTakeMinimumWindows)
        let floor = percentile(windows.map(\.rms), 0.1)
        return NoiseVerdict(isStatic: isStatic, floorRMS: floor,
                            speechBandRange: speechBandRange(samples),
                            seconds: Double(samples.count) / 16_000)
    }

    static let speechBandWindow = 800 // 50 ms at 16 kHz

    /// 90th/10th percentile of 50 ms window levels after a 300 to 3,400 Hz band-pass
    /// (two 2nd-order Butterworth high-pass sections, then two low-pass sections). Engine and
    /// cabin rumble sit below 300 Hz, so the band shows whether a voice rose and fell.
    static func speechBandRange(_ samples: [Float]) -> Float {
        guard samples.count >= speechBandWindow * 2 else { return 0 }
        var filters = [Biquad.highPass(300, q: 0.5411961), Biquad.highPass(300, q: 1.3065630),
                       Biquad.lowPass(3_400, q: 0.5411961), Biquad.lowPass(3_400, q: 1.3065630)]
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / speechBandWindow)
        var energy: Float = 0
        var count = 0
        for raw in samples {
            var y = raw.isFinite ? raw : 0
            for i in filters.indices { y = filters[i].process(y) }
            energy += y * y; count += 1
            if count == speechBandWindow {
                levels.append((energy / Float(count)).squareRoot())
                energy = 0; count = 0
            }
        }
        let p10 = percentile(levels, 0.1)
        let p90 = percentile(levels, 0.9)
        return p90 / max(p10, 1e-7)
    }

    private static func percentile(_ values: [Float], _ q: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * q)]
    }

    /// RBJ cookbook biquad at 16 kHz.
    private struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        static func highPass(_ hz: Double, q: Double) -> Biquad { make(hz, q: q, high: true) }
        static func lowPass(_ hz: Double, q: Double) -> Biquad { make(hz, q: q, high: false) }

        private static func make(_ hz: Double, q: Double, high: Bool) -> Biquad {
            let w = 2 * Double.pi * hz / 16_000
            let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
            let b0 = high ? (1 + c) / 2 : (1 - c) / 2
            let b1 = high ? -(1 + c) : 1 - c
            return Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b0 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}
