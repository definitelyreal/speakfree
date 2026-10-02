// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-25
import Foundation
import NaturalLanguage

// CLAUSE-FINAL "question mark" / "exclamation mark" COMMAND (punctuation pass, round 4).
//
// The 2026-08-24 noun guards protected "I drew that bright question mark on the screen" by
// looking at what the phrase FOLLOWS, which also blocked the command at the end of a question,
// where it almost always follows a noun phrase ("is the oven preheated question mark",
// "can we skip that question mark"). Rounds 1-3 relaxed those guards at a clause end with word
// lists, and every list leaked both ways: "Click the circled question mark." became "Click the
// circled?", while "Where is the remote question mark" stayed literal.
//
// Round 4 decides per CLAUSE instead. After a noun phrase ("the X", "that"), the command is the
// default, because the maintainer's Jun-Sep corpus shows declarative questions (shapes like "You
// remember the picnic question mark", "I'll see you in a few question mark") far outnumber literal
// clause-final uses. Two clause-level signals override the default:
// - Literal: the clause acts on the glyph itself, as an imperative or a reported act ("Click the
//   circled…", "Look at this…", "Can you add the inverted exclamation mark", "I noticed that…").
// - Command: the clause is a question (it opens with a wh-word or an auxiliary/modal, offers
//   "or" alternatives, or ends with a tag like ", right"). For "question mark" this wins over
//   the glyph signal, so "Can you fix that question mark?" converts; that sentence is ambiguous
//   and the corpus sides with the command (shapes like "Can you copy … question mark", "Can I
//   see the menu question mark").
// A predicate noun ("It is the main question mark.") or a glyph verb directly before ("type
// question mark") needs the question signal. Mid-sentence, the older table rules still apply.
//
// Always literal, whatever the clause: directly after an article or possessive ("a question
// mark", "the question mark"), after "the word" / "said", after a size, color or idiom adjective
// ("a big question mark"), after a glyph verb + demonstrative ("remove that question mark"), and
// in "what's that question mark".
extension TextPostProcessor {

    private static let ccMention: Set<String> = ["word", "said"]
    /// Directly before the phrase, always the literal mark ("a question mark").
    private static let ccArticle: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "its", "our", "their",
    ]
    private static let ccDemonstrative: Set<String> = ["this", "that", "these", "those"]
    /// Two words before the phrase, marks "the X question mark" as a noun phrase.
    private static let ccDeterminer: Set<String> = ccArticle.union(ccDemonstrative)
        .union(["any", "no", "every", "each", "some"])
    private static let ccModifier: Set<String> = [
        "red", "large", "small", "literal", "actual", "visible", "single", "double", "first",
        "second", "third", "fourth", "fifth", "final", "another", "big", "huge", "giant", "major",
        "massive", "little", "tiny", "real", "open", "lingering", "serious", "extra", "bold",
        "blue", "green", "yellow", "orange", "black", "white", "grey", "gray", "pink", "purple",
    ]
    /// Verbs whose object after a demonstrative is the glyph itself ("remove that question mark").
    private static let ccGlyphVerbBeforeDemonstrative: Set<String> = [
        "remove", "delete", "erase", "keep", "click", "tap", "type", "insert", "add", "drop",
        "highlight", "select", "print", "render", "draw", "write", "move", "copy", "paste", "see",
        "love", "like", "hate",
    ]
    /// Verbs that take the glyph directly ("type question mark"): the words convert only in a
    /// question ("What did you type question mark"). Kept short: "write", "use", "include" end
    /// real commands in the corpus (shaped like "so you don't need to write question mark").
    private static let ccGlyphVerbDirect: Set<String> = [
        "type", "insert", "press", "click", "tap", "hit", "enter", "add", "put",
    ]
    private static let ccNegation: Set<String> = [
        "didn't", "don't", "doesn't", "can't", "cannot", "couldn't", "won't", "wouldn't",
        "shouldn't", "hasn't", "haven't", "isn't", "wasn't", "weren't", "not", "never",
    ]
    /// Words that open a question.
    private static let ccQuestionOpener: Set<String> = [
        "what", "what's", "whats", "where", "where's", "when", "when's", "why", "why's", "who",
        "who's", "whom", "whose", "which", "how", "how's",
        "is", "isn't", "are", "aren't", "was", "wasn't", "were", "weren't", "am", "do", "don't",
        "does", "doesn't", "did", "didn't", "can", "can't", "could", "couldn't", "will", "won't",
        "would", "wouldn't", "should", "shouldn't", "shall", "may", "might", "must", "have",
        "haven't", "has", "hasn't", "had", "hadn't",
    ]
    /// Discourse fillers skipped before the opener ("So, where is…", "Okay and can you…").
    private static let ccFiller: Set<String> = [
        "so", "and", "but", "okay", "ok", "oh", "well", "hey", "hi", "also", "then", "like",
        "wait", "um", "uh", "alright", "now", "yeah", "yes", "actually", "just", "hmm", "anyway",
        "sorry", "still", "plus", "basically", "honestly", "seriously", "right",
    ]
    /// Imperative verbs that act on a visible glyph ("Click the circled question mark.",
    /// "Use the Spanish exclamation mark."). "look" counts only as "look at".
    private static let ccGlyphImperative: Set<String> = [
        "click", "tap", "press", "type", "insert", "draw", "highlight", "hover", "circle",
        "underline", "notice", "look", "use", "change", "add", "remove", "delete", "erase",
        "replace", "swap", "put", "select", "copy", "paste", "move", "drag", "drop",
    ]
    /// The same acts reported with a subject ("I noticed that question mark.").
    private static let ccGlyphReported: Set<String> = [
        "clicked", "tapped", "pressed", "typed", "inserted", "drew", "drawn", "highlighted",
        "hovered", "circled", "underlined", "noticed", "spotted", "erased", "pasted",
    ]
    private static let ccWhWord = ["what", "where", "when", "why", "who", "whom", "whose",
                                   "which", "how"]
    private static let ccSubject: Set<String> = [
        "i", "we", "you", "they", "he", "she", "i'll", "we'll", "you'll", "i've", "we've",
        "i'd", "we'd", "let's",
    ]
    private static let ccVerbSkip: Set<String> = [
        "please", "just", "also", "really", "already", "actually", "maybe", "then", "never",
        "not", "always", "now", "quickly", "first", "only", "even",
    ]
    private static let ccCopula: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "becomes", "became",
    ]

    private static let ccWordRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9'’]+(?:-[A-Za-z0-9'’]+)*", options: [])

    private static func ccWordsKeepingCase(_ s: String) -> [String] {
        let ns = s as NSString
        return ccWordRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).replacingOccurrences(of: "’", with: "'")
        }
    }

    private static func ccWords(_ s: String) -> [String] {
        let ns = s as NSString
        return ccWordRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'")
        }
    }

    /// The current clause: text after the last sentence mark, semicolon, line break, or a
    /// spoken command that ends a sentence ("Hi Sam exclamation mark how was the trip …").
    private static let ccClauseBreak = try! NSRegularExpression(
        pattern: "[.?!;\\n]|\\b(?:question mark|exclamation (?:mark|point)|full stop|new line"
            + "|newline|new paragraph)\\b", options: [.caseInsensitive])

    private static func ccClause(_ prefix: String) -> String {
        let ns = prefix as NSString
        let breaks = ccClauseBreak.matches(in: prefix, range: NSRange(location: 0, length: ns.length))
        guard let last = breaks.last else { return prefix }
        return ns.substring(from: last.range.location + last.range.length)
    }

    /// Subjects that follow an inverted auxiliary ("can YOU…", "is THAT real").
    private static let ccSubjectPronoun: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "this", "that", "these", "those", "there",
        "anyone", "anybody", "someone", "somebody", "everyone", "everybody", "anything",
        "something", "everything", "y'all",
    ]
    /// Auxiliaries that also open an imperative ("Do the dishes", "Have a look", "Don't click").
    /// They count as a question opener only before a subject pronoun ("Do you…").
    private static let ccImperativeCapableAux: Set<String> = [
        "do", "don't", "have", "be", "must",
    ]

    /// Strong signal that a clause is a question: in some comma segment, a wh-word opens it, or
    /// an auxiliary opens it and is followed by its subject (inversion: "can you", "is the store",
    /// "does Sam"). "Don't click…" and "Have a look…" are imperatives, not questions.
    static func clauseOpensQuestion(_ clause: String) -> Bool {
        for segment in clause.split(separator: ",", omittingEmptySubsequences: true) {
            let original = ccWordsKeepingCase(String(segment))
            let words = original.map { $0.lowercased() }
            guard let i = words.firstIndex(where: { !ccFiller.contains($0) }) else { continue }
            let first = words[i]
            if ccWhWord.contains(where: { first == $0 || first.hasPrefix($0 + "'") }) || first == "whats" {
                return true
            }
            guard ccQuestionOpener.contains(first), i + 1 < words.count else { continue }
            let next = words[i + 1]
            if ccSubjectPronoun.contains(next) { return true }
            if ccImperativeCapableAux.contains(first) { continue }
            if ccDeterminer.contains(next) { return true }
            if original[i + 1].first?.isUppercase == true { return true }  // a name
        }
        // Tag question: ", right" / ", okay" at the very end.
        return clause.range(of: ",\\s*(?:right|okay|ok|correct|yeah|huh|no|yes)\\s*$",
                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Any question signal, including "or" alternatives ("tea or coffee question mark").
    static func clauseIsQuestion(_ clause: String) -> Bool {
        clauseOpensQuestion(clause) || ccWords(clause).dropLast().contains("or")
    }

    /// Quantifier-like heads the tagger calls adjectives but that end real clauses
    /// ("in a few", "the other").
    private static let ccPronominalHead: Set<String> = [
        "few", "other", "others", "same", "rest", "latter", "former", "best", "worst", "most",
        "least", "diff", "own",
    ]

    /// Lexical classes of the last `count` words of the clause (system part-of-speech tagger).
    private static func ccTailTags(_ text: String, count: Int) -> [NLTag?] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var tags: [NLTag?] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) {
            tag, _ in
            tags.append(tag)
            return true
        }
        return Array(tags.suffix(count))
    }

    /// True when the word right before the phrase, directly after an article, is a modifier
    /// still waiting for its noun ("the strange", "a faded", "the circled"); that noun is the
    /// mark itself. `participleOnly` limits it to past participles ("the circled"), which the
    /// tagger reads reliably. Its adjective tag is only trusted in a statement: on the Jun-Sep
    /// corpus it also calls clause-final nouns adjectives in real questions (shapes like "for the
    /// picnic question mark", "on the shelf question mark", "doing a bake sale question mark").
    static func headIsModifier(_ clause: String, participleOnly: Bool) -> Bool {
        let text = clause.trimmingCharacters(in: .whitespaces)
        guard let lastWord = ccWords(text).last, !ccPronominalHead.contains(lastWord)
        else { return false }
        let tag = ccTailTags(text, count: 1).first ?? nil
        return ccIsParticiple(lastWord, tag) || (!participleOnly && tag == .adjective)
    }

    /// A past participle ("circled", "broken", "hand-drawn"); the tagger's verb tag alone
    /// also covers "-ing" nouns ("the ending", "a meeting"), so the ending is required.
    private static func ccIsParticiple(_ word: String, _ tag: NLTag?) -> Bool {
        (word.hasSuffix("ed") || word.hasSuffix("en") || word.hasSuffix("wn"))
            && (tag == .verb || tag == .adjective)
    }

    /// Statements only: "the X Y" whose last two words are both modifiers ("a small circled",
    /// "the upside down", "a greyed out", "a weird looking"), so no noun has arrived yet.
    static func twoWordModifier(_ clause: String) -> Bool {
        let text = clause.trimmingCharacters(in: .whitespaces)
        let words = ccWords(text)
        guard words.count >= 2 else { return false }
        let tags = ccTailTags(text, count: 2)
        guard tags.count == 2 else { return false }
        let first = tags[0], last = tags[1], lastWord = words[words.count - 1]
        guard first == .adjective || first == .adverb else { return false }
        return last == .adverb || last == .particle || ccIsParticiple(lastWord, last)
            || (last == .verb && lastWord.hasSuffix("ing"))
    }

    /// True when the last comma segment of the clause is an act on a visible glyph: an
    /// imperative ("Click the …", "Look at this …", "Can you add the …") or a reported act
    /// ("I noticed that …"). Such a clause is talking about the mark, not dictating it.
    static func clauseActsOnGlyph(_ clause: String, question: Bool = true) -> Bool {
        let lastSegment = clause.split(separator: ",").last.map(String.init) ?? clause
        let w = ccWords(lastSegment)
        var i = 0
        var sawSubject = false
        var auxBeforeSubject = false  // "Can you add …" is an imperative, "I add …" is not
        while i < w.count {
            let x = w[i]
            if ccSubject.contains(x) { sawSubject = true; i += 1; continue }
            if ccQuestionOpener.contains(x) && !ccWhWord.contains(where: { x.hasPrefix($0) }) {
                if !sawSubject { auxBeforeSubject = true }
                i += 1; continue
            }
            if ccFiller.contains(x) || ccVerbSkip.contains(x) || ccNegation.contains(x) {
                i += 1; continue
            }
            break
        }
        guard i < w.count else { return false }
        let verb = w[i]
        // "Look at this question mark" is about the glyph; "Look at the view!" is not.
        if verb == "look" { return question && i + 1 < w.count && w[i + 1] == "at" }
        if ccGlyphReported.contains(verb) { return true }
        return (!sawSubject || auxBeforeSubject) && ccGlyphImperative.contains(verb)
    }

    /// Decide whether a clause-final "question mark" / "exclamation mark" is the command.
    /// `prefix` is all text before the phrase.
    static func clauseFinalIsCommand(prefix: String, question: Bool, commaForm: Bool) -> Bool {
        let clause = ccClause(prefix)
        // Nothing before it in the clause ("Nice. Question mark.") or a punctuation break
        // directly before it ("…done, question mark") is the command signature.
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if let last = trimmed.last, ",:".contains(last) { return true }

        let w = ccWords(clause)
        guard let prev = w.last else { return true }
        let prev2 = w.count >= 2 ? w[w.count - 2] : ""
        let prev3 = w.count >= 3 ? w[w.count - 3] : ""

        // Always literal.
        if ccMention.contains(prev) || ccArticle.contains(prev) { return false }
        // A size, color or idiom adjective: literal after an article ("a big question mark"),
        // and in any clause that is not a question ("Is the store open question mark" is one).
        if ccModifier.contains(prev) {
            if ccArticle.contains(prev2) { return false }
            return question && clauseOpensQuestion(clause)
        }
        if ccDemonstrative.contains(prev) {
            if ccGlyphVerbBeforeDemonstrative.contains(prev2) { return false }
            if prev2 == "what's" || prev2 == "whats" || (prev2 == "is" && prev3 == "what") {
                return false
            }
        }
        if commaForm && ccNegation.contains(prev) { return false }

        // A predicate noun ("It is the main question mark.") or a glyph verb directly before
        // ("type question mark") is the literal mark unless the clause is a question
        // ("Where is the remote question mark", "What did you type question mark").
        let predicate = ccCopula.contains(prev3) && ["a", "an", "the"].contains(prev2)
        if predicate || (ccGlyphVerbDirect.contains(prev) && !ccDeterminer.contains(prev2)) {
            return question && clauseIsQuestion(clause)
        }
        // After "the X" / "that" (or "the X Y" for the glyph check): the command is the default.
        // A clause opening a question converts ("Can we skip that question mark"). A clause
        // acting on the glyph ("Click the circled help question mark.", "Don't touch …") keeps
        // the words, as does an adjective or participle waiting for its noun ("He stared at
        // the strange question mark.").
        let nearNounPhrase = ccDemonstrative.contains(prev) || ccDeterminer.contains(prev2)
        let nounPhrase = nearNounPhrase || ccDeterminer.contains(prev3)
        guard nounPhrase else { return true }
        // An adjective or participle right after the article ("the strange", "a faded") is
        // waiting for its noun, which is the mark itself; in a question only a participle
        // counts ("What happened to the circled question mark"). "Is the oven preheated" is
        // unaffected (a noun sits between).
        let opensQuestion = question && clauseOpensQuestion(clause)
        let afterArticle = ccDeterminer.contains(prev2) && !ccDemonstrative.contains(prev)
        if afterArticle && headIsModifier(clause, participleOnly: opensQuestion) { return false }
        if !opensQuestion && ccArticle.contains(prev3) && twoWordModifier(clause) { return false }
        if opensQuestion { return true }
        if clauseActsOnGlyph(clause, question: question) { return false }
        return true
    }

    private static let ccCommandRegex = try! NSRegularExpression(
        pattern: "(?<=[\\s.,!?;:]|^)(question mark|exclamation (?:mark|point))"
            + "(?:"
            // group 2: comma + clause opener (the comma form); the comma is consumed
            + "(\\s*,(?=\\s+(?:i|i'm|i’m|i'd|i’d|it|it's|it’s|we|you|they|he|she|probably"
            + "|maybe|perhaps|please)\\b))"
            // group 3: a single engine sentence mark right after (the spoken mark wins)
            + "|(\\s*[.?!])(?![.?!])"
            // otherwise: end of text, a spoken line break, or a longer mark run ("?!", "...")
            + "|(?=\\s*$|\\s+(?:new line|newline|new paragraph)\\b|\\s*[.?!])"
            + ")",
        options: [.caseInsensitive])

    /// Convert a clause-final spoken "question mark" / "exclamation mark" to its symbol when
    /// `clauseFinalIsCommand` says it is the command.
    static func convertClauseFinalCommands(_ text: String) -> String {
        // Left to right, re-matching after each change, so a command converted earlier in the
        // text ends the clause for the next one ("Hi Sam exclamation mark how was the trip
        // question mark").
        let ns = NSMutableString(string: text)
        var searchFrom = 0
        while searchFrom < ns.length,
              let m = ccCommandRegex.firstMatch(
                in: ns as String, range: NSRange(location: searchFrom, length: ns.length - searchFrom)) {
            let phrase = ns.substring(with: m.range(at: 1)).lowercased()
            let question = phrase.hasPrefix("question")
            let commaForm = m.range(at: 2).location != NSNotFound
            let end = m.range.location + m.range.length
            let after = ns.substring(from: m.range(at: 1).location + m.range(at: 1).length)
            let prefix = ns.substring(to: m.range(at: 1).location)
            // "What is that exclamation point?" asks about the glyph.
            let glyphQuestion = !question && after.trimmingCharacters(in: .whitespaces).hasPrefix("?")
            if !glyphQuestion,
               clauseFinalIsCommand(prefix: prefix, question: question, commaForm: commaForm) {
                ns.replaceCharacters(in: NSRange(location: m.range.location,
                                                 length: end - m.range.location),
                                     with: question ? "?" : "!")
                searchFrom = m.range.location + 1
            } else {
                searchFrom = m.range(at: 1).location + m.range(at: 1).length
            }
        }
        return ns as String
    }

    /// "…later. Question mark is it worth it?" — the engine ended a sentence where the command
    /// was spoken and opened the next with it. Converts only when the sentence before is itself
    /// a question (engine "?" or a question-shaped clause), so "Good point. Question mark is it
    /// a symbol?" keeps the words.
    private static let ccSplitRegex = try! NSRegularExpression(
        pattern: "([.,!?])\\s+question mark(?=\\s+(?:is|are|was|were|do|does|did|can|could|would"
            + "|will|should|have|has)\\s+(?:it|there|this|that|these|those|you|we|they|i|he|she)\\b)",
        options: [.caseInsensitive])

    static func convertSplitQuestionCommand(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        let matches = ccSplitRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let mark = ns.substring(with: m.range(at: 1))
            let before = ns.substring(to: m.range.location)
            guard mark == "?" || clauseIsQuestion(ccClause(before)) else { continue }
            ns.replaceCharacters(in: m.range, with: "?")
        }
        return ns as String
    }
}
