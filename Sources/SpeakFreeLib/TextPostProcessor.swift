// ai-suggestion:unverified · session:unknown · 2026-08-24
import Foundation
import NaturalLanguage

public struct TextPostProcessor {
    // Boundaries use whitespace OR punctuation (not \b which treats hyphens as boundaries).
    // Punctuation in lookahead handles whisper appending periods: "Period." "Exclamation mark."
    private static let ws = "(?<=[\\s.,!?;:]|^)"
    private static let we = "(?=[\\s.,!?;:]|$)"

    // A negation/auxiliary directly before a command word is never a command: "didn't new
    // line that" is a garble ("didn't realize that", 2026-07-03 regression), and
    // converting it eats the garbled word AND inserts fake punctuation. Bounded-alternation
    // lookbehind (ICU requires bounded length).
    private static let notAfterNegation =
        "(?<!\\b(?:didn['’]t|don['’]t|doesn['’]t|can['’]t|cannot|couldn['’]t|won['’]t|wouldn['’]t"
        + "|shouldn['’]t|hasn['’]t|haven['’]t|isn['’]t|wasn['’]t|weren['’]t|not|never)\\s)"

    // A determiner or explicit mention marker makes a multi-word punctuation phrase a noun:
    // "the question mark", "the word question mark". Spoken commands after a clause boundary
    // are unaffected because the immediately preceding character is punctuation, not this set.
    private static let notAfterLiteralNounMarker =
        "(?<!\\b(?:a|an|the|this|that|these|those|my|your|his|her|its|our|their|word|said)\\s)"
    // 2026-09-24: extended with the "a big question mark" idiom adjectives and colors, which
    // (like the originals) describe the glyph or the figurative noun, never a command's object.
    private static let notAfterLiteralNounModifier =
        "(?<!\\b(?:red|large|small|literal|actual|visible|single|double|first|second|third|fourth|fifth|final|another|big|huge|giant|major|massive|little|tiny|real|open|lingering|serious|extra|bold|blue|green|yellow|orange|black|white|grey|gray|pink|purple)\\s)"
    private static let notAfterModifiedLiteralNounMarker =
        "(?<!\\b(?:a|an|the|this|that|these|those|my|your|his|her|its|our|their)"
        + "\\s[A-Za-z][A-Za-z'’-]{0,29}\\s)"
    private static let questionPhraseNotUsedAsNoun =
        "(?!\\s+(?:as|is|means|symbol|character|noun|usage|use|uses|placement|rule|rules)\\b)"

    // Clause-final "question mark" / "exclamation mark" commands are decided per clause in
    // ClauseFinalCommand.swift (round 4). The table rules below cover only the mid-sentence
    // positions: this lookahead keeps them off every position that decision already owns, so
    // a phrase it left literal ("Click the circled question mark.") is not converted anyway.
    private static let notAtClauseEnd =
        "(?!\\s*[.?!]|\\s*$|\\s+(?:new line|newline|new paragraph)\\b"
        + "|\\s*,\\s+(?:i|i'm|i’m|i'd|i’d|it|it's|it’s|we|you|they|he|she|probably|maybe|perhaps"
        + "|please)\\b)"

    /// Round 4 (2026-09-25): the engine often ends a spoken "new line" with its own period
    /// ("…? New line. Thanks"). That period is consumed with the command; left behind, it
    /// collapsed into the mark before the break and the line break was lost.
    private static let consumeEngineMark = "(?:[.,](?=\\s|$))?"

    /// "Press question mark to open help": a verb that takes the glyph as its object.
    private static let notAfterGlyphVerb = "(?<!\\b(?:type|typed|insert|inserted|press|pressed|click|clicked|tap|tapped|hit|enter|entered)\\s)"

    // Unambiguous: these phrases are almost never used as regular words in speech.
    // Always safe to replace regardless of context (except right after a negation).
    private static var alwaysReplace: [(pattern: String, replacement: String)] {[
        // SINGULAR ONLY. The trailing `s?` used to swallow the plural NOUN, and unlike every
        // other failure in this file that one DESTROYS CONTENT: "the people with question marks"
        // became "the people with?", deleting the rest of the sentence (speech audit finding 3,
        // ~5 of 6,571 pairs; fix approved 2026-08-05). Spoken punctuation is dictated
        // in the singular, so the plural is essentially always the literal noun. If someone really
        // does dictate two question marks, the cost is a visible word to delete by hand — which is
        // the direction this file always errs, per the 2026-07-26 "prefer the loud useless one".
        ("\(ws)\(notAfterNegation)\(notAfterLiteralNounMarker)\(notAfterLiteralNounModifier)\(notAfterModifiedLiteralNounMarker)\(notAfterGlyphVerb)question mark\(questionPhraseNotUsedAsNoun)\(notAtClauseEnd)\(we)", "?"),
        ("\(ws)\(notAfterNegation)\(notAfterLiteralNounMarker)\(notAfterLiteralNounModifier)\(notAfterModifiedLiteralNounMarker)exclamation mark\(notAtClauseEnd)\(we)", "!"),
        ("\(ws)\(notAfterNegation)\(notAfterLiteralNounMarker)\(notAfterLiteralNounModifier)\(notAfterModifiedLiteralNounMarker)exclamation point\(notAtClauseEnd)\(we)", "!"),
        ("\(ws)\(notAfterNegation)\(notAfterLiteralNounMarker)semicolon\(we)", ";"),
        ("\(ws)\(notAfterNegation)\(notAfterLiteralNounMarker)semi colon\(we)", ";"),
        // Ellipsis removed — whisper generates "..." from pauses causing false positives
        ("\(ws)\(notAfterNegation)full stop\(we)", "."),
        ("\(ws)\(notAfterNegation)open quote\(we)", "\""),
        ("\(ws)\(notAfterNegation)close quote\(we)", "\""),
        ("\(ws)\(notAfterNegation)open paren\(we)", "("),
        ("\(ws)\(notAfterNegation)close paren\(we)", ")"),
        ("\(ws)\(notAfterNegation)new line\(consumeEngineMark)\(we)", "\n"),
        ("\(ws)\(notAfterNegation)newline\(consumeEngineMark)\(we)", "\n"),
        ("\(ws)\(notAfterNegation)new paragraph\(consumeEngineMark)\(we)", "\n\n"),
    ]}

    // Ambiguous: these words are commonly used as regular words ("comma separating",
    // "period of time", "colon cancer", "dash of salt"). Only replace when whisper
    // signaled a break before the word (preceded by punctuation), indicating the speaker
    // paused — meaning they intended a punctuation command, not a regular word.
    // The trailing `(?:[.,!?;:]|(?=\\s|$))` *consumes* a trailing punctuation char
    // when there is one, so that whisper's auto-punct adjacent to the user's spoken
    // word ("comma?" / "period.") does not survive into the cleanup steps and override
    // the user's stated intent. Spoken-word substitution always wins over auto-punct.
    private static var contextReplace: [(pattern: String, replacement: String)] {[
        // Require punctuation immediately before (after optional whitespace):
        // "hello, comma how" → replace ("," before "comma" = whisper saw a break)
        // "comma separating" → skip (no punctuation before = regular word)
        // Comma-homophone family: Parakeet mishears the spoken word "comma" as a small,
        // bounded set of /kVmV/ non-words. Mined from the maintainer's corpus 2026-07-02:
        // kama(29), kana(4), karma(3), kamala(1). All are handled here, gated on a
        // preceding punctuation break — that break is the garble signature (Parakeet
        // emits its own period/comma, then the mis-heard command). The gate is what keeps
        // a real "Kamala" or "good karma" in plain prose from being turned into a comma;
        // only the punctuation-preceded position converts. Runs BEFORE GlossaryCorrector.
        // Sentence-punct BEFORE the comma garble is CONSUMED (not just required): the
        // user's spoken comma outranks the engine's auto-period on both sides, so
        // "unreal. Kama have" → "unreal, have" — not "unreal. Have" (2026-07-14: the
        // period used to win the collision and turn a spoken comma into a fake
        // sentence break).
        // kamala/karma are REAL words that legitimately start sentences ("…ended. Kamala won."),
        // so for them the punctuation break must appear on BOTH sides (". Kamala," — the
        // dogfood 2026-07-02 garble shape). A following word instead of punctuation means a
        // real sentence-initial use, and converting would delete the word (adversarial
        // review 2026-07-15, round 1). The non-word family keeps the loose tail.
        // Each real-word rule carries a negative lookahead mirroring the word's skipBefore
        // list from convertStandaloneAmbiguous — these rules run FIRST and used to bypass
        // those guards entirely ("…punctuation. Comma usage varies." lost the word "Comma";
        // ". Colon cancer screening" lost "Colon" — adversarial review 2026-07-15, round 2).
        // The skip-ahead guard applies ONLY to the real word "comma" — the non-word garble
        // family (komma/kana/kanna/kama) can never be legitimate prose, so guarding them
        // would just leave visible garbles ("…note. Kama usage varies" — round 3).
        ("[.;]\\s*comma\(commaSkipAhead)(?:[.,!?;:]|(?=\\s|$))", ","),
        ("[.;]\\s*(?:komma|kamma|kana|kanna|kama|kaima|kalma|katma|comam|comlette|(?-i:gama|kanga))(?:[.,!?;:]|(?=\\s|$))", ","),
        ("[.;]\\s*(?:kamala|karma|(?-i:gama|kanga))\(notListItem)[.,!?;:]", ","),
        // comment/common joined the family 2026-07-29 (reported as "bad commas"). Parakeet hears
        // spoken "comma" as these two often enough to show up 6 times in one day. They are REAL
        // words, so they take the kamala/karma treatment — punctuation required on BOTH sides —
        // never the loose non-word tail. Verified against the same day's corpus: ". Comment,"
        // converts, while shapes like "the side comment box", "in quick comments I", "kind
        // comments and" and "should be common in" correctly do NOT (no trailing punctuation, or
        // plural).
        ("[.;]\\s*(?:comment|common|coma)[.,!?;:]", ","),
        // Same high-signal shape at utterance end: an existing punctuation mark immediately
        // followed by a comma-homophone and nothing else. This catches "Bread, comment" without
        // touching ordinary "leave a comment" prose (no punctuation directly before the noun).
        ("[,!?:]\\s*(?:comment|common|coma|karma|kamala)\\s*$", ","),
        // Short discourse markers followed by a punctuated comma-homophone are command-shaped:
        // "Shoot comment, I…" / "Okay awesome comment. I…". Keep the marker list closed and
        // require punctuation after the candidate; broad sentence-medial comment rewriting would
        // destroy legitimate review/document language.
        ("(\\b(?:shoot|okay|awesome|great|cool|thanks|interesting|right|yeah|yes|no|anyway)"
            + "(?:[ ,]+(?:really|very|so|pretty|totally|awesome|good|great|cool))*)"
            + "[ ,]+(?:comment|common|coma)[.,!?;:](?=\\s|$)", "$1,"),
        ("(?<=[,!?:])\\s*comma\(commaSkipAhead)(?:[.,!?;:]|(?=\\s|$))", ","),
        ("(?<=[,!?:])\\s*(?:komma|kana|kanna|kama|kaima|kalma|katma|comam|comlette|ka\\s+ma|(?-i:gama|kanga))(?:[.,!?;:]|(?=\\s|$))", ","),
        ("(?<=[,!?:])\\s*(?:kamala|karma|(?-i:gama|kanga))\(notListItem)[.,!?;:]", ","),
        ("(?<=[,!?:])\\s*(?:comment|common|coma)[.,!?;:]", ","),
        // Sentence-medial comment/common (2026-08-14, looser conversion approved).
        // Parakeet's dominant comma garble in running speech carries NO adjacent punctuation
        // ("the baking side comment, I would love" / "lunch options common. Maybe"), so the
        // both-sides-punctuation family above never fires. Three corpus-validated shapes convert;
        // the guard is the PRECEDING word: legitimate noun/adjective uses are (in 2 months of
        // corpus, Jul-Aug 2026: 27+2+19 command hits, 0 legit casualties) always preceded by a
        // determiner, possessive, comparative, copula, or verb marker ("a comment", "the right
        // comment bar", "more common", "to comment", "leave a comment or"), all blocklisted.
        // Plurals never match (the word is followed directly by punctuation or whitespace).
        // Shape 1: bare word before, punctuation after — "side comment, I" → "side, I".
        ("(?<![.,!?;:])(?<!\\b\(commentPrecedingWordBlock))\(commentNounPhraseLookback)"
            + "\\s+(?:comment|common)[.,!?;:](?=\\s|$)", ","),
        // "comet" is decided in `convertGarbledCometComma` (needs evidence on both sides).
        // Shape 2: no punctuation anywhere, followed by a clause-continuing conjunction —
        // "holds other things comment and think" → "holds other things, and think".
        ("(?<![.,!?;:])(?<!\\b\(commentPrecedingWordBlock))\(commentNounPhraseLookback)"
            + "\\s+(?:comment|common)\\s+"
            + "(?=(?:and|but|so|or|since|because|which|instead|then)\\b)", ", "),
        // Shape 3: punctuation before (consumed — the spoken comma outranks the engine's
        // auto-period, same rationale as the kama family), clause-starter after —
        // "chores. Common to separate" → "chores, to separate".
        ("[.,;]\\s+(?:comment|common)\\s+"
            + "(?=(?:and|but|so|or|if|either|to|does|do|keep|let|need|should|can|could|would"
            + "|might|not|just|it|that|this|they|there|you|we|i)\\b)", ", "),
        ("(?<=[.,!?;:])\\s*period(?!\\s+(?:of|piece)\\b)(?:[.,!?;:]|(?=\\s|$))", "."),
        ("(?<=[.,!?;:])\\s*colon(?!\\s+(?:cancer|surgery|cleanse|polyps?)\\b)(?:[.,!?;:]|(?=\\s|$))", ":"),
        ("(?<=[.,!?;:])\\s*dash(?!\\s+(?:of|board|cam)\\b)(?:[.,!?;:]|(?=\\s|$))", " —"),
        ("(?<=[.,!?;:])\\s*hyphen(?:[.,!?;:]|(?=\\s|$))", "-"),
    ]}

    /// Round 4 (2026-09-25): a real-word homophone followed by ", and" / ", or" is a list item
    /// ("Sam, Karma, and Lee came"), never a spoken comma; converting it deleted the name.
    private static let notListItem = "(?!,\\s+(?:and|or|&)(?=\\s|$))"

    /// Negative lookahead mirroring `comma`'s skipBefore list ("comma separated values",
    /// "Comma usage varies") for the punctuation-preceded rules above.
    private static let commaSkipAhead =
        "(?!\\s+(?:separated|delimited|splices?|operator|issues?|problems?|key|questions?|"
        + "things?|usage|placement|rules?|characters?)\\b)"

    /// Preceding words that mark comment/common as legitimate prose (negative lookbehind for
    /// the sentence-medial rules; every branch is fixed-length as ICU lookbehind requires):
    /// determiners/possessives ("a comment"), comparatives/intensifiers ("more common"),
    /// copulas ("is common"), verb markers ("to comment", "will comment"), pronoun subjects
    /// ("I comment"), negations, and — VERIFY round 1, 2026-08-14 — the noun/adjective
    /// modifiers that form compounds with "comment" ("a long comment.", "the blog comment.",
    /// "a code review comment") where the determiner sits 2+ tokens back, past a one-token
    /// lookbehind. Corpus-validated Jul-Aug 2026: blocks every legitimate use found (including
    /// the verifier's adversarial set); blocks zero of the 48 corpus command uses.
    private static let commentPrecedingWordBlock =
        "(?:a|an|the|this|that|these|those|my|your|his|her|its|our|their|any|no|each|every"
        + "|one|such|more|most|less|very|pretty|so|quite|really|new|old|right|latest|last"
        + "|first|next|good|bad|great|nice|is|are|was|were|be|being|been|as|too|to|will"
        + "|would|can|could|should|might|may|just|not|don't|didn't|won't|can't|shouldn't"
        + "|wouldn't|couldn't|i|you|we|they|he|she|it|please"
        + "|long|short|quick|brief|blog|code|review|inline|previous|earlier|original|single"
        + "|snide|rude|mean|nasty|helpful|written|posted|top|above|below|opening|closing"
        + "|youtube|reddit|facebook|instagram"
        + "|\\w{1,24}'s)"

    /// VERIFY round 2, 2026-08-14: an enumerated modifier list cannot close an open English
    /// class ("a snarky comment", "your GitHub comment", "His parting comment" all leaked).
    /// What every leak shared was a determiner/possessive/copula sitting exactly TWO tokens
    /// back — the reliable signature of a noun phrase whose head is "comment"/"common"-as-
    /// adjective. This second lookbehind blocks that signature. Cost, measured on the Jul-Aug
    /// corpus: 3 of 29 real command garbles no longer convert (shapes like "is fine comment." /
    /// "miss your walk comment since" / "in the yard comment,") because they are structurally identical
    /// to legitimate noun phrases — a missed comma is visible and cheap; a silently deleted
    /// noun is neither. Engine-level (acoustic) correction is the only clean fix for those.
    private static let commentNounPhraseLookback =
        "(?<!\\b(?:a|an|the|this|that|these|those|my|your|his|her|its|our|their"
        + "|is|are|was|were|be|been|being)\\s\\w{1,24})"

    /// Candidate shape for the "comet" comma garble: lowercase "comet" directly before the
    /// engine's own comma, with the comment/common noun-phrase guards and three more: a
    /// capitalized word before it names the comet ("Halley comet,", "ISON comet,"), a
    /// capitalized "Comet" is the browser or a name ("open Comet,"), and "X or comet," /
    /// "X and comet," is a noun list.
    private static let cometCandidate: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?<![.,!?;:])(?<!\\b\(commentPrecedingWordBlock))(?<!\\b(?:or|and|nor))"
            + "\(commentNounPhraseLookback)"
            + "(?<!(?-i:\\b[A-Z][A-Za-z'’]{0,24}))[^\\S\\n]+(?-i:comet),(?=\\s)",
        options: [.caseInsensitive])

    /// Words that open a new clause. After "comet," they are the garble evidence on the right.
    private static let cometClauseOpeners: Set<String> = [
        "i", "i'm", "i’m", "i'd", "i’d", "i'll", "i’ll", "i've", "i’ve", "it", "it's", "it’s",
        "we", "we're", "we’re", "you", "you're", "you’re", "they", "they're", "they’re", "he",
        "she", "that", "that's", "that’s", "this", "there", "there's", "there’s", "and", "but",
        "so", "or", "not", "then", "because", "if", "when", "which", "maybe", "also", "just",
        "like", "though", "although", "unless", "since", "while", "otherwise", "instead",
        "probably", "please", "let's", "let’s", "do", "does", "don't", "don’t", "can", "could",
        "would", "should", "is", "are", "was", "what", "how", "why", "where", "okay", "ok",
        "yeah", "yes", "no",
    ]

    /// Determiners, possessives and numbers: inside the noun phrase before "comet" they mark
    /// the real noun ("a really bright comet,", "one more comet,").
    private static let cometDeterminers: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "his", "her", "its",
        "our", "their", "any", "no", "each", "every", "one", "another", "some", "which", "what",
        "whose", "such", "two", "three", "first", "second", "last", "next",
    ]

    /// "comet," is a spoken comma only with evidence on both sides (design ruling 2026-09-25):
    /// - right: the word after the comma opens a clause or is capitalized
    ///   ("between them comet, not always", "smaller comet, it fits");
    /// - left: nothing marks a noun phrase. An adjective or noun right before it, or a
    ///   determiner, possessive or number reached by walking back over modifiers and
    ///   participles, means the real noun ("a really bright comet, and then", "an ice comet,
    ///   it", "a newly discovered comet, it"). The one exception is a comparative after a
    ///   degree phrase that opens the clause ("A little bit smaller comet, it fits"): a size
    ///   answer with no noun, so "comet" has nothing to be a noun of.
    /// Both 2026 archive uses of "comet" are garbles of this shape; no real noun appears.
    static func convertGarbledCometComma(_ text: String) -> String {
        guard let re = cometCandidate, text.range(of: "comet,", options: .caseInsensitive) != nil
        else { return text }
        let ns = text as NSString
        var out = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            // Right-hand evidence: the next word.
            let after = ns.substring(from: m.range.location + m.range.length)
                .trimmingCharacters(in: .whitespaces)
            let nextWord = after.split(whereSeparator: { $0 == " " || $0 == "\n" }).first
                .map { String($0).trimmingCharacters(in: CharacterSet.punctuationCharacters
                    .subtracting(CharacterSet(charactersIn: "'’"))) } ?? ""
            guard let first = nextWord.first else { continue }
            guard cometClauseOpeners.contains(nextWord.lowercased()) || first.isUppercase
            else { continue }
            // Left-hand evidence: the clause before "comet".
            let before = ns.substring(to: m.range.location)
            if cometHeadsNounPhrase(clauseBefore: before) { continue }
            out = out.replacingCharacters(in: m.range, with: ",") as NSString
        }
        return out as String
    }

    /// True when the words before "comet" in its clause form a noun phrase for it.
    private static func cometHeadsNounPhrase(clauseBefore before: String) -> Bool {
        let clause = before.split(whereSeparator: { ".,;:!?\n".contains($0) }).last
            .map(String.init) ?? before
        // Tag the clause with "comet" in place so the tagger sees the head it modifies.
        let tagged = clause + " comet"
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = tagged
        var tokens: [(word: String, tag: NLTag?)] = []
        tagger.enumerateTags(in: tagged.startIndex..<tagged.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) {
            tag, range in
            tokens.append((String(tagged[range]).lowercased(), tag))
            return true
        }
        guard tokens.last?.word == "comet" else { return false }
        tokens.removeLast()
        // A possessive ("Halley's comet,") names it; the tagger splits off the "'s".
        guard let last = tokens.last else { return false }
        if last.word == "'s" || last.word == "’s" || last.word.hasSuffix("'s")
            || last.word.hasSuffix("’s") {
            return true
        }
        // A comparative after a clause-opening degree phrase ("A little bit smaller comet, it
        // fits") answers a question about size and has no noun: "comet" is the garble there.
        // Only that opening shape is exempt; with anything before it ("It was a lot bigger
        // comet,", "a much brighter comet,") the phrase is a real noun phrase.
        let comparative = last.word.hasSuffix("er") || last.word == "more" || last.word == "less"
        let degree = tokens.dropLast().map(\.word)
        if comparative, degree.contains(where: { ["bit", "tad", "lot"].contains($0) }),
           degree.allSatisfy({ ["a", "little", "bit", "tad", "lot"].contains($0) }) {
            return false
        }
        if cometDeterminers.contains(last.word) || last.tag == .adjective || last.tag == .number
            || last.tag == .noun {
            // A noun right before it is a compound ("an ice comet,", "space rock comet,").
            return true
        }
        // Walk back over modifiers, participles and compound nouns to a determiner ("a big
        // ice comet,", "a newly discovered comet,").
        for token in tokens.reversed().prefix(5) {
            if cometDeterminers.contains(token.word) || token.tag == .number
                || token.tag == .determiner {
                return true
            }
            // Verbs are crossed too: the tagger reads participles as verbs, and irregular ones
            // ("found", "seen") have no ending to recognize. Crossing only ever adds noun
            // evidence, so the cost is a missed comma, never a deleted word.
            guard let t = token.tag, [.adjective, .adverb, .noun, .verb].contains(t) else {
                return false
            }
        }
        return false
    }

    // Ellipsis support removed — whisper generates "..." from pauses, causing false positives.
    // All multi-dot sequences are now stripped unconditionally.

    // LEGACY unguarded table. As of 2026-08-12 PRODUCTION never reaches this branch:
    // TextPipeline routes BOTH .spoken and .hybrid through the guarded path (`hybrid: true`),
    // so `.off` is the only non-guarded mode and it skips process() entirely. This table is
    // therefore reachable only via direct `process(_, hybrid: false)` unit tests. It is the
    // UNGUARDED substitution that used to make Spoken Only mangle "a period of time" →
    // "a. Of time" and "colon cancer" → ": cancer"; do NOT wire it back into a punctuation mode.
    private static var spokenFallback: [(pattern: String, replacement: String)] {[
        // NOTE: kamala/karma are deliberately NOT here. This is the SPOKEN-mode always-replace
        // fallback; kamala/karma are real words, so they only convert in the position-gated hybrid
        // rule above (preceded by a punctuation break = the garble signature). kama/kana/kanna are
        // non-words, safe to always-replace.
        ("\(ws)(?:[ck]omma|kana|kanna|kama)\(we)", ","),
        ("\(ws)period\(we)", "."),
        ("\(ws)colon\(we)", ":"),
        ("\(ws)dash\(we)", " —"),
        ("\(ws)hyphen\(we)", "-"),
    ]}

    /// Process spoken punctuation words into symbols.
    /// - Parameter hybrid: true = guarded substitution (context-aware `contextReplace` table +
    ///   `convertStandaloneAmbiguous`). PRODUCTION passes true for BOTH the Automatic & Spoken
    ///   (.hybrid) and Spoken Only (.spoken) modes — the guards are identical, and suppression of
    ///   the engine's own auto-punct (upstream) is the only thing that distinguishes them.
    ///   false = the LEGACY unguarded `spokenFallback` table; no production mode passes false any
    ///   more, so it is exercised only by direct unit tests.
    public static func process(_ text: String, hybrid: Bool = false) -> String {
        var result = text
        // Spurious pause-split softener (2026-07-25, corpus 0.3% of raws): the
        // engine sometimes splits at a spoken pause — "kitchen. as it goes" — and
        // the LOWERCASE continuation is its own tell that it didn't believe the
        // sentence ended. Soften to a comma. Runs FIRST, on pure engine output —
        // later passes intentionally create lowercase-after-period intermediates
        // that must not be touched. Exclusions: spoken-punctuation words after the
        // period are the garble family other rules own; ≥3 letters before the
        // period protects abbreviations (e.g., vs.).
        // LIVE as of 2026-08-02. This was written to a `var softened` that nothing read, so the
        // rule documented as "runs FIRST, on pure engine output" never actually ran. Wiring it in
        // changes one corpus expectation — "…or at least. Every six days" becomes
        // "…or at least, every six days" — which was approved as a product decision, since
        // the engine's pause-split was never a real sentence boundary.
        result = text.replacingOccurrences(
            of: "([A-Za-z]{3,})(?<!\\b[Ee]tc)\\. (?!(?:period|comma|kama|kaima|gama|coma|kamala|karma|dot|question|exclamation|new|newline)\\b)([a-z])",
            with: "$1, $2",
            options: .regularExpression)

        // 0.4. Strip surrounding quotes around spoken-command words. Whisper sometimes
        // wraps emphasized speech in quotes — `publish "Question mark"?` or `etc. "period."`
        // — so the unquoted-form rules below never see "comma"/"period"/etc. Strip the
        // quotes first; the existing rules then handle the now-unquoted command.
        result = stripQuotesAroundCommandWords(result)

        // Parakeet article insertion (2026-08-22 labeled clip): the speaker said
        // "Like, comma, what else..." and the decoder produced "Like a comma, what else...".
        // Keep this narrower than a generic "a comma" rewrite: require the exact discourse
        // marker plus punctuation plus a closed clause-starter set. Utterance-final
        // "Like a comma" is handled by convertStandaloneAmbiguous below.
        result = result.replacingOccurrences(
            of: "(?i)(^|[.!?]\\s+)(like)\\s+a\\s+comma[.,](?=\\s+(?:what|and|but|so|then|whether|if|when|where|which|who|how|i|we|you|they|he|she|it)\\b)",
            with: "$1$2,",
            options: .regularExpression)

        // 0.5. Collapse whisper's comma spam FIRST. If we let comma→period run first,
        // any capitalized word inside the spam ("I'd", "Claude") becomes a sentence
        // break, leaving "Hey hey. I'd. Claude do some research..." instead of
        // "Hey hey I'd Claude do some research...". Detect the run before reinterpreting
        // individual commas.
        result = collapseCommaSpam(result)

        // 0.6. Trailing comma → period for whisper-trailing-off cases. Run BEFORE
        // spoken punctuation substitution so a user-said "comma" at the end of an
        // utterance (which becomes "," after substitution) is not undone.
        result = trailingCommaToPeriod(result)

        // 1. (removed 2026-08-21) The old `commaBeforeCapitalToPeriod` rule converted
        // every engine ", Capital" → ". Capital" (a Whisper-era heuristic: Whisper spammed
        // commas where it meant periods). On Parakeet — the default engine, nearly all of the
        // labeled recordings — that premise is false: Parakeet's comma-before-a-capital is
        // almost always CORRECT (a name, a list, an appositive, a quoted clause). Corpus
        // audit: the rule fired 312 times and was WRONG in 100% of them — it split shapes
        // like "…meetings, Notion, and my email", "…for me, Sam, and Lee", "…make decisions,
        // Jordan should…" into fake sentences, and turned "Hello, Taylor" into "Hello.
        // Taylor" (a documented false positive). The Whisper recordings never triggered
        // it. Removing it stops corrupting good output. The legitimate residual case — an
        // engine stray-capital directly after a comma ("Great, So when") — is still handled,
        // correctly and proper-noun-safely, by `lowercaseStrandedCapitalAfterComma` (step 9).

        // 2. Replace unambiguous spoken punctuation words (always safe)
        // Preserve the established interrogative command while the general noun guards below
        // protect demonstrative + modifier phrases such as "that bright question mark".
        result = result.replacingOccurrences(
            of: "(?i)^(.*\\b(?:is|was) that right)\\s+question mark[.!]?\\s*$",
            with: "$1?", options: .regularExpression)
        result = convertClauseFinalCommands(result)
        result = convertSplitQuestionCommand(result)
        for (pattern, replacement) in alwaysReplace {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        // 2b. Collapse the engine's HALF-converted "question mark": Parakeet sometimes
        // converts the spoken word "mark" into "?" itself, leaving "question?" in the
        // softened (2026-07-14: "…as they get shot at question?"). Guarded by the same
        // noun-context rule as the standalone converter ("What is the question?" stays).
        result = collapseHalfConvertedQuestionMark(result)

        // 2c. Command-word garbles that arrive as their own one-word sentence
        // (2026-07-14, built-in mic — engine garbles, not audio).
        result = collapseCommandWordGarbles(result)

        // 2a. Trim spaces adjacent to spoken line-breaks (audit M2).
        // The alwaysReplace lookbehind/lookahead for "new line"/"new paragraph" are
        // non-consuming: they match on a word boundary but leave the adjacent spaces in place,
        // producing " \n " (trailing space on the prior word, leading space on the next).
        // Trim those artifact spaces so the break is clean: "hello \n world" → "hello\nworld".
        // This runs after alwaysReplace so it only touches \n characters that arrived from
        // spoken-command substitution (Whisper multi-segment \n are already space-joined
        // upstream in Transcriber before the text reaches TextPostProcessor).
        result = trimSpacesAroundNewlines(result)

        // 2. Replace ambiguous words — strategy depends on mode
        let ambiguous = hybrid ? contextReplace : spokenFallback
        for (pattern, replacement) in ambiguous {
            // A spoken line break is not a pause between words: these rules read "punctuation,
            // then whitespace, then the word" as a spoken mark, and crossing a break let them
            // consume it ("First part. New line. Comma, second" lost the break). Their
            // whitespace runs stop at a line break.
            let sameLine = pattern
                .replacingOccurrences(of: "\\s*", with: "[^\\S\\n]*")
                .replacingOccurrences(of: "\\s+", with: "[^\\S\\n]+")
            guard let regex = try? NSRegularExpression(pattern: sameLine, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        // 2.5. In hybrid mode, catch ambiguous words the context-aware regex missed.
        // The context regex requires preceding punctuation, but users often say
        // "word comma word" without whisper adding a comma first.
        if hybrid {
            result = convertGarbledCometComma(result)
            result = convertStandaloneAmbiguous(result)
        }

        // 2.6. A spoken mark right after a spoken line break ("new line comma"). The collapse
        // and spacing passes below read the break as whitespace between two marks, or before
        // one, and delete it, so every mark is settled against the break first.
        result = placeMarksAfterLineBreak(result)

        // 3. Collapse exactly-two-dots (from substitution duplicates) to a single dot.
        // The lookbehind+lookahead together ensure we don't touch any pair that's part
        // of a 3+ dot ellipsis run ("So... You"). Strip unicode ellipsis (whisper
        // occasionally emits it).
        if let dotsRegex = try? NSRegularExpression(pattern: "(?<!\\.)\\.\\.(?!\\.)", options: []) {
            result = dotsRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ".")
        }
        result = result.replacingOccurrences(of: "\u{2026}", with: "")

        // 4. Collapse space-separated same-type punctuation BEFORE fixSpacing.
        // Excludes "." so 3+ dot ellipses ("So...") survive — double-dots from
        // substitution duplicates are already handled by the dot-collapse above.
        if let regex = try? NSRegularExpression(pattern: "([,!?;:])(?:[^\\S\\n]*\\1)+", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // 5. Fix spacing: remove whitespace before punctuation marks
        result = fixSpacingAroundPunctuation(result)

        // 6. Collapse adjacent different-type punctuation conflicts
        result = collapseAdjacentPunctuation(result)

        // 6.5. Re-collapse two-dot duplicates that only became ADJACENT after fixSpacing
        // removed the separating space (". ." → ".."). Step 3 ran BEFORE spacing, so it
        // missed the space-separated form — the case Parakeet produces when its own
        // sentence period collides with a spoken/stray one ("looking for. ." → "for.."
        // → "for."). Preserves 3+ dot ellipses via the same lookarounds.
        if let dotsRegex = try? NSRegularExpression(pattern: "(?<!\\.)\\.\\.(?!\\.)", options: []) {
            result = dotsRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "."
            )
        }

        // 7. Ensure space after punctuation before next word
        result = ensureSpaceAfterPunctuation(result)

        // 8. Capitalize first letter after sentence-ending punctuation (. ! ?)
        // Double-punctuation collapse (2026-07-25 regression): Parakeet often
        // auto-punctuates the pause AND transcribes the spoken word — "calls it
        // done, comma things" — leaving the literal word after its own mark. When a
        // spoken-punctuation word directly follows the SAME mark, drop the word.
        result = result.replacingOccurrences(
            of: ",[^\\S\\n]+comma\\b[^\\S\\n]*", with: ", ",
            options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: "\\.[^\\S\\n]+period\\b[^\\S\\n]*", with: ". ",
            options: [.regularExpression, .caseInsensitive])
        // Corpus H3/H9 (2026-07-25, 7 instances): Parakeet splits/mangles spoken
        // "exclamation mark" into "Exclamation. Mark." / "exclamation marker" /
        // "Exclamation Market". Collapse the variants to "!" attached to the
        // preceding word, mirroring the single-token spoken-punctuation handling.
        // Guard shape: the mark-word is REQUIRED mid-text ("what an exclamation
        // that was" must survive); a bare "Exclamation." converts only when it is
        // the dictation's final token (the observed split-mangle position).
        let literalExclamationPrefix =
            "(?:a|an|the|this|that|these|those|my|your|his|her|its|our|their|word|said"
            + "|red|large|small|literal|actual|visible|single|double|first|second|another)"
        let modifiedLiteralExclamationPrefix =
            "(?:a|an|the|this|that|these|those|my|your|his|her|its|our|their)"
            + "\\s[A-Za-z][A-Za-z'’-]{0,29}"
        let commandPrefix = "(?:^|[,.][^\\S\\n]*|(?<!\\b\(literalExclamationPrefix))"
            + "(?<!\\b\(modifiedLiteralExclamationPrefix))[^\\S\\n]+)"
        if let re = try? NSRegularExpression(
            pattern: commandPrefix
                + "\\bexclamation(?:[ .]+|,[^\\S\\n]+(?=mark\\b(?:[.!]|\\s*$)))(?:mark(?:er|et)?|park)\\b[.!]*"
                + "|" + commandPrefix + "\\bexclamation\\.?\\s*$"
                // Clause-final split form: only the mention markers protect it there (see
                // `atClauseEnd`) — "…on the new job exclamation park." is the command.
                + "|(?<!\\b(?:word|said|red|large|small|literal|actual|visible|single|double|first|second|third|fourth|fifth|final|another|big|huge|giant|major|massive|little|tiny|real|open|lingering|serious|extra|bold|blue|green|yellow|orange|black|white|grey|gray|pink|purple|a|an|the|my|your|his|her|its|our|their|any|no))"
                // Split/garbled forms only; plain "exclamation mark" is owned (with all its
                // guards) by the alwaysReplace clause-end rule.
                + "[^\\S\\n]+\\bexclamation(?: +(?:mark(?:er|et)|park)|\\.[ .]*(?:mark(?:er|et)?|park))"
                + "\\b[.!]*(?=\\s*$)",
            options: [.caseInsensitive]) {
            let ns = NSMutableString(string: result)
            let matches = re.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                ns.replaceCharacters(in: m.range, with: "! ")
            }
            result = (ns as String).replacingOccurrences(of: "! $", with: "!",
                                                         options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        // Wide-sweep garbles (2026-08-20 punctuation-phoneme sweep; every rule
        // corpus-simulated at 0 false positives before shipping).
        // "Quark" = FUSED "question mark" — the sweep's biggest find (29 occurrences, 27
        // directly after the engine's own "?" or ".", zero prose uses). The engine's
        // punctuation is consumed; the user's spoken question mark wins.
        result = result.replacingOccurrences(
            of: "[?.][^\\S\\n]*quark\\b[.,!?;:]*", with: "?",
            options: [.regularExpression, .caseInsensitive])
        // "Colin" = "colon" when punctuated on BOTH sides ("two thoughts, Colin. One is…").
        // Greeting-position guard keeps a real Colin addressable: "Hi Colin," survives.
        result = result.replacingOccurrences(
            of: "(?<!\\b(?:hi|hey|hello|dear|thanks|yo)[ ,])[.,;][^\\S\\n]*colin[.,:][^\\S\\n]*", with: ": ",
            options: [.regularExpression, .caseInsensitive])
        // "questioner" / "question marked" / "question marker" / "kushma" — question-mark
        // garbles, gated to punctuation-adjacent or final position.
        result = result.replacingOccurrences(
            of: "[?.,][^\\S\\n]*(?:questioner|question[^\\S\\n]+mark(?:ed|er)|kushma(?:rk?)?)\\b[.,!?;:]*(?=\\s|$)", with: "?",
            options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: "[^\\S\\n]+(?:questioner|question[^\\S\\n]+mark(?:ed|er)|kushma(?:rk?)?)[.!?]*\\s*$", with: "?",
            options: [.regularExpression, .caseInsensitive])
        // "periods" directly after punctuation = spoken "period" (the plural NOUN is
        // protected by requiring the preceding punctuation break; "my periods" or "time
        // periods" carry no break).
        result = result.replacingOccurrences(
            of: "[.,][^\\S\\n]*periods\\b[.,!?;:]*(?=\\s|$)", with: ".",
            options: [.regularExpression, .caseInsensitive])
        // Approved 2026-08-21 (the wide sweep's owner-decision rows):
        // "quarter" directly after the engine's own "?" and final = spoken "question mark"
        // (real word, so the gate is the tightest observed shape: after-? + final).
        result = result.replacingOccurrences(
            of: "\\?[^\\S\\n]*quarter[.!?]*\\s*$", with: "?",
            options: [.regularExpression, .caseInsensitive])
        // "question marks" with punctuation before AND a trailing ? — the engine already
        // half-converted, so the plural here is the command, not the protected noun
        // (which appears mid-prose with a determiner: "the people with question marks" —
        // no punctuation break before, no trailing ?, so the 08-05 plural ruling holds).
        result = result.replacingOccurrences(
            of: "[.,][^\\S\\n]*question[^\\S\\n]+marks\\?+\\s*$", with: "?",
            options: [.regularExpression, .caseInsensitive])
        // tama/fama/pama both-sides-punctuated = spoken comma (plausible nicknames, so
        // both-sides only — the vocative shape "Hey Tama," has no punctuation before).
        result = result.replacingOccurrences(
            of: "[.;,][^\\S\\n]*(?:tama|fama|pama)[.,;][^\\S\\n]*", with: ", ",
            options: [.regularExpression, .caseInsensitive])
        // "combo" punctuated on BOTH sides mid-sentence = spoken comma (2026-09-25). Every
        // such hit in the maintainer's archive is a command (shapes like "a small risk. Combo,
        // but at the same time", "planning, combo, okay", "…, combo, it's noisy"); no real
        // "combo" in the archive has that shape. The word after must open a new clause, so a
        // menu order keeps its word ("the burger, combo, and a drink", "three. Combo, please").
        result = result.replacingOccurrences(
            of: "[.;,][^\\S\\n]*combo[.,;][^\\S\\n]+(?=(?:but|so|okay|ok|it|it's|it’s|i|i'm|i’m|we|you|they"
                + "|that|this|there|then|because|maybe|also)\\b)", with: ", ",
            options: [.regularExpression, .caseInsensitive])
        // "combo" / "pierre" both-sides-punctuated at utterance end = spoken comma/period.
        result = result.replacingOccurrences(
            of: "[.,;][^\\S\\n]*combo[.,;]?\\s*$", with: ",",
            options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: "[.,;][^\\S\\n]*pierre[.,;]?\\s*$", with: ".",
            options: [.regularExpression, .caseInsensitive])
        // 2026-09-24 punctuation pass: mid-sentence comma garble. Checked against every Jun-Sep
        // corpus take (both hits were spoken commas; an independent listener heard "comma").
        // "come a" is not grammatical before a clause opener, so no real word is lost.
        // "come a" (comma + inserted article) after an engine comma and before a clause
        // opener: "Okay, come a can you open the door" → "Okay, can you open the door".
        result = result.replacingOccurrences(
            of: ",[^\\S\\n]+come a[^\\S\\n]+(?=(?:i|we|you|they|do|does|did|can|could|would|should|it|so|and"
                + "|but|is|are|if|what|how)\\b)", with: ", ",
            options: [.regularExpression, .caseInsensitive])

        // Phoneme-mined final-position garbles (2026-08-20 punctuation-phoneme study).
        // All FINAL-position only: each surface form is plausible
        // prose mid-sentence ("make the question work", "his explanation marks a shift"),
        // but as the dictation's last token after real content it is command-shaped.
        // R5: "explanation mark" — head garble of "exclamation mark" (3 corpus hits).
        result = result.replacingOccurrences(
            of: "[ ,.]*\\bexplanation[ .]+mark(?:et)?\\b[.!]*\\s*$", with: "!",
            options: [.regularExpression, .caseInsensitive])
        // R6: "exclaim" / "exclaim mark" — clipped command (3 corpus hits, shaped like
        // "See you soon, exclaim.").
        result = result.replacingOccurrences(
            of: "[ ,.]*\\bexclaim(?:[ .]+mark)?\\b[.!]*\\s*$", with: "!",
            options: [.regularExpression, .caseInsensitive])
        // R7: "question work" — tail garble of "question mark" (punct-gated, final only).
        // "question market" (2026-09-24) is the same tail garble; also final-only.
        result = result.replacingOccurrences(
            of: "[ ,.]*\\bquestion[^\\S\\n]+(?:work|market)\\b[.!?]*\\s*$", with: "?",
            options: [.regularExpression, .caseInsensitive])
        // R8: ", appeared." — spoken "period" heard as "appeared" after an engine comma
        // (a comma directly before a bare verb is not grammatical prose, so the shape is
        // safe to claim in final position). 2026-09-24: also directly after "etc." ("…the
        // apples, etc. Appeared."), where no sentence can be ending on its own.
        // Round 4: the engine's closing period is required, so "Items etc. appeared" (no
        // period, a real verb continuing the sentence) keeps its word.
        result = result.replacingOccurrences(
            of: ",[^\\S\\n]+appeared[.]?\\s*$", with: ".",
            options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: "(?<=\\betc[.,])[^\\S\\n]+appeared\\.\\s*$", with: "",
            options: [.regularExpression, .caseInsensitive])
        // The final-position garble rules above can leave a new mark right after a break
        // ("First part new line question market" -> "First part\n?"); settle it again.
        result = placeMarksAfterLineBreak(result)
        result = capitalizeAfterSentenceEnd(result)

        // 9. Lowercase a stranded capital left after a spoken-comma conversion. The
        // comma-homophone rules above CONSUME a preceding engine period and emit ","
        // ("tomorrow. Comment. Any chance" → "tomorrow, Any chance"), but the word the
        // engine capitalized after that period stays capitalized, producing a mid-sentence
        // capital after a comma ("Great, So when", "opinion, But now", "not sure, What").
        // Since the step-1 comma→period rule was removed (2026-08-21), this pass ALSO sees
        // engine-native ", Capital" — which it handles correctly: only a CLOSED set of
        // discourse/function words (never proper nouns) is lowercased, so an engine comma
        // before a name or a list ("him, Sam was there", "meetings, Notion, and email") is
        // left exactly as the engine — correctly — punctuated it. Corpus Jul-Aug 2026: ~81
        // stranded capitals, 0 legit casualties in the closed set.
        result = lowercaseStrandedCapitalAfterComma(result)

        // 10. Lowercase a mid-CLAUSE spurious capital the engine emitted on a function word
        // that can never begin a sentence (Parakeet, 2026-08-21: "take something from The
        // large pile", "edges of The tiles", "I want To make it"). Distinct from step 9:
        // this fires between two words (not after a comma), and only for never-openers — so
        // it can't mistake a missing-period boundary ("…in reply to that. Are you able…")
        // for a stray capital, the way lowercasing And/But/So/Then/Are would.
        result = lowercaseSpuriousMidClauseCapital(result)

        return result
    }

    /// Closed set of discourse/function words the engine routinely capitalizes as a
    /// segment opener but which are never proper nouns — so a capitalized form directly
    /// after a comma is always a stranded capital from a spoken-comma conversion.
    private static let strandedCommaWords =
        "So|But|And|Or|Yeah|Yes|No|Well|Okay|Then|Also|Because|However|What|When|Where"
        + "|Which|Who|How|You|We|They|It|This|That|If|Any|Now|Here|There|Just"

    /// Lowercase a capitalized function word immediately following ", " (see step 9).
    private static func lowercaseStrandedCapitalAfterComma(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: ",(\\s+)(\(strandedCommaWords))\\b", options: []) else { return text }
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let wordRange = match.range(at: 2)
            guard let swiftRange = Range(wordRange, in: text) else { continue }
            let word = text[swiftRange]
            // "It"/"If" double as titles (the film "It", the poem "If"). Used as an appositive
            // title they are wrapped by a following comma ("my favorite film, It, still scares
            // me"); a discourse continuation ("..., It was") is never immediately followed by a
            // comma. Skip the lowercase only for that title signature — keeps the common real
            // correction, drops the rare proper-noun casualty (VERIFY 2026-08-18).
            if word == "It" || word == "If", text[swiftRange.upperBound...].first == "," { continue }
            let lowered = word.lowercased()
            mutable.replaceCharacters(in: wordRange, with: lowered)
        }
        return mutable as String
    }

    /// Function words that can NEVER begin an English sentence. A mid-clause Titlecase
    /// occurrence of one of these is always the engine's spurious capital — unlike
    /// And/But/So/Then/Are/Would (which DO open sentences, so a mid-clause capital there is
    /// often a missing period, not a stray capital). Deliberately EXCLUDES single letters
    /// ("A"/"B" option labels), month/name homographs, and auxiliaries that open yes/no
    /// questions. Corpus-simulated (Parakeet raws, 2026-08-21): 40 firings, 0 false
    /// positives (the lone borderline case was already-malformed input).
    private static let neverSentenceOpeners: Set<String> = [
        "the", "of", "to", "for", "with", "by", "from", "into", "onto", "at", "in",
        "on", "an", "as", "than", "about", "above", "below", "upon", "per", "via",
        "among", "amongst", "between", "during", "within", "without", "toward",
        "towards", "versus",
    ]

    /// Lowercase a Titlecase never-opener that sits mid-CLAUSE — preceded by a letter or
    /// comma (so NOT after `. ! ? : ;` and not at the start) — unless the FOLLOWING word is
    /// also capitalized, which protects a proper noun or title ("watched The Matrix", "in
    /// The MailChimp"). See step 10. `[A-Z][a-z]+` requires a lowercase tail, so single
    /// letters ("A") and all-caps ("THE"/acronyms) are never touched.
    private static func lowercaseSpuriousMidClauseCapital(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "[A-Za-z,]\\s+([A-Z][a-z]+)\\b", options: []) else { return text }
        let ns = text as NSString
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let wordRange = match.range(at: 1)
            let word = ns.substring(with: wordRange)
            guard neverSentenceOpeners.contains(word.lowercased()) else { continue }
            // Peek at the next non-space character: if it starts an uppercase word, treat
            // this as a proper noun / title ("The Matrix") and leave the capital alone.
            var idx = wordRange.location + wordRange.length
            while idx < ns.length, ns.character(at: idx) == 0x20 { idx += 1 }
            if idx < ns.length,
               let scalar = Unicode.Scalar(ns.character(at: idx)),
               CharacterSet.uppercaseLetters.contains(scalar) {
                continue
            }
            mutable.replaceCharacters(in: wordRange, with: word.lowercased())
        }
        return mutable as String
    }

    /// Replace a trailing comma (ignoring trailing whitespace) with a period.
    /// "Hello there," → "Hello there." / "Done, " → "Done. "
    private static func trailingCommaToPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(",") else { return text }
        // Find the last comma in the original text and swap it for a period,
        // preserving any trailing whitespace exactly.
        guard let lastComma = text.lastIndex(of: ",") else { return text }
        // Confirm that everything after the comma is whitespace (so it really is trailing).
        let afterComma = text[text.index(after: lastComma)...]
        guard afterComma.allSatisfy({ $0.isWhitespace }) else { return text }
        return text.replacingCharacters(in: lastComma...lastComma, with: ".")
    }

    /// Find runs of 5+ consecutive "word, word, " patterns and strip the commas.
    /// Whisper's comma-at-every-pause pattern. A run of 5+ means commas are noise;
    /// 1-4 is normal English ("First, ..." / "Okay, yeah, I think you can ..." /
    /// "apples, oranges, bananas, and pears"). Threshold tuned from real failures
    /// where 3-rep collapse ate legitimate speech-pause commas at the start of
    /// thoughts ("Okay, yeah, I think").
    /// Strip surrounding quotes (straight or curly) around recognized spoken-command words.
    /// Whisper sometimes wraps emphasized speech in quotes, e.g. `"Question mark"` instead of
    /// the literal phrase. Stripping the quotes first lets the existing spoken-punct rules
    /// match the unquoted form. Multi-word commands ("question mark", "exclamation mark",
    /// "new paragraph") are included. Match is case-insensitive.
    private static func stripQuotesAroundCommandWords(_ text: String) -> String {
        let commands = "comma|period|question marks?|exclamation marks?|exclamation points?|semicolon|semi colon|colon|dash|hyphen|full stop|new line|newline|new paragraph|open quote|close quote|open paren|close paren"
        // Match: opening quote + command (case-insens) + optional trailing punct + closing quote.
        // Capture group 1 is the command word; we substitute back without the surrounding quotes
        // (and without the trailing punct inside the quotes — the downstream spoken-punct rules
        // produce the correct symbol from the now-unquoted command word).
        let pattern = "(?i)[\"\u{201C}\u{201D}](\(commands))[.,!?;:]*[\"\u{201C}\u{201D}]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1"
        )
    }

    private static func collapseCommaSpam(_ text: String) -> String {
        // Word chars including apostrophe + hyphen (so "I'll", "don't", "wee-hours" all count as single words)
        // Match a word, then 4+ repetitions of ", word"
        let pattern = #"\b[\w'-]+(?:,\s+[\w'-]+){4,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }

        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        // Process in reverse so ranges stay valid
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let matched = String(text[range])
            // Strip commas between words (but keep the words)
            let fixed = matched.replacingOccurrences(of: ", ", with: " ")
            mutable.replaceCharacters(in: match.range, with: fixed)
        }
        return mutable as String
    }

    // MARK: - Style Modes

    public enum StyleMode {
        case texting    // Signal, iMessage, WhatsApp, SMS
        case slack      // Slack, Discord, Teams
        case email      // Gmail, Outlook, Mail
        case none       // No style processing (default for unknown apps)
    }

    /// True when the transcript tail is a spoken end-of-message period command — the word
    /// "period" (optionally trailed by the engine's own auto-punctuation) as the last token.
    /// Checked on the PRE-substitution transcript, because after substitution a dictated "."
    /// is indistinguishable from an auto-inserted one.
    public static func endsWithSpokenPeriodCommand(_ rawText: String) -> Bool {
        rawText.range(of: "\\bperiod[.!?,;:]?\\s*$",
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Detect style mode from the frontmost app's bundle ID.
    public static func detectStyleMode(bundleID: String?) -> StyleMode {
        guard let id = bundleID?.lowercased() else { return .none }
        // Texting apps
        if id.contains("signal") || id.contains("imessage") || id.contains("messages")
            || id.contains("whatsapp") || id.contains("telegram") || id.contains("sms") {
            return .texting
        }
        // Slack-style work chat
        if id.contains("slack") || id.contains("discord") || id.contains("teams") {
            return .slack
        }
        // Email
        if id.contains("gmail") || id.contains("mail") || id.contains("outlook")
            || id.contains("superhuman") || id.contains("spark") {
            return .email
        }
        return .none
    }

    /// Apply the chat-message style to transcribed text: casual messages conventionally drop
    /// the final period and start with a capital.
    /// Only modifies text for messaging apps — email and other apps keep normal punctuation.
    public static func applyStyle(_ text: String, mode: StyleMode,
                                  explicitTrailingPeriod: Bool = false) -> String {
        // Only apply style processing for messaging apps
        guard mode == .texting || mode == .slack else { return text }

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Strip trailing period only — mid-sentence periods stay for multi-sentence dictations.
        // Chat messages conventionally end without a period.
        // EXCEPT when the user explicitly dictated it (product decision 2026-08-14: honor
        // dictated punctuation): saying the word "period" is a deliberate override of the
        // chat style, and stripping it reads as "punctuation I said didn't get honored".
        if !explicitTrailingPeriod, result.hasSuffix(".") && !result.hasSuffix("..") {
            let beforeDot = result.dropLast()
            if !beforeDot.isEmpty {
                let lastWord = String(beforeDot.split(separator: " ").last ?? "")
                if lastWord.count > 2 { // keep after abbreviations like "U.S."
                    result = String(beforeDot)
                }
            }
        }

        // Capitalize first letter
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    /// Capitalize the first letter after sentence-ending punctuation.
    /// "hello. would love" → "hello. Would love"
    private static func capitalizeAfterSentenceEnd(_ text: String) -> String {
        // (?<!\.)  — skip the trailing dot of an ellipsis ("..."), so "could... do"
        //            stays lowercase instead of becoming "could... Do".
        // (?<![A-Z]) — skip when the dot follows a single uppercase letter, which is
        //            typically an acronym end ("U.S.A. next" / "Tour.U.K. guide").
        //            Capitalizing would turn the next common word into a fake sentence.
        // (?<![aApP]\.[mM]) — skip the trailing dot of a meridiem abbreviation ("5 p.m.
        //            today" must not become "5 p.m. Today"). In dictation "p.m."/"a.m." is
        //            almost always mid-sentence (a time), so the following word continues
        //            the sentence. Accepted tradeoff: a genuine sentence break right after
        //            "…p.m." is left lowercase — far rarer than the continuation.
        // (?<!\b[Ee]tc) — same for "etc." (round 4, 2026-09-25): "Items etc. appeared" is one
        //            sentence; the engine's own capital after "etc." is left as it came.
        guard let regex = try? NSRegularExpression(pattern: "(?<!\\.)(?<![A-Z])(?<![aApP]\\.[mM])(?<!\\b[Ee]tc)([.!?])\\s+(\\w)", options: []) else { return text }
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Process in reverse so ranges stay valid
        for match in matches.reversed() {
            let letterRange = match.range(at: 2)
            guard let swiftRange = Range(letterRange, in: text) else { continue }
            let upper = text[swiftRange].uppercased()
            mutable.replaceCharacters(in: letterRange, with: upper)
        }
        return mutable as String
    }

    /// Words that mark an ambiguous punctuation word as a NOUN phrase rather than a command:
    /// a pure article or possessive directly before it ("like a colon", "add the comma",
    /// "their period") means the user is talking *about* the thing. Deliberately excludes
    /// demonstratives ("I like that comma and then…" is a plausible genuine command).
    /// Root cause of the 2026-07-03 colon incident: Parakeet garbled a real word into
    /// "colon" inside "like a colon where", and the unguarded standalone rule converted one
    /// recognition error into fake punctuation.
    private static let nounDeterminers: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "its", "our", "their",
    ]

    /// Words that mark "question?" as a real noun phrase rather than a half-converted
    /// spoken "question mark": determiners/possessives plus the "in question" idiom.
    private static let questionNounContext: Set<String> =
        nounDeterminers.union(["that", "this", "these", "those", "in", "no", "any", "another", "one"])

    /// Collapse "…question?" → "…?" when the engine itself converted the spoken word
    /// "mark" into "?" (leaving the word "question" behind). Skips noun usage:
    /// "What is the question?", "the person in question?".
    static func collapseHalfConvertedQuestionMark(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)(?:^|[^\\S\\n]+|(?<=\\n))question\\?(?=\\s|$)", options: []) else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            // At a line start the words before the dictated break are still the context; the
            // "?" lands after the break and `placeMarksAfterLineBreak` moves it before it.
            let before = Substring(String(result[..<range.lowerBound].reversed()
                .drop(while: { $0 == "\n" }).reversed()))
            // Scan accepts hyphens and BOTH apostrophe forms so "follow-up" and "student’s"
            // are single tokens (round 2: the curly ’ and the hyphen used to stop the scan,
            // defeating the guards below).
            let isWordChar: (Character) -> Bool = { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
            let precedingWord = String(
                before.reversed().prefix(while: isWordChar).reversed()
            ).lowercased()
            if questionNounContext.contains(precedingWord) { continue }
            if precedingWord.isEmpty { continue }  // "Question?" alone — leave it
            // A possessive directly before "question" is always a real noun phrase
            // ("What was John's question?") — round 2.
            if precedingWord.hasSuffix("'s") || precedingWord.hasSuffix("’s")
                || precedingWord.hasSuffix("'") || precedingWord.hasSuffix("’") { continue }
            // Look one word further back: "a quick question?" / "a follow-up question?"
            // put an adjective between the determiner and the noun, and collapsing there
            // deletes a real word (adversarial review 2026-07-15, round 1).
            let beforeRest = before.dropLast(precedingWord.count)
            let secondPreceding = String(
                beforeRest.reversed().drop(while: { $0.isWhitespace })
                    .prefix(while: isWordChar).reversed()
            ).lowercased()
            if questionNounContext.contains(secondPreceding) { continue }
            result.replaceSubrange(range, with: "?")
        }
        return result
    }

    /// Command-word garbles observed 2026-07-14 (built-in mic — recognition garbles, not
    /// Bluetooth audio):
    /// - "…? Quark." — spoken "question mark" where the engine already emitted the "?"
    ///   and rendered the leftover as "Quark". Strip the stray word ("quark" as a real
    ///   word directly after a question mark is essentially nonexistent in dictation).
    /// - "…. Comment. X" — spoken "comma" rendered as a one-word sentence between two
    ///   engine periods. Join the clauses with the comma the user actually said. The
    ///   one-word-sentence signature (period on BOTH sides) is what protects genuine
    ///   uses like "leave a comment on the PR".
    static func collapseCommandWordGarbles(_ text: String) -> String {
        var result = text
        if let quark = try? NSRegularExpression(
            pattern: "(?<=\\?)[^\\S\\n]+[Qq]uark(?:\\.|(?=\\s|$))", options: []) {
            result = quark.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let comment = try? NSRegularExpression(
            pattern: "\\.[^\\S\\n]+[Cc]omment\\.(?=\\s|$)", options: []) {
            result = comment.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ",")
        }
        return result
    }

    /// In hybrid mode, convert ambiguous punctuation words when they appear as standalone
    /// words between phrases. "things like comma San Francisco" → "things like, San Francisco".
    /// Skips conversion when the word is part of a compound like "comma separated", when a
    /// real-word command follows an article/possessive (noun usage), or when a real-word
    /// command opens a multi-word utterance (punctuation with nothing before it is the garble
    /// signature — see the ": what about…" false conversion, 2026-07-03).
    private static func convertStandaloneAmbiguous(_ text: String) -> String {
        var result = text
        // `guarded` = the word is a real English word, so position guards apply. The comma
        // garble family (komma/kana/kanna) are non-words and always convert.
        // `literalPreceders` = words that mark the command word as a real noun regardless of
        // position ("the Oxford comma.", "a transition period.") — the determiner guard can't
        // see them because an adjective sits between the determiner and the noun.
        let ambiguousWords: [(word: String, replacement: String, skipBefore: Set<String>,
                              literalPreceders: Set<String>, guarded: Bool)] = [
            ("comma", ",", ["separated", "delimited", "splice", "operator", "issue", "issues", "problem", "problems", "key", "question", "thing", "things", "usage", "placement", "rule", "rules", "character"],
             ["oxford", "serial", "trailing", "inverted", "word", "said"], true),
            ("komma", ",", [], [], false),
            ("kamma", ",", [], [], false),
            // 2026-09-25: "kama" converts in EVERY position, not only after punctuation
            // (maintainer ruling: it is not a name in practice). Round 1 of the punctuation
            // pass read "Hey Kama," and "<name> Kama." as a person's name; they are Parakeet
            // hearing the spoken word "comma" with no pause before it (3 of 112 raw corpus
            // hits, all three commands). "Kama Sutra" is the only real phrase and stays.
            ("kama", ",", ["sutra"], ["the"], false),
            // Same shape, same non-word family: "going to the market Kaima, so they are right".
            ("kaima", ",", [], [], false),
            ("kana", ",", [], [], false),
            ("kanna", ",", [], [], false),
            ("kalma", ",", [], [], false),
            ("katma", ",", [], [], false),
            ("comam", ",", [], [], false),
            ("comlette", ",", [], [], false),
            // skipBefore also carries the menstrual "period <noun>" collocations
            // (period cramps/pain/tracker/…): a menstrual noun directly after "period"
            // is unambiguously the noun sense. These only fire when the noun is ADJACENT
            // ("period cramps"); an emphatic "…it hurt. Period. Cramps everywhere." keeps
            // the sentence break, so nextWord is empty there and the token still converts.
            // literalPreceders carries ONLY collocations with no live emphatic reading
            // (clinical "menstrual period", the fixed grace/trial/billing/… family).
            // Evaluative or state adjectives (late/heavy/light/missed/irregular) are
            // DELIBERATELY excluded — each has a live emphatic command reading ("the results
            // were irregular. Period.", "I'm running late. Period."), so protecting them
            // would swallow the command. The menstrual noun is instead carried by the
            // possessive guard, the menstrual-verb gate, and these skip nouns.
            ("period", ".", ["of", "piece",
              "cramps", "cramp", "pain", "tracker", "tracking", "symptoms", "flow"],
             ["transition", "grace", "grading", "trial", "notice", "probationary", "probation",
              "incubation", "menstrual", "cooling-off", "billing", "waiting",
              "recovery", "word", "said"], true),
            ("colon", ":", ["cancer", "surgery", "cleanse", "polyp"],
             ["sigmoid", "transverse", "ascending", "descending", "word", "said"], true),
            ("dash", " —", ["of", "board", "cam"], ["word", "said"], true),
            ("hyphen", "-", ["ated", "ation"], ["word", "said"], true),
        ]

        for (word, replacement, skipBefore, literalPreceders, guarded) in ambiguousWords {
            // Match the word as a standalone token (word boundaries on both sides)
            let pattern = "(?i)(?<=\\s|^)\(word)(?=\\s|$|[.,!?;:])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }

            // Process matches in reverse so indices stay valid
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }

                // Check if the next word is in the skip list
                let afterMatch = result[range.upperBound...]
                    .drop(while: { $0.isWhitespace })
                let nextWord = String(afterMatch.prefix(while: { $0.isLetter })).lowercased()
                if skipBefore.contains(nextWord) { continue }

                // Non-word garbles convert in every position, but a listed preceding word still
                // marks the real noun ("the Kama river", 2026-09-25 review).
                if !guarded, !literalPreceders.isEmpty {
                    let precedingWord = String(result[..<range.lowerBound]
                        .reversed().drop(while: { $0.isWhitespace })
                        .prefix(while: { $0.isLetter }).reversed()).lowercased()
                    if literalPreceders.contains(precedingWord) { continue }
                }

                // Position guards for real-word commands. Utterance-final means nothing
                // follows but one optional auto-punct char and whitespace — a digit or a
                // following sentence does NOT count ("talk about your period. It hurts" is
                // mid-utterance noun usage). Trailing commands are the most common
                // spoken-punctuation use ("…went to the store period"), so utterance-final
                // still converts by default — but the determiner and literal-preceder guards
                // apply in EVERY position: "I need to track my period." and "we discussed
                // the Oxford comma." end utterances too, and converting there deletes a real
                // word (adversarial review 2026-07-15, round 1).
                let isUtteranceFinal: Bool = {
                    var rest = afterMatch
                    if let first = rest.first, ".,!?;:".contains(first) { rest = rest.dropFirst() }
                    return rest.allSatisfy { $0.isWhitespace }
                }()
                if guarded {
                    let before = result[..<range.lowerBound]
                    let beforeTrimmed = before.reversed().drop(while: { $0.isWhitespace }).reversed()
                    // A line start after a dictated break is not the utterance start: the
                    // break was spoken, so the command after it is too ("new line comma …").
                    if beforeTrimmed.isEmpty && !isUtteranceFinal && !before.contains("\n") {
                        // Utterance-opening command with more words after it: garble signature
                        // (": what about…", 2026-07-03).
                        continue
                    }
                    // Accept hyphens and both apostrophe forms so "cooling-off" is one
                    // token — the hyphen used to stop this scan, making the hyphenated
                    // literalPreceders unreachable (round 2).
                    let precedingWord = String(
                        beforeTrimmed.reversed()
                            .prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
                            .reversed()
                    ).lowercased()
                    // Whole run of words before the match, for the multi-token lookback
                    // guards below (time-period window, having-a-period). Split on
                    // non-word chars so a "." breaks the phrase; each lookback guard is
                    // itself gated on `precedingWord` (the strict adjacent scan above), so
                    // a "X. period" case — where precedingWord is empty — never reaches them.
                    let priorWords = String(beforeTrimmed).lowercased()
                        .split(whereSeparator: {
                            !($0.isLetter || $0 == "'" || $0 == "’" || $0 == "-")
                        })
                        .map(String.init)
                    // A copular/reporting phrase before an article marks literal noun usage:
                    // "it should have been a comma" and "I said it was a period". This is
                    // intentionally narrower than the generic article guard so the documented
                    // Parakeet insertions "hover over a period" / "Like a comma" still correct.
                    if ["a", "an"].contains(precedingWord) {
                        let nounIntroducers: Set<String> = [
                            "be", "been", "being", "is", "was", "were", "means", "called",
                            "named", "said", "word",
                        ]
                        if nounIntroducers.contains(priorWords.dropLast().last ?? "") { continue }
                    }
                    // Menstrual-verb gate (runs FIRST so it beats the utterance-final drops
                    // below). "having/getting/missed/skipped/tracking <a|an|her|his> period" is
                    // the menstrual noun and must be protected in every position: "having her."
                    // / "getting a." cannot end a clause, so there is NO emphatic command to
                    // swallow. Gated on a menstrual verb immediately before the article/
                    // possessive, so the "end with a period" demo (verb "with"/"to"/"be") and
                    // the bare object-pronoun command "…and her. Period." (verb "and") are NOT
                    // rescued — they still convert. This is the ONLY thing that protects the
                    // article/possessive cases the drops below would otherwise convert.
                    if word == "period",
                       ["a", "an", "her", "his"].contains(precedingWord) {
                        let menstrualVerbs: Set<String> = [
                            "having", "have", "had", "has", "getting", "get", "gets", "got",
                            "missed", "miss", "missing", "skipped", "skip", "skipping",
                            "tracking", "track",
                        ]
                        if menstrualVerbs.contains(priorWords.dropLast().last ?? "") { continue }
                    }
                    // Utterance-final articles stay convertible: the live capture
                    // "…and end with a comma." (2026-04-29 regression) is a spoken
                    // command demo, and "a/an <command>" at the very end reads as command
                    // far more often than noun. "the" and the possessive DETERMINERS that
                    // cannot double as object pronouns (my/your/our/their/its) read as noun
                    // ("track my period.") in every position. But "her"/"his" also serve as
                    // object/predicate pronouns, so utterance-final "…and her period." /
                    // "…it's his period." is genuinely ambiguous between the noun ("her
                    // period") and an emphatic command ("…and her. Period."). Per the
                    // population ruling (2026-08-12, tightened after the over-broadness panel):
                    // a swallowed command is worse than a visible typo, so at utterance end the
                    // emphatic command wins (convert) unless the menstrual-verb gate above
                    // already protected it; mid-utterance still reads as the noun (protected).
                    // Scoped to "period"; comma/colon keep the full possessive set.
                    let droppedFinal: Set<String> = word == "period"
                        ? ["a", "an", "her", "his"]
                        : ["a", "an"]
                    let finalGuard: Set<String> = isUtteranceFinal
                        ? nounDeterminers.subtracting(droppedFinal)
                        : nounDeterminers
                    if finalGuard.contains(precedingWord) { continue }
                    if literalPreceders.contains(precedingWord) { continue }
                    // NOTE: there is deliberately NO "time period" noun protection. The
                    // over-broadness panel (2026-08-12) showed any "protect period after time"
                    // form — even gated on a definite article or possessive — swallows the very
                    // common emphatic "take your time. Period." / "on your own time. Period." /
                    // "give it the time. Period." The rare formal noun "at the appropriate time
                    // period" is left to convert to "…time." (a visible typo, the accepted
                    // cost — the original corpus defect, 3 raws).
                }

                // If the next non-space character is whisper auto-punct, consume it —
                // user's spoken word wins ("comma." → "," not ",.", "period?" → "." not ".?").
                let trailing = result[range.upperBound...]
                let punctSet: Set<Character> = [".", ",", "!", "?", ";", ":"]
                var replacementRange = range
                if guarded {
                    let before = result[..<range.lowerBound]
                    let beforeTrimmed = before.reversed().drop(while: { $0.isWhitespace }).reversed()
                    let precedingWord = String(
                        beforeTrimmed.reversed()
                            .prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
                            .reversed()
                    ).lowercased()
                    let beforeArticle = beforeTrimmed.dropLast(precedingWord.count)
                        .reversed().drop(while: { $0.isWhitespace }).reversed()
                    let articleIntroducer = String(
                        beforeArticle.reversed()
                            .prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
                            .reversed()
                    ).lowercased()
                    // Drop only the two corpus-established Parakeet article insertions.
                    // Other command-demo forms intentionally keep the historical output
                    // ("end with a period" -> "end with a.") to avoid changing the calibrated
                    // article/noun tradeoff beyond the evidence supplied for this feature.
                    if precedingWord == "a" || precedingWord == "an",
                       ["over", "like"].contains(articleIntroducer) {
                        let beforeSlice = result[..<range.lowerBound]
                        if let articleEnd = beforeSlice.lastIndex(where: { !$0.isWhitespace }) {
                            let articleStart = result.index(articleEnd,
                                                            offsetBy: -(precedingWord.count - 1))
                            replacementRange = articleStart..<range.upperBound
                        }
                    }
                }
                // A non-word garble opening the utterance ("Kama let's go") is dropped with the
                // engine mark after it: a comma has nothing to follow there, and a leading ","
                // is never what was meant (2026-09-25 review). The next word takes the capital.
                // Applies to the whole non-word family (kama, komma, kana, …). A dictation that is
                // ONLY the garble still becomes "," so it matches a correctly heard "Comma."
                var end = range.upperBound
                // The engine mark is consumed only on the same line: a dictated break between
                // them is kept ("new line comma new line comma" kept one break, 2026-09-25).
                let sameLineMark = trailing.first(where: { !$0.isWhitespace || $0 == "\n" })
                if let firstNonWS = sameLineMark,
                   punctSet.contains(firstNonWS) {
                    end = result.index(after: trailing.firstIndex(of: firstNonWS)!)
                }
                let rest = result[end...].drop(while: { $0.isWhitespace })
                if !guarded, !rest.isEmpty,
                   result[..<range.lowerBound].allSatisfy({ $0.isWhitespace }) {
                    let capital = result[range].first?.isUppercase ?? false
                    result = (capital ? rest.prefix(1).uppercased() : String(rest.prefix(1)))
                        + rest.dropFirst()
                    continue
                }
                if let firstNonWS = sameLineMark, punctSet.contains(firstNonWS) {
                    let endIdx = trailing.firstIndex(of: firstNonWS)!
                    let extendedRange = replacementRange.lowerBound..<result.index(after: endIdx)
                    result.replaceSubrange(extendedRange, with: replacement)
                } else {
                    result.replaceSubrange(replacementRange, with: replacement)
                }
            }
        }
        return result
    }

    /// Trim spaces that are immediately adjacent to a newline character (audit M2).
    /// The spoken-command regex for "new line" / "new paragraph" uses non-consuming
    /// lookbehind/lookahead, leaving the surrounding spaces in place: "hello \n world".
    /// This pass collapses those artifact spaces: "hello \n world" → "hello\nworld",
    /// "hello \n\n world" → "hello\n\nworld".
    /// Only spaces (U+0020) directly before or after `\n` are removed — other
    /// whitespace (tabs, multiple spaces from sentence spacing) is left untouched.
    /// `internal` (not `private`) so tests can cover it directly via @testable import.
    static func trimSpacesAroundNewlines(_ text: String) -> String {
        var result = text
        // Strip one or more spaces immediately before each \n.
        if let pre = try? NSRegularExpression(pattern: " +(?=\\n)", options: []) {
            result = pre.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Strip one or more spaces immediately after each \n.
        if let post = try? NSRegularExpression(pattern: "(?<=\\n) +", options: []) {
            result = post.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    /// A punctuation mark directly after a spoken line break has no text on its line to
    /// attach to, and step 5 would delete the break as "space before punctuation" (2026-09-25
    /// regression: "new line comma" lost the line break). The break was explicitly dictated,
    /// so it always survives:
    /// - a comma, semicolon or colon after a break is dropped ("first part new line comma
    ///   second part" -> "first part\nsecond part"). Its only job is to separate text within
    ///   a line, the break already separates more strongly, and a line that starts with a
    ///   comma is never wanted. Moving it before the break would instead add a mark to the
    ///   previous line that the break order says came after it.
    /// - a period, question mark or exclamation point after a break moves before it ("new
    ///   line period" -> "first part.\nSecond part"). It also ends the sentence and sets the
    ///   capital on the next line, which dropping it would lose.
    /// With no text before the break (the dictation opens with "new line"), any mark is
    /// dropped.
    static func placeMarksAfterLineBreak(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        let rules: [(NSRegularExpression?, String)] = [
            (try? NSRegularExpression(pattern: "(\\n+)[ \\t]*[,;:]+(?!\\d)[ \\t]*"), "$1"),
            (try? NSRegularExpression(
                pattern: "(?<=\\S)[ \\t]*(\\n+)[ \\t]*([.?!]+)(?!\\d)[ \\t]*"), "$2$1"),
            (try? NSRegularExpression(pattern: "(\\n+)[ \\t]*[.?!,;:]+(?!\\d)[ \\t]*"), "$1"),
        ]
        // A run such as ",?" after a break: the comma goes, then the question mark moves.
        var result = text
        for _ in 0..<4 {
            let before = result
            for (re, template) in rules {
                guard let re else { continue }
                result = re.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: template)
            }
            if result == before { break }
        }
        return result
    }

    private static func fixSpacingAroundPunctuation(_ text: String) -> String {
        var result = text
        // Never across a line break: every break reaching here was dictated.
        guard let regex = try? NSRegularExpression(pattern: "[^\\S\\n]+([.,?!:;...])", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1"
        )
        return result
    }

    /// Collapse punctuation conflicts from hybrid mode (whisper auto-punct + spoken punct).
    private static func collapseAdjacentPunctuation(_ text: String) -> String {
        var result = text

        // Remove comma/semicolon/colon before a sentence-ending mark: ",!" → "!", ";." → "."
        if let regex = try? NSRegularExpression(pattern: "[,;:][^\\S\\n]*([.!?...])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove period before ! or ?: ".!" → "!". Excludes "." in the character
        // class so 3+ dot ellipses ("So...") survive — sentence-end punct trumps
        // period, but a period inside an ellipsis isn't a "weaker" sentence-ender.
        if let regex = try? NSRegularExpression(pattern: "\\.[^\\S\\n]*([!?])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove trailing period after ! or ?: "!." → "!", "?." → "?"
        if let regex = try? NSRegularExpression(pattern: "([!?])[^\\S\\n]*\\.", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove comma after ! or ?: "!," → "!", "?," → "?"
        if let regex = try? NSRegularExpression(pattern: "([!?])[^\\S\\n]*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove comma after period: ".," → "." (period is stronger than comma)
        if let regex = try? NSRegularExpression(pattern: "\\.[^\\S\\n]*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "."
            )
        }

        return result
    }

    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var result = text
        // Comma, ?, !, : and ; (unchanged): (?<!\d) skips a mark between digits ("30,000").
        // (?![A-Za-z]\.) skips when the next char is a letter that's itself followed by
        // another dot — a single-letter abbreviation chain. Case-insensitive so it covers
        // BOTH uppercase acronyms ("U.S.A.", "Tour.U.K.I") and lowercase abbreviations
        // ("p.m.", "a.m.", "e.g.", "i.e."). Before this it was `[A-Z]` only, so "5 p.m."
        // was shattered into "5 p. m." and then capitalized to "p. M." (corpus Jul-Aug 2026:
        // 17 of 20 meridiem times corrupted). Keeps abbreviations compact.
        //
        // The period (2026-09-25): the old shared rule split every dotted token the engine
        // wrote correctly ("H.264" → "H. 264", "Frame.io" → "Frame. Io", "config.json").
        // A period after a letter is now spaced only for sentence glue, "word.Next": a capital
        // continuation, or the one-letter words "a"/"i". Any other digit or lowercase
        // continuation after a letter is not spaced, and a period after a digit never is
        // ("4.30", "H.264", "Frame.io", "Amazon.com"). In the September research replay, most
        // lowercase continuations were dotted names; the rest were engine garbles or stray
        // periods before an ordinary word, which a space rarely repaired. No dotted name had
        // a one-letter lowercase continuation. Rules below are applied in order.
        let rules = [
            "(?<![\\d\\n])([,?!:;])(?![A-Za-z]\\.)(\\w)",
            // After a non-capital letter: any capital that is not followed by a digit or dot
            // ("file.V2", "Tour.U.K." stay whole), except the dotted-name suffixes the engine
            // writes in capitals ("Frame.IO", "Node.JS", "Socket.IO"). "end.OK" is spaced.
            // (?<!\.\p{L}) leaves letters inside a dotted chain to the chain rule.
            "(?<=\\p{L})(?<!\\p{Lu})(?<!\\.\\p{L})(\\.)(?!(?:IO|JS|NET)\\b)(\\p{Lu})(?![\\d.])",
            // After a capital: only a capital that starts an ordinary word, so all-caps
            // tokens stay whole ("ASP.NET", "CLAUDE.MD") while "USA.I think" is spaced.
            "(?<=\\p{Lu})(?<!\\.\\p{L})(\\.)(\\p{Lu})(?![\\p{Lu}\\d.])",
            // Inside a dotted chain ("U.S.", "p.m.", "J.R.R."): only a capitalized word
            // ("U.S.Then" → "U.S. Then"), the pronoun "I" ("p.m.I think") and, after a
            // lowercase chain, the article "A" ("a.m.A new day"). "U.S.A next", "A.I. is" and
            // "Frame.i.O" stay whole; an all-caps word after a chain ("U.S.NASA") stays glued.
            "(?<=\\.\\p{L})(\\.)(\\p{Lu})(?=\\p{Ll})",
            "(?<=\\.\\p{L})(\\.)(I)(?=[\\s'’]|$)",
            "(?<=\\.\\p{Ll})(\\.)(A)(?=\\s)",
            // The lowercase one-letter words, as a whole word: "ended.a new one" is glue.
            // Trade-off, as before this change: a one-letter extension ending a token
            // ("libfoo.a", "file.i") is spaced.
            "(?<=\\p{L})(?<!\\.\\p{L})(\\.)([ai])(?=[\\s'’]|$)",
            // After anything that is not a word character (an ellipsis dot, a closing quote
            // or paren): the original rule. Keep it last: its [A-Za-z] is ASCII-only.
            "(?<![\\w\\n])(\\.)(?![A-Za-z]\\.)(\\w)",
        ]
        for pattern in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1 $2"
            )
        }
        return result
    }
}
