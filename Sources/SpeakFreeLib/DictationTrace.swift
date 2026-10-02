// ai-suggestion:unverified · session:feat-dictation-trace · 2026-09-24
import Foundation

/// Dictation trace: an optional, per-app, off-by-default marker that speakfree appends after
/// dictated text so an AI assistant reading the text can see what the speech engine actually
/// heard (the raw engine output before speakfree's cleanup, plus the words the engine was
/// unsure of).
///
/// Layout of an inserted dictation with a trace:
///
///     <dictated text> ·<invisible payload>
///
/// One visible anchor (a middle dot, U+00B7) is followed by the payload in one of two invisible
/// encodings:
///
/// - `.tags`: Unicode TAG characters U+E0020 to U+E007E, one per ASCII character. The payload
///   is ASCII-only JSON (non-ASCII escaped as `\uXXXX`), so a model such as Claude that sees
///   the raw characters can read it directly, no decoding step.
/// - `.selectors`: variation selectors, one per UTF-8 byte (bytes 0-15 map to U+FE00 to U+FE0F,
///   bytes 16-255 to U+E0100 to U+E01EF), attached to the anchor dot. Denser for non-ASCII and
///   often survives where TAG characters are stripped, but needs `speakfree trace decode`.
///
/// The payload is one JSON object:
/// `{"speakfree_trace":1,"engine":"whisper","heard":"raw engine text","unsure":["word 0.41"]}`.
///
/// Pure: no AppKit, no AX, no I/O. The app decides WHEN to append (see `TraceGate`); this type
/// only encodes, finds, decodes, and strips.
public enum DictationTrace {

    public enum Encoding: String, CaseIterable, Codable, Sendable {
        case tags
        case selectors
    }

    /// The visible anchor. A middle dot reads as a faint separator, not clutter.
    public static let anchor: Character = "\u{00B7}"

    /// Longest raw text carried. A longer dictation is truncated (and marked) so a trace can
    /// never balloon a keystroke-typed insertion; `speakfree match` still recovers the full take.
    public static let maxHeardCharacters = 2_000
    /// At most this many unsure words, the lowest-scoring kept in spoken order.
    public static let maxUnsureWords = 12
    /// A run of invisible characters shorter than this is never treated as a trace. Keeps
    /// ordinary emoji (one FE0F) and flag tag sequences from being misread.
    static let minimumRunLength = 16

    public struct WordScore: Codable, Equatable, Sendable {
        public let word: String
        /// Engine confidence 0...1 (Whisper: token probability; Parakeet: token confidence).
        public let score: Float
        public init(word: String, score: Float) {
            self.word = word
            self.score = score
        }
    }

    public struct Payload: Equatable, Sendable {
        public var engine: String
        public var heard: String
        public var unsure: [WordScore]
        public var truncated: Bool

        public init(engine: String, heard: String, unsure: [WordScore] = [], truncated: Bool = false) {
            self.engine = engine
            self.heard = heard
            self.unsure = unsure
            self.truncated = truncated
        }

        /// Build a payload from a take, applying the size caps.
        public static func make(engine: String, heard: String, unsure: [WordScore]) -> Payload {
            let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = trimmed
            var truncated = false
            if text.count > DictationTrace.maxHeardCharacters {
                text = String(text.prefix(DictationTrace.maxHeardCharacters))
                truncated = true
            }
            return Payload(engine: engine, heard: text,
                           unsure: DictationTrace.capUnsure(unsure), truncated: truncated)
        }
    }

    /// Keep the lowest-scoring `maxUnsureWords`, in their original (spoken) order.
    static func capUnsure(_ words: [WordScore]) -> [WordScore] {
        let clean = words.filter { !$0.word.isEmpty && !$0.word.contains(" ") && $0.score.isFinite }
        guard clean.count > maxUnsureWords else { return clean }
        let keep = Set(clean.indices.sorted { clean[$0].score < clean[$1].score }.prefix(maxUnsureWords))
        return clean.indices.filter { keep.contains($0) }.map { clean[$0] }
    }

    // MARK: - JSON

    /// Compact JSON, key order fixed so the same take always encodes the same way.
    /// `asciiOnly` escapes every non-ASCII scalar as `\uXXXX` (surrogate pairs above U+FFFF).
    static func json(_ p: Payload, asciiOnly: Bool) -> String {
        var s = "{\"speakfree_trace\":1,\"engine\":" + quote(p.engine, asciiOnly: asciiOnly)
        s += ",\"heard\":" + quote(p.heard, asciiOnly: asciiOnly)
        if !p.unsure.isEmpty {
            s += ",\"unsure\":["
            s += p.unsure.map { quote("\($0.word) \(formatScore($0.score))", asciiOnly: asciiOnly) }
                .joined(separator: ",")
            s += "]"
        }
        if p.truncated { s += ",\"truncated\":true" }
        return s + "}"
    }

    static func formatScore(_ score: Float) -> String {
        let clamped = min(max(score, 0), 1)
        return String(format: "%.2f", clamped)
    }

    static func quote(_ s: String, asciiOnly: Bool) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let v = scalar.value
                if v < 0x20 || v == 0x7F {
                    out += String(format: "\\u%04x", v)
                } else if asciiOnly && v > 0x7E {
                    if v > 0xFFFF {
                        let u = v - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (u >> 10), 0xDC00 + (u & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", v)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func parse(json: String) -> Payload? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["speakfree_trace"] as? NSNumber)?.intValue == 1,
              let engine = obj["engine"] as? String,
              let heard = obj["heard"] as? String else { return nil }
        var unsure: [WordScore] = []
        for item in (obj["unsure"] as? [String]) ?? [] {
            guard let space = item.lastIndex(of: " "),
                  let score = Float(item[item.index(after: space)...]) else { continue }
            unsure.append(WordScore(word: String(item[..<space]), score: score))
        }
        return Payload(engine: engine, heard: heard, unsure: unsure,
                       truncated: (obj["truncated"] as? Bool) ?? false)
    }

    // MARK: - Encode

    /// The invisible characters for `payload` (no anchor).
    public static func invisible(_ payload: Payload, encoding: Encoding) -> String {
        var out = String.UnicodeScalarView()
        switch encoding {
        case .tags:
            for byte in json(payload, asciiOnly: true).utf8 {
                // asciiOnly JSON is printable ASCII 0x20...0x7E, exactly the TAG block's range.
                out.append(Unicode.Scalar(0xE0000 + UInt32(byte))!)
            }
        case .selectors:
            for byte in json(payload, asciiOnly: false).utf8 {
                out.append(selector(for: byte))
            }
        }
        return String(out)
    }

    static func selector(for byte: UInt8) -> Unicode.Scalar {
        byte < 16 ? Unicode.Scalar(0xFE00 + UInt32(byte))! : Unicode.Scalar(0xE0100 + UInt32(byte) - 16)!
    }

    /// The anchor plus the invisible payload, preceded by one space.
    public static func suffix(_ payload: Payload, encoding: Encoding) -> String {
        " " + String(anchor) + invisible(payload, encoding: encoding)
    }

    /// `text` with a trace appended. Trailing whitespace or line breaks in `text` (a spoken
    /// "new line" at the end) stay AFTER the trace, so the cursor ends where it would have.
    public static func append(_ payload: Payload, encoding: Encoding, to text: String) -> String {
        let body = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard !body.isEmpty else { return text }
        let tail = String(text.dropFirst(body.count))
        return body + suffix(payload, encoding: encoding) + tail
    }

    // MARK: - Find, decode, strip

    public struct Found: Equatable {
        public let encoding: Encoding
        public let payload: Payload
        /// Scalar range of the removable trace (optional space + anchor + invisible run).
        let removalRange: Range<Int>
        /// Scalar offset of the invisible run in the input.
        public let offset: Int
        /// Whether the visible anchor was still in front of the invisible run.
        public let anchored: Bool
    }

    static func tagByte(_ s: Unicode.Scalar) -> UInt8? {
        (0xE0020...0xE007E).contains(s.value) ? UInt8(s.value - 0xE0000) : nil
    }

    static func selectorByte(_ s: Unicode.Scalar) -> UInt8? {
        switch s.value {
        case 0xFE00...0xFE0F: return UInt8(s.value - 0xFE00)
        case 0xE0100...0xE01EF: return UInt8(s.value - 0xE0100 + 16)
        default: return nil
        }
    }

    /// Every decodable trace in `text`, in order. Runs that do not decode to a speakfree trace
    /// (emoji variation selectors, flag tag sequences, someone else's hidden text) are ignored.
    public static func find(in text: String) -> [Found] {
        let scalars = Array(text.unicodeScalars)
        var results: [Found] = []
        var i = 0
        while i < scalars.count {
            let isTag = tagByte(scalars[i]) != nil
            let isSel = !isTag && selectorByte(scalars[i]) != nil
            guard isTag || isSel else { i += 1; continue }
            var start = i
            var bytes: [UInt8] = []
            while i < scalars.count,
                  let b = isTag ? tagByte(scalars[i]) : selectorByte(scalars[i]) {
                bytes.append(b)
                i += 1
            }
            // An emoji's own U+FE0F (byte 0x0F) can sit right before a selectors payload once
            // the dot is deleted. Payload JSON starts with "{", never a byte below 0x10.
            if isSel {
                let lead = bytes.prefix { $0 < 0x10 }.count
                bytes.removeFirst(lead)
                start += lead
            }
            guard bytes.count >= minimumRunLength,
                  let json = String(bytes: bytes, encoding: .utf8),
                  let payload = parse(json: json) else { continue }
            var removalStart = start
            var anchored = false
            if removalStart > 0, scalars[removalStart - 1] == "\u{00B7}" {
                anchored = true
                removalStart -= 1
                if removalStart > 0, scalars[removalStart - 1] == " " { removalStart -= 1 }
            }
            results.append(Found(encoding: isTag ? .tags : .selectors, payload: payload,
                                 removalRange: removalStart..<i, offset: start, anchored: anchored))
        }
        return results
    }

    /// `text` with every speakfree trace (and its anchor and leading space) removed.
    public static func strip(_ text: String) -> String {
        let found = find(in: text)
        guard !found.isEmpty else { return text }
        var scalars = Array(text.unicodeScalars)
        for f in found.reversed() { scalars.removeSubrange(f.removalRange) }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Cheap check used on hot paths: does `text` contain anything that could be a trace?
    public static func mayContainTrace(_ text: String) -> Bool {
        text.unicodeScalars.contains { tagByte($0) != nil || ($0.value >= 0xE0100 && $0.value <= 0xE01EF) }
            || text.unicodeScalars.lazy.filter { (0xFE00...0xFE0F).contains($0.value) }.count >= minimumRunLength
    }
}

// MARK: - Where a trace may go

/// Decides whether a trace is appended for one dictation. Pure so every rule is unit-tested.
///
/// Rules, all of which must pass:
/// 1. The feature is on (`dictationTrace` is "tags" or "selectors"; nil or "off" = off).
/// 2. Secure Input is not active and the focused field is not a password field.
/// 3. The app the dictation started in and the app frontmost at insertion are the same, and
///    that app is in the trace app list (the user's list, or `defaultApps`).
/// 4. Chat and mail apps (`messagingApps`: Messages, Slack, Mail, ...) are never on the
///    default list (a test enforces it); only a user's own `dictationTraceApps` can add one.
/// 5. A browser is allowed only when the focused page's host is in the web host list
///    (`defaultWebHosts`: Claude and ChatGPT/Codex). An unknown URL means no trace.
public enum TraceGate {

    /// Default target apps: AI assistants, code editors, terminals (where Claude Code and
    /// Codex run), and browsers (host-restricted, see `defaultWebHosts`).
    public static let defaultApps: [String] = [
        "com.anthropic.claudefordesktop",       // Claude
        "com.openai.codex",                     // Codex / ChatGPT desktop (new)
        "com.openai.chat",                      // ChatGPT desktop (classic)
        "com.microsoft.VSCode",                 // VS Code (Claude Code / Codex extensions)
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",        // Cursor
        "com.exafunction.windsurf",             // Windsurf
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.google.Chrome",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.brave.Browser",
        "company.thebrowser.Browser",           // Arc
        "com.microsoft.edgemac",
    ]

    /// Pages in a browser where a trace is allowed.
    public static let defaultWebHosts: [String] = ["claude.ai", "chatgpt.com", "chat.openai.com"]

    /// Apps whose text goes to other people (lowercased). Must never appear in `defaultApps`.
    public static let messagingApps: Set<String> = [
        "com.superhuman.superhuman", "com.superhuman.mail",
        "com.apple.mobilesms", "com.apple.mail", "com.tinyspeck.slackmacgap",
        "com.hnc.discord", "net.whatsapp.whatsapp", "desktop.whatsapp",
        "org.whispersystems.signal-desktop", "ru.keepcoder.telegram", "com.tdesktop.telegram",
        "com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.outlook",
        "com.superhuman.electron", "us.zoom.xos", "com.facebook.archon", "com.readdle.smartemail-mac",
        "com.apple.facetime", "com.linkedin.linkedin",
    ]

    public enum Decision: Equatable {
        case append(DictationTrace.Encoding)
        case skip(String)
    }

    public struct Input {
        public var setting: String?
        public var userApps: [String]?
        public var userWebHosts: [String]?
        public var targetBundleID: String?
        public var frontmostBundleID: String?
        public var secureInputActive: Bool
        public var focusedFieldIsSecure: Bool
        /// Host of the focused web page, when the app is a browser and AX could read it.
        public var webHost: String?

        public init(setting: String?, userApps: [String]? = nil, userWebHosts: [String]? = nil,
                    targetBundleID: String?, frontmostBundleID: String?,
                    secureInputActive: Bool, focusedFieldIsSecure: Bool, webHost: String? = nil) {
            self.setting = setting
            self.userApps = userApps
            self.userWebHosts = userWebHosts
            self.targetBundleID = targetBundleID
            self.frontmostBundleID = frontmostBundleID
            self.secureInputActive = secureInputActive
            self.focusedFieldIsSecure = focusedFieldIsSecure
            self.webHost = webHost
        }
    }

    public static func encoding(forSetting setting: String?) -> DictationTrace.Encoding? {
        guard let s = setting?.lowercased() else { return nil }
        return DictationTrace.Encoding(rawValue: s)
    }

    /// True when `bundleID` is on the effective list (case-insensitive).
    public static func isListed(_ bundleID: String, userApps: [String]?) -> Bool {
        let list = userApps ?? defaultApps
        return list.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    public static func hostAllowed(_ host: String?, userWebHosts: [String]?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return (userWebHosts ?? defaultWebHosts).contains { allowed in
            let a = allowed.lowercased()
            return host == a || host.hasSuffix("." + a)
        }
    }

    /// Whether the app is one for which the web host must be checked.
    public static func needsWebHost(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return TextInserter.isBrowser(bundleID: bundleID)
    }

    public static func decide(_ input: Input) -> Decision {
        guard let encoding = encoding(forSetting: input.setting) else { return .skip("off") }
        if input.secureInputActive { return .skip("secure input") }
        if input.focusedFieldIsSecure { return .skip("password field") }
        guard let target = input.targetBundleID, !target.isEmpty else { return .skip("unknown app") }
        guard let front = input.frontmostBundleID,
              front.caseInsensitiveCompare(target) == .orderedSame else { return .skip("app changed") }
        guard isListed(target, userApps: input.userApps) else { return .skip("app not in list") }
        if needsWebHost(target), !hostAllowed(input.webHost, userWebHosts: input.userWebHosts) {
            return .skip(input.webHost == nil ? "browser page unknown" : "browser page not in list")
        }
        return .append(encoding)
    }
}
