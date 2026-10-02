// ai-suggestion:unverified · session:feat-dictation-trace · 2026-09-24
import Foundation

/// "Assemble the dots": given text that may contain dictated passages (a prompt, a copied
/// conversation), find the archived dictations it came from, even after the visible trace
/// was deleted or never added. Works only on the local recordings archive, so only when the
/// user has turned on saving.
///
/// Matching is word 3-gram containment inside one stretch of the input: a take matches when
/// at least `minContainment` of its word triples appear within a single window of the input
/// about 1.5 times the take's length, which tolerates light editing after dictation but not
/// common phrases scattered through typed text. Takes of `minShingleWords` to
/// `minPartialWords - 1` words must appear whole (every triple, in one window). Takes of fewer
/// than `minShingleWords` words match only when the whole input is that take, so "Yes."
/// does not match every text containing the word yes. Overlapping candidates are resolved
/// greedily: the take covering the most input wins, and a take mostly covered by a better one
/// is dropped. Identical takes keep only the newest.
///
/// Speed (it runs on every prompt from a hook): takes are tokenized and scored in parallel,
/// and word triples are compared as hashes, not strings.
public enum DictationMatch {

    public static let minContainment = 0.6
    public static let minShingleWords = 4
    /// Takes shorter than this must appear whole to match; longer ones may be edited.
    public static let minPartialWords = 8
    /// Default look-back: dictations from the last this-many days are candidates.
    public static let defaultDays = 14
    /// Hard cap on archive entries examined per call, newest first.
    public static let maxTakes = 10_000

    /// One archived take as the matcher sees it.
    public struct Take {
        public let base: String          // recording-<stamp>-<id>, no extension
        public let text: String          // final inserted text (.txt)
        public init(base: String, text: String) {
            self.base = base
            self.text = text
        }
    }

    public struct Hit: Equatable {
        public let base: String
        /// Share of the take's word triples found in the input (1.0 for an exact short take).
        public let containment: Double
        /// Word index in the input where the match starts; results are sorted by it.
        public let position: Int
    }

    /// Lowercased word tokens: letters, digits, and inner apostrophes (straight or curly).
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        var pendingApostrophe = false
        func flush() {
            if !cur.isEmpty { out.append(String(cur)) }
            cur = String.UnicodeScalarView()
            pendingApostrophe = false
        }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
                if pendingApostrophe { cur.append("'"); pendingApostrophe = false }
                cur.append(scalar)
            } else if v >= 0x41 && v <= 0x5A {
                if pendingApostrophe { cur.append("'"); pendingApostrophe = false }
                cur.append(Unicode.Scalar(v + 32)!)
            } else if v == 0x27 || v == 0x2019 {
                if !cur.isEmpty { pendingApostrophe = true }
            } else if v > 0x7F, CharacterSet.alphanumerics.contains(scalar) {
                if pendingApostrophe { cur.append("'"); pendingApostrophe = false }
                cur.append(contentsOf: String(scalar).lowercased().unicodeScalars)
            } else if v >= 0x300 && v <= 0x36F {
                // Combining marks stay inside the word they modify.
                if !cur.isEmpty { cur.append(scalar) }
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func hashes(_ w: [String]) -> [Int] { w.map { $0.hashValue } }

    static func shingleKeys(_ h: [Int]) -> [Int] {
        guard h.count >= 3 else { return [] }
        var out: [Int] = []
        out.reserveCapacity(h.count - 2)
        for i in 0...(h.count - 3) {
            var hasher = Hasher()
            hasher.combine(h[i])
            hasher.combine(h[i + 1])
            hasher.combine(h[i + 2])
            out.append(hasher.finalize())
        }
        return out
    }

    /// Prepared input, reusable across takes.
    public struct Input {
        let wordCount: Int
        let wholeKey: Int
        /// Shingle hash -> every word index where it starts.
        let positions: [Int: [Int]]

        public init(_ text: String) {
            let w = DictationMatch.words(DictationTrace.strip(text))
            wordCount = w.count
            let h = DictationMatch.hashes(w)
            wholeKey = h.hashValue
            var p: [Int: [Int]] = [:]
            for (i, s) in DictationMatch.shingleKeys(h).enumerated() { p[s, default: []].append(i) }
            positions = p
        }
    }

    private struct Scored {
        var key = 0
        var matched = false
        var containment = 0.0
        var covered: [Int] = []
        var first = Int.max
    }

    /// Score one take against the input (pure, thread-safe).
    private static func score(_ take: Take, _ input: Input) -> Scored {
        var s = Scored()
        let h = hashes(words(take.text))
        guard !h.isEmpty else { return s }
        s.key = h.hashValue
        if h.count < minShingleWords {
            if s.key == input.wholeKey {
                s.matched = true
                s.containment = 1
                s.covered = Array(0..<max(1, input.wordCount - 2))
                s.first = 0
            }
            return s
        }
        let keys = shingleKeys(h)
        // Every (input position, take triple) pair where a take triple occurs in the input.
        var hitsAt: [(pos: Int, triple: Int)] = []
        for (j, k) in keys.enumerated() {
            guard let pos = input.positions[k] else { continue }
            for p in pos { hitsAt.append((p, j)) }
        }
        let needed = h.count < minPartialWords ? 1.0 : minContainment
        guard Double(Set(hitsAt.map(\.triple)).count) >= needed * Double(keys.count) else { return s }
        hitsAt.sort { $0.pos < $1.pos }
        // Best window: the most distinct take triples found within `span` input words.
        let span = Int((Double(keys.count) * 1.5).rounded(.up)) + 2
        var counts: [Int: Int] = [:]
        var lo = 0
        var best = 0
        var bestRange = 0..<0
        for hi in hitsAt.indices {
            counts[hitsAt[hi].triple, default: 0] += 1
            while hitsAt[hi].pos - hitsAt[lo].pos >= span {
                let t = hitsAt[lo].triple
                counts[t]! -= 1
                if counts[t] == 0 { counts[t] = nil }
                lo += 1
            }
            if counts.count > best {
                best = counts.count
                bestRange = lo..<(hi + 1)
            }
        }
        s.containment = Double(best) / Double(keys.count)
        if s.containment >= needed {
            s.matched = true
            let window = hitsAt[bestRange]
            s.covered = Array(Set(window.map(\.pos)))
            s.first = window.first?.pos ?? 0
        }
        return s
    }

    /// Match `takes` (newest first) against `input`.
    public static func match(_ input: Input, takes: [Take]) -> [Hit] {
        guard input.wordCount > 0, !takes.isEmpty else { return [] }
        var scored = [Scored](repeating: Scored(), count: takes.count)
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 2, takes.count))
        let per = (takes.count + chunks - 1) / chunks
        scored.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * per
                let hi = min(takes.count, lo + per)
                guard lo < hi else { return }
                for i in lo..<hi { (base + i).pointee = score(takes[i], input) }
            }
        }

        struct Candidate { let hit: Hit; let covered: Set<Int>; let order: Int }
        var candidates: [Candidate] = []
        var seen = Set<Int>()
        for (order, s) in scored.enumerated() where s.matched {
            // Newest first, so the first occurrence of identical text is the newest take.
            guard seen.insert(s.key).inserted else { continue }
            candidates.append(Candidate(
                hit: Hit(base: takes[order].base,
                         containment: (s.containment * 100).rounded() / 100, position: s.first),
                covered: Set(s.covered), order: order))
        }
        // Greedy overlap resolution: most input covered first, then newest.
        candidates.sort {
            $0.covered.count != $1.covered.count ? $0.covered.count > $1.covered.count : $0.order < $1.order
        }
        var claimed = Set<Int>()
        var accepted: [Hit] = []
        for c in candidates {
            let fresh = c.covered.subtracting(claimed)
            guard Double(fresh.count) >= Double(c.covered.count) * minContainment else { continue }
            claimed.formUnion(c.covered)
            accepted.append(c.hit)
        }
        return accepted.sorted { $0.position < $1.position }
    }
}
