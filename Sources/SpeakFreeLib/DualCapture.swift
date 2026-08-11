// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
import AudioToolbox
import AVFoundation
import CoreAudio
import CTryCatch
import Foundation

/// Dual-mic capture: keep the always-on/pre-roll stream on the built-in microphone,
/// open Bluetooth only while a dictation is active, then conservatively combine the
/// two independently-produced transcripts.
///
/// When engaged: the ALWAYS-ON engine is pinned to the built-in mic (pre-roll lives
/// there, and the AirPods are released to A2DP while idle — the whole point), and a
/// SECOND stream on an available Bluetooth input is opened only for the duration of a
/// recording. The built-in track supplies reliable boundaries; aligned Bluetooth text
/// supplies the close-field middle. Both source tracks and transcripts remain in the
/// corpus so future recordings can tighten the merge policy without losing evidence.
public enum DualCapture {

    /// The primary may be pinned to the built-in mic even before Bluetooth is present.
    /// That guarantees connecting AirPods never turns the idle pre-roll engine into an
    /// HFP/SCO stream and degrades playback.
    public static func shouldUseBuiltInPrimary(
        flagOn: Bool, pinnedUID: String?, hasBuiltIn: Bool
    ) -> Bool {
        flagOn && pinnedUID == nil && hasBuiltIn
    }

    /// A second stream engages only when both source devices are actually available.
    public static func shouldEngage(
        flagOn: Bool, pinnedUID: String?, hasBuiltIn: Bool, hasBluetooth: Bool
    ) -> Bool {
        shouldUseBuiltInPrimary(flagOn: flagOn, pinnedUID: pinnedUID, hasBuiltIn: hasBuiltIn)
            && hasBluetooth
    }

    /// A primary that is explicitly or implicitly pinned does not need rebuilding when
    /// the system default changes. This is also the circuit break that prevents our own
    /// device binding from creating an AVAudioEngine configuration-change feedback loop.
    public static func primaryFollowsSystemDefault(
        flagOn: Bool, pinnedUID: String?, hasBuiltIn: Bool
    ) -> Bool {
        pinnedUID == nil
            && !shouldUseBuiltInPrimary(
                flagOn: flagOn, pinnedUID: pinnedUID, hasBuiltIn: hasBuiltIn)
    }

    /// Word-level agreement between two transcriptions (0…1): LCS length over the
    /// longer token count, case/punctuation-insensitive. Drives the corpus verdict on
    /// whether the Bluetooth track ever beats the built-in one.
    public static func tokenAgreement(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty || !tb.isEmpty else { return 1 }
        guard !ta.isEmpty && !tb.isEmpty else { return 0 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: tb.count + 1), count: ta.count + 1)
        for i in 1...ta.count {
            for j in 1...tb.count {
                dp[i][j] = ta[i-1] == tb[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1])
            }
        }
        return Double(dp[ta.count][tb.count]) / Double(max(ta.count, tb.count))
    }

    /// Ceiling on how long finalization waits for the Bluetooth comparison track.
    /// Normal stop resolves in tens of ms; the only thing past this deadline is a
    /// wedged Bluetooth HAL (or a very short dictation still draining the start
    /// sleeps, whose BT track would be useless anyway). Primary-only beats waiting.
    static let secondaryResultTimeout: TimeInterval = 1.0

    enum MergeReason: String, Equatable {
        case primaryOnly
        case bluetoothOnly
        case identical
        case aligned
        case insufficientAlignment
        /// Bluetooth dropped words the primary heard between two anchors (BT dropout).
        /// Importing its middle would DELETE spoken words — possibly a negation — so
        /// the complete primary wins outright.
        case bluetoothOmission
        /// A between-anchor substitution would lose a negation the primary heard
        /// ("do not forward" → "do please forward" inverts the sentence). Contraction
        /// swaps ("did not"→"didn't") keep the negation on both sides and still merge.
        case negationRisk
        /// The merge would damage spoken punctuation (2026-07-21 corpus): Bluetooth
        /// mishears command words ("slash"→"flash") or re-inserts one the primary
        /// already rendered as punctuation ("later," + BT's "comment" for a spoken
        /// comma). Both classes keep the primary verbatim.
        case punctuationRisk
        /// A substitution would lose a user vocabulary/glossary term the primary heard
        /// ("my EC2"→"my PC2"). Curated terms outrank Bluetooth wording.
        case vocabularyRisk
    }

    struct MergeResult: Equatable {
        let text: String
        let usedBluetooth: Bool
        let confidence: Double
        let matchedTokens: Int
        let reason: MergeReason
    }

    enum ForkBReason: Equatable {
        case identical
        case bluetoothTooShort
        case mergeVeto
        case primaryHasFewerUnknownWords
        case tied
        case bluetoothHasFewerUnknownWords
    }

    struct ForkBDecision: Equatable {
        let preferBluetooth: Bool
        let primaryUnknownWords: Int
        let bluetoothUnknownWords: Int
        let reason: ForkBReason
    }

    static let forkBCommonWords: Set<String> = Set("""
        a about after again all also am an and any are as at back be because been before being
        better both but by can come could day did do does done down each even every first for
        from get give go going good got had has have he her here him his how i if in into is it
        its just keep know last like look made make many may me might more most much my need new
        no not now of off ok okay on one only or other our out over package people please put
        putting really right said same say see send should shots so some something still such take
        than that the their them then there these they thing things think this through time to
        together too two up us use very want was way we well were what when where which who why
        will with work would yeah yes you your commas comments periods report today tomorrow
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    static func forkBDecision(
        primary: String,
        bluetooth: String,
        vocabularyWords: Set<String>,
        commonWords: Set<String> = forkBCommonWords
    ) -> ForkBDecision {
        let primaryTokens = wordTokens(in: primary).map(\.normalized)
        let bluetoothTokens = wordTokens(in: bluetooth).map(\.normalized)
        guard primaryTokens != bluetoothTokens else {
            return ForkBDecision(
                preferBluetooth: false, primaryUnknownWords: 0, bluetoothUnknownWords: 0,
                reason: .identical)
        }
        if primaryTokens.isEmpty, bluetoothTokens.count >= 2 {
            return ForkBDecision(
                preferBluetooth: true,
                primaryUnknownWords: 0,
                bluetoothUnknownWords: 0,
                reason: .bluetoothHasFewerUnknownWords)
        }
        let minimumBluetoothWords = Int(ceil(Double(primaryTokens.count) * 0.8))
        guard !primaryTokens.isEmpty, bluetoothTokens.count >= minimumBluetoothWords else {
            return ForkBDecision(
                preferBluetooth: false, primaryUnknownWords: 0, bluetoothUnknownWords: 0,
                reason: .bluetoothTooShort)
        }

        let normalizedVocabulary = Set(vocabularyWords.flatMap { term in
            wordTokens(in: term).map(\.normalized)
        })
        let protectedWords = normalizedVocabulary
        let merge = mergeTranscripts(
            primary: primary, bluetooth: bluetooth, protectedWords: protectedWords)
        switch merge.reason {
        case .bluetoothOmission, .negationRisk, .punctuationRisk, .vocabularyRisk:
            return ForkBDecision(
                preferBluetooth: false, primaryUnknownWords: 0, bluetoothUnknownWords: 0,
                reason: .mergeVeto)
        default:
            break
        }

        let knownWords = commonWords.union(normalizedVocabulary)
        let primaryUnknown = primaryTokens.filter { !knownWords.contains($0) }.count
        let bluetoothUnknown = bluetoothTokens.filter { !knownWords.contains($0) }.count
        if bluetoothUnknown < primaryUnknown {
            return ForkBDecision(
                preferBluetooth: true,
                primaryUnknownWords: primaryUnknown,
                bluetoothUnknownWords: bluetoothUnknown,
                reason: .bluetoothHasFewerUnknownWords)
        }
        if primaryUnknown < bluetoothUnknown {
            return ForkBDecision(
                preferBluetooth: false,
                primaryUnknownWords: primaryUnknown,
                bluetoothUnknownWords: bluetoothUnknown,
                reason: .primaryHasFewerUnknownWords)
        }
        return ForkBDecision(
            preferBluetooth: false,
            primaryUnknownWords: primaryUnknown,
            bluetoothUnknownWords: bluetoothUnknown,
            reason: .tied)
    }

    /// Merge raw transcripts before TextPipeline runs. Exact word anchors protect the
    /// complete built-in prefix/suffix while allowing Bluetooth's wording between the
    /// anchors to win. Low-confidence alignment always falls back to the built-in text.
    /// `protectedWords`: normalized (lowercased) user vocabulary/glossary terms whose
    /// loss in a substitution vetoes the merge — curated names outrank BT wording.
    static func mergeTranscripts(
        primary: String, bluetooth: String, protectedWords: Set<String> = []
    ) -> MergeResult {
        let primaryTokens = wordTokens(in: primary)
        let bluetoothTokens = wordTokens(in: bluetooth)

        guard !bluetoothTokens.isEmpty else {
            return MergeResult(text: primary, usedBluetooth: false, confidence: 0,
                               matchedTokens: 0, reason: .primaryOnly)
        }
        guard !primaryTokens.isEmpty else {
            let usable = bluetoothTokens.count >= 2
            return MergeResult(text: usable ? bluetooth : primary, usedBluetooth: usable,
                               confidence: usable ? 1 : 0, matchedTokens: 0,
                               reason: usable ? .bluetoothOnly : .primaryOnly)
        }

        let primaryWords = primaryTokens.map(\.normalized)
        let bluetoothWords = bluetoothTokens.map(\.normalized)
        if primaryWords == bluetoothWords {
            // There is no recognition win to import. Keep the complete primary's
            // casing: Bluetooth may start late and capitalize its first audible word
            // even though that word belongs in the middle of the primary sentence.
            return MergeResult(text: primary, usedBluetooth: false, confidence: 1,
                               matchedTokens: primaryWords.count, reason: .identical)
        }

        let matches = lcsMatches(primaryWords, bluetoothWords)
        guard let first = matches.first, let last = matches.last else {
            return MergeResult(text: primary, usedBluetooth: false, confidence: 0,
                               matchedTokens: 0, reason: .insufficientAlignment)
        }

        let primarySpan = last.0 - first.0 + 1
        let bluetoothSpan = last.1 - first.1 + 1
        let bluetoothCoverage = Double(matches.count) / Double(bluetoothTokens.count)
        let density = Double(matches.count) / Double(max(primarySpan, bluetoothSpan))
        let confidence = bluetoothCoverage * 0.65 + density * 0.35
        guard matches.count >= 3, bluetoothCoverage >= 0.55, density >= 0.5,
              confidence >= 0.58 else {
            return MergeResult(text: primary, usedBluetooth: false, confidence: confidence,
                               matchedTokens: matches.count, reason: .insufficientAlignment)
        }

        // Omission guard: the coverage gate is structurally blind to Bluetooth
        // DROPPING words — a BT track that is a pure subsequence of the primary scores
        // coverage 1.0 ("please do send…" after BT lost "not"). Between any two
        // anchors, primary-only words with an EMPTY Bluetooth gap mean BT went silent
        // there; importing its middle would delete spoken words. Substitutions (both
        // gaps non-empty, e.g. "did not"→"didn't") and BT insertions (words the far
        // mic missed) remain merge-eligible. Prefix gaps are NOT omissions — BT
        // legitimately starts late; the primary supplies the prefix anyway.
        for k in 0..<(matches.count - 1) {
            let primaryGap = matches[k + 1].0 - matches[k].0 - 1
            let bluetoothGap = matches[k + 1].1 - matches[k].1 - 1
            if primaryGap > 0, bluetoothGap == 0 {
                return MergeResult(text: primary, usedBluetooth: false,
                                   confidence: confidence, matchedTokens: matches.count,
                                   reason: .bluetoothOmission)
            }
            // Substitutions are merge-eligible — EXCEPT when they would lose a
            // negation ("not"→"please" inverts meaning; the omission guard can't see
            // it because both gaps are non-empty). A gap where the primary heard more
            // negation tokens than Bluetooth falls back to the primary verbatim.
            if primaryGap > 0, bluetoothGap > 0 {
                let primaryGapWords = primaryWords[(matches[k].0 + 1)..<matches[k + 1].0]
                let bluetoothGapWords = bluetoothWords[(matches[k].1 + 1)..<matches[k + 1].1]
                let primaryNegations = primaryGapWords.filter(Self.isNegationToken).count
                let bluetoothNegations = bluetoothGapWords.filter(Self.isNegationToken).count
                if primaryNegations > bluetoothNegations {
                    return MergeResult(text: primary, usedBluetooth: false,
                                       confidence: confidence,
                                       matchedTokens: matches.count,
                                       reason: .negationRisk)
                }
                // Spoken punctuation commands: the primary's "slash" becoming BT's
                // "flash" (2026-07-21 corpus, recording-154324) re-words what the user
                // dictated as structure. If the primary gap holds a command word the
                // BT gap dropped, keep the primary.
                let bluetoothGapSet = Set(bluetoothGapWords)
                if primaryGapWords.contains(where: {
                    Self.punctuationCommandWords.contains($0) && !bluetoothGapSet.contains($0)
                }) {
                    return MergeResult(text: primary, usedBluetooth: false,
                                       confidence: confidence,
                                       matchedTokens: matches.count,
                                       reason: .punctuationRisk)
                }
                // Curated vocabulary/glossary terms ("EC2") outrank BT wording — a
                // substitution that loses one is a name-mangling risk, not a win.
                if !protectedWords.isEmpty, primaryGapWords.contains(where: {
                    protectedWords.contains($0) && !bluetoothGapSet.contains($0)
                }) {
                    return MergeResult(text: primary, usedBluetooth: false,
                                       confidence: confidence,
                                       matchedTokens: matches.count,
                                       reason: .vocabularyRisk)
                }
            }
            // BT INSERTION right at a primary punctuation seam: the primary already
            // rendered the spoken command as punctuation ("later,"), and Bluetooth
            // heard it as a word ("comment" for a spoken comma — 2026-07-21 corpus,
            // recording-154324). A single-token BT insertion where the primary's
            // inter-anchor text contains punctuation is that mishear, not a rescue.
            if primaryGap == 0, bluetoothGap == 1 {
                let sepStart = primaryTokens[matches[k].0].range.location
                    + primaryTokens[matches[k].0].range.length
                let sepEnd = primaryTokens[matches[k + 1].0].range.location
                let separator = (primary as NSString).substring(
                    with: NSRange(location: sepStart, length: sepEnd - sepStart))
                if separator.rangeOfCharacter(from: Self.sentencePunctuation) != nil {
                    return MergeResult(text: primary, usedBluetooth: false,
                                       confidence: confidence,
                                       matchedTokens: matches.count,
                                       reason: .punctuationRisk)
                }
            }
        }

        let primaryString = primary as NSString
        let bluetoothString = bluetooth as NSString
        let prefix = primaryString.substring(with: NSRange(
            location: 0, length: primaryTokens[first.0].range.location))
        // The secondary often starts after the sentence began, so ASR capitalizes its
        // first token ("The", "More", "Installing"). Both anchor words exist in both
        // tracks; inherit their exact surface from the complete primary and take
        // Bluetooth only BETWEEN its anchors. The suffix then starts immediately after
        // the primary's last-anchor token, so primary punctuation at the seam — a
        // terminal "." or a ", " the BT track never emitted — survives the merge.
        let primaryFirstAnchor = primaryString.substring(with: primaryTokens[first.0].range)
        let primaryLastAnchor = primaryString.substring(with: primaryTokens[last.0].range)
        let bluetoothFirstAnchorEnd = bluetoothTokens[first.1].range.location
            + bluetoothTokens[first.1].range.length
        let bluetoothBetween = bluetoothString.substring(with: NSRange(
            location: bluetoothFirstAnchorEnd,
            length: bluetoothTokens[last.1].range.location - bluetoothFirstAnchorEnd))
        let suffixStart = primaryTokens[last.0].range.location
            + primaryTokens[last.0].range.length
        let suffix = primaryString.substring(from: suffixStart)
        // Plain concatenation: every part keeps its original separators (spaces,
        // commas, hyphens), so no join-with-space step that would mis-space a suffix
        // beginning with punctuation ("…period" + ".").
        let merged = (prefix + primaryFirstAnchor + bluetoothBetween + primaryLastAnchor + suffix)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return MergeResult(text: merged, usedBluetooth: true, confidence: confidence,
                           matchedTokens: matches.count, reason: .aligned)
    }

    /// Tokens whose loss inverts a sentence. Operates on normalized (lowercased,
    /// straight-apostrophe) words; any "n't" contraction counts.
    private static let negationWords: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "nowhere",
        "neither", "nor", "cannot", "without",
    ]
    static func isNegationToken(_ normalized: String) -> Bool {
        negationWords.contains(normalized) || normalized.hasSuffix("n't")
    }

    /// Build the protected-word set from the comma-joined vocabulary/glossary string
    /// (`Config.loadVocabulary` format). Multi-word terms protect each component word
    /// — losing "Reality" out of "Reality Games" manglles the name just the same.
    static func protectedWordSet(fromGlossary glossary: String?) -> Set<String> {
        guard let glossary else { return [] }
        var out = Set<String>()
        for term in glossary.components(separatedBy: ",") {
            for token in wordTokens(in: term) where token.normalized.count >= 2 {
                out.insert(token.normalized)
            }
        }
        return out
    }

    /// Spoken punctuation/structure command words (normalized) that TextPipeline later
    /// converts into characters. Multi-word commands ("question mark", "new line") are
    /// deliberately absent — their component words are common prose.
    private static let punctuationCommandWords: Set<String> = [
        "comma", "period", "colon", "semicolon", "slash", "backslash",
        "dash", "hyphen", "underscore", "ampersand", "asterisk", "percent",
        "hashtag", "apostrophe", "quote", "unquote",
    ]
    /// Punctuation characters that mean "the primary already rendered a spoken
    /// command here" when found between two adjacent anchors.
    private static let sentencePunctuation = CharacterSet(charactersIn: ".,;:!?—-/")

    private struct WordToken {
        let normalized: String
        let range: NSRange
    }

    private static let wordRegex = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)

    private static func wordTokens(in text: String) -> [WordToken] {
        let source = text as NSString
        return wordRegex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { match in
                let raw = source.substring(with: match.range)
                return WordToken(
                    normalized: raw.lowercased().replacingOccurrences(of: "’", with: "'"),
                    range: match.range)
            }
    }

    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty, !b.isEmpty {
            for i in 1...a.count {
                for j in 1...b.count {
                    table[i][j] = a[i - 1] == b[j - 1]
                        ? table[i - 1][j - 1] + 1
                        : max(table[i - 1][j], table[i][j - 1])
                }
            }
        }

        var i = a.count
        var j = b.count
        var matches: [(Int, Int)] = []
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                matches.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matches.reversed()
    }

    /// Write 16 kHz mono Float32 samples as a 16-bit wav (same settings as the
    /// primary recording file).
    public static func writeWav(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        var offset = 0
        let chunk = 16_000 * 4
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(count)) else { break }
            buf.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
            }
            try file.write(from: buf)
            offset += count
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One-shot async handoff from the serial CoreAudio teardown queue to finalization.
/// It preserves start→stop ordering for very short dictations without ever blocking main.
final class SecondaryCaptureResult: @unchecked Sendable {
    /// Box so a timeout can claim a specific waiter exactly once — resolve() and the
    /// timeout race for `continuation` under the lock; whoever takes it non-nil resumes.
    private final class Waiter {
        var continuation: CheckedContinuation<[Float], Never>?
        init(_ continuation: CheckedContinuation<[Float], Never>) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var samples: [Float]?
    private var waiters: [Waiter] = []

    func resolve(_ samples: [Float]) {
        lock.lock()
        guard self.samples == nil else { lock.unlock(); return }
        self.samples = samples
        let pending = waiters.compactMap { waiter -> CheckedContinuation<[Float], Never>? in
            let continuation = waiter.continuation
            waiter.continuation = nil
            return continuation
        }
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: samples) }
    }

    func value() async -> [Float] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let samples {
                lock.unlock()
                continuation.resume(returning: samples)
            } else {
                waiters.append(Waiter(continuation))
                lock.unlock()
            }
        }
    }

    /// Like `value()`, but never waits longer than `timeout`: the secondary stop runs
    /// behind Bluetooth HAL calls on the capture queue, and a wedged coreaudiod there
    /// must degrade the dictation to primary-only — not block insertion forever
    /// (the primary track is already complete and safely off the HAL path).
    func value(timeout: TimeInterval) async -> [Float] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let samples {
                lock.unlock()
                continuation.resume(returning: samples)
                return
            }
            let waiter = Waiter(continuation)
            waiters.append(waiter)
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                [weak self] in
                guard let self else { return }
                self.lock.lock()
                let timedOut = waiter.continuation
                waiter.continuation = nil
                self.waiters.removeAll { $0 === waiter }
                self.lock.unlock()
                guard let timedOut else { return }  // resolve() won the race
                DiagnosticLogger.shared.log(
                    "SecondaryCaptureResult: timed out after \(timeout)s — primary-only")
                timedOut.resume(returning: [])
            }
        }
    }
}

/// Minimal second capture stream: its own AVAudioEngine bound to a specific device,
/// accumulating 16 kHz mono Float32 samples between start() and stop(). No pre-roll,
/// no file, no crash recovery — it exists to produce a comparison track.
final class SecondaryRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    /// Bumped (under `lock`) on every engine build and teardown. AVFoundation can
    /// deliver a tap buffer AFTER removeTap/stop (the same late-callback race the
    /// primary path mitigates with retiredEngines); a stale buffer from a torn-down
    /// engine must not bleed into the NEXT recording's freshly-reset sample buffer.
    private var generation = 0
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Begin capturing from `device`. Returns false when the stream can't start
    /// (device vanished mid-handoff, invalid format, …) — callers just proceed
    /// single-mic; this stream is best-effort by design.
    func start(device: AudioInputDevice) -> Bool {
        stop()
        guard startAttempt(device: device) else {
            // The first engine start is itself what can complete A2DP→SCO negotiation.
            // A format-not-supported failure is therefore recoverable: build a fresh
            // graph against the now-settled route once, while primary keeps recording.
            DiagnosticLogger.shared.log(
                "SecondaryRecorder: first start failed — retrying settled Bluetooth route")
            Thread.sleep(forTimeInterval: 0.45)
            return startAttempt(device: device)
        }

        // A tap receives frames even in silence. If SCO negotiation invalidated the
        // initial format immediately after start, retry once after it has settled.
        Thread.sleep(forTimeInterval: 0.25)
        lock.lock()
        let receivedFrames = !samples.isEmpty
        lock.unlock()
        if receivedFrames { return true }
        DiagnosticLogger.shared.log(
            "SecondaryRecorder: no initial frames from \(device.name) — retrying after handoff")
        teardown()
        Thread.sleep(forTimeInterval: 0.25)
        return startAttempt(device: device)
    }

    private func startAttempt(device: AudioInputDevice) -> Bool {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let unit = inputNode.audioUnit else { return false }
        var deviceID = device.id
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return false }

        // AirPods need a brief A2DP→SCO handoff after binding. Reading the format
        // immediately can capture the stale stereo-route format and produce a running
        // engine whose tap never receives a frame. This queue is dedicated to Bluetooth
        // setup, so the wait cannot block UI or the reliable built-in primary.
        Thread.sleep(forTimeInterval: 0.35)

        let deviceFormat = inputNode.inputFormat(forBus: 0)
        let clientFormat = inputNode.outputFormat(forBus: 0)
        DiagnosticLogger.shared.log(
            "SecondaryRecorder: negotiated formats device="
                + "\(Int(deviceFormat.sampleRate))Hz/\(deviceFormat.channelCount)ch client="
                + "\(Int(clientFormat.sampleRate))Hz/\(clientFormat.channelCount)ch")
        guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else {
            DiagnosticLogger.shared.log(
                "SecondaryRecorder: \(device.name) format not ready — skipping dual capture")
            return false
        }
        // P5: reset the shared buffer under the lock. `samples` is mutated from the audio-thread
        // `append` and read/cleared from `collectSamples` on main; an unlocked `samples = []` here
        // is a real Array race against either. `converter` is reset alongside it for coherence.
        lock.lock()
        converter = nil
        samples = []
        generation += 1
        let tapGeneration = generation
        lock.unlock()

        var tapErr: NSError?
        let tapOK = CTryCatch({
            // Use the device/input scope. The client/output scope can remain at the
            // built-in graph's 48 kHz during handoff even when AirPods SCO is 24 kHz.
            inputNode.installTap(
                onBus: 0, bufferSize: 4096, format: deviceFormat
            ) { [weak self] buffer, _ in
                self?.append(buffer, generation: tapGeneration)
            }
        }, &tapErr)
        guard tapOK else {
            DiagnosticLogger.shared.log(
                "SecondaryRecorder: installTap failed — \(tapErr?.localizedDescription ?? "?")")
            return false
        }
        do {
            try engine.start()
        } catch {
            DiagnosticLogger.shared.log("SecondaryRecorder: start failed — \(error.localizedDescription)")
            return false
        }
        self.engine = engine
        DiagnosticLogger.shared.log(
            "SecondaryRecorder: capturing from \(device.name) "
                + "(\(Int(deviceFormat.sampleRate)) Hz, \(deviceFormat.channelCount) ch)")
        return true
    }

    private func append(_ buffer: AVAudioPCMBuffer, generation: Int) {
        lock.lock()
        guard generation == self.generation else { lock.unlock(); return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        let converter = converter
        lock.unlock()
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convErr == nil, let data = out.floatChannelData else { return }
        let converted = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        lock.lock()
        // Re-check: teardown/startAttempt may have advanced the generation while the
        // conversion ran; a stale buffer must not land in the next recording's track.
        if generation == self.generation {
            samples.append(contentsOf: converted)
        }
        lock.unlock()
    }

    /// Return whatever was captured so far and clear the buffer. Cheap and lock-guarded —
    /// does NO CoreAudio work, so it is safe to call from the main thread (the caller reads
    /// the comparison track here, then tears the HAL engine down off main via `teardown()`).
    func collectSamples() -> [Float] {
        lock.lock()
        let out = samples
        samples = []
        lock.unlock()
        return out
    }

    /// Tear down the capture engine. CoreAudio (removeTap/stop) — must run OFF the main
    /// thread; a stuck coreaudiod would otherwise wedge the main run loop.
    func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // Invalidate any tap buffer still in flight from the engine just stopped
        // (late AVFoundation callbacks arrive after removeTap), and clear the
        // converter under the same lock `append` reads it through.
        lock.lock()
        generation += 1
        converter = nil
        lock.unlock()
    }

    /// Stop capturing and return whatever was collected (empty when start failed).
    /// Convenience for callers already off the main thread; splits into `teardown()` +
    /// `collectSamples()` for the main-thread path (see AudioRecorder.stopRecording).
    @discardableResult
    func stop() -> [Float] {
        let wasRunning = engine != nil
        teardown()
        let captured = collectSamples()
        if wasRunning && captured.isEmpty {
            DiagnosticLogger.shared.log("SecondaryRecorder: stopped with zero samples")
        }
        return captured
    }
}
