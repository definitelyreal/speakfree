import XCTest
@testable import SpeakFreeLib

/// The span-edit applier bounds what an untrusted cleanup model can do to a segment: it applies a
/// repair ONLY on a unique exact anchor, never overlapping, never introducing a control char or
/// newline. Every rejection is recorded with a cause. The parser strictly rejects anything that is
/// not the contracted bare JSON array.
final class SpanEditTests: XCTestCase {

    private func edit(_ find: String, _ replace: String, _ reason: String = "r") -> SpanEdit {
        SpanEdit(find: find, replace: replace, reason: reason)
    }

    // MARK: - Applier: matching

    func testUniqueMatchApplies() {
        let r = SpanEditApplier.apply([edit("teh", "the")], to: "teh cat sat")
        XCTAssertEqual(r.text, "the cat sat")
        XCTAssertEqual(r.applied, [edit("teh", "the")])
        XCTAssertTrue(r.rejected.isEmpty)
    }

    func testNoMatchRejected() {
        let r = SpanEditApplier.apply([edit("dog", "cat")], to: "teh cat sat")
        XCTAssertEqual(r.text, "teh cat sat", "text unchanged")
        XCTAssertTrue(r.applied.isEmpty)
        XCTAssertEqual(r.rejected.map { $0.cause }, [.noMatch])
    }

    func testAmbiguousMatchRejected() {
        // "at" occurs twice ("cat", "sat"? — "at" appears in both) → not a unique anchor.
        let r = SpanEditApplier.apply([edit("at", "AT")], to: "cat sat")
        XCTAssertEqual(r.text, "cat sat")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.ambiguousMatch])
    }

    func testOverlappingEditsSecondRejected() {
        // Both anchor uniquely, but their matched ranges overlap; the later one is rejected.
        let r = SpanEditApplier.apply([edit("abcd", "X"), edit("bc", "Y")], to: "abcd")
        XCTAssertEqual(r.text, "X")
        XCTAssertEqual(r.applied, [edit("abcd", "X")])
        XCTAssertEqual(r.rejected.map { $0.cause }, [.overlap])
    }

    func testMultipleNonOverlappingEditsAllApply() {
        let r = SpanEditApplier.apply([edit("teh", "the"), edit("kat", "cat")], to: "teh kat")
        XCTAssertEqual(r.text, "the cat")
        XCTAssertEqual(r.applied, [edit("teh", "the"), edit("kat", "cat")])
    }

    func testApplyOrderDoesNotCorruptOffsets() {
        // Two edits where the first-in-text is listed second: applying last-to-first keeps indices valid.
        let r = SpanEditApplier.apply([edit("world", "WORLD"), edit("hello", "HELLO")],
                                      to: "hello world")
        XCTAssertEqual(r.text, "HELLO WORLD")
    }

    // MARK: - Applier: validation

    func testEmptyFindRejected() {
        let r = SpanEditApplier.apply([edit("", "x")], to: "abc")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.emptyFind])
    }

    func testNoOpRejected() {
        let r = SpanEditApplier.apply([edit("abc", "abc")], to: "abc")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.noOp])
        XCTAssertEqual(r.text, "abc")
    }

    func testNewlineInReplacementRejected() {
        let r = SpanEditApplier.apply([edit("x", "a\nb")], to: "x")
        XCTAssertEqual(r.text, "x", "a newline would split the paragraph/segment — rejected, not stripped")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.invalidReplacement])
    }

    func testControlCharInjectionRejected() {
        // A NUL or bell smuggled into the replacement is rejected outright (untrusted output, C6).
        let r = SpanEditApplier.apply([edit("x", "a\u{0007}b")], to: "x")
        XCTAssertEqual(r.text, "x")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.invalidReplacement])
    }

    // MARK: - Applier: unicode + emoji

    func testUnicodeAndEmojiAreValidReplacements() {
        let r = SpanEditApplier.apply([edit("cafe", "café 🎉")], to: "a cafe here")
        XCTAssertEqual(r.text, "a café 🎉 here")
        XCTAssertTrue(r.rejected.isEmpty)
    }

    func testEmojiAnchorMatchesUniquely() {
        let r = SpanEditApplier.apply([edit("👍", "👎")], to: "rate this 👍 please")
        XCTAssertEqual(r.text, "rate this 👎 please")
    }

    func testCombiningMarksNotTreatedAsControl() {
        // e + combining acute accent — a mark, not a control char; must be allowed.
        let r = SpanEditApplier.apply([edit("e", "e\u{0301}")], to: "e")
        XCTAssertEqual(r.text, "e\u{0301}")
        XCTAssertTrue(r.rejected.isEmpty)
    }

    // MARK: - Parser

    func testParseBareArray() {
        let out = #"[{"find":"teh","replace":"the","reason":"typo"}]"#
        XCTAssertEqual(SpanEditParser.parse(out), .parsed([edit("teh", "the", "typo")]))
    }

    func testParseBareArrayWithSurroundingWhitespace() {
        let out = "\n  [{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]  \n"
        XCTAssertEqual(SpanEditParser.parse(out), .parsed([edit("a", "b", "c")]))
    }

    func testParseEmptyArrayMeansNoEdits() {
        XCTAssertEqual(SpanEditParser.parse("[]"), .parsed([]))
    }

    func testParseEmptyOutputRejected() {
        XCTAssertEqual(SpanEditParser.parse("   \n  "), .rejected(.empty))
    }

    func testParseFencedRejected() {
        let out = "```json\n[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]\n```"
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseProseWrappedRejected() {
        let out = #"Sure! Here are the edits: [{"find":"a","replace":"b","reason":"c"}]"#
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseTrailingProseRejected() {
        let out = #"[{"find":"a","replace":"b","reason":"c"}] hope that helps"#
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseMalformedJSONRejected() {
        XCTAssertEqual(SpanEditParser.parse("[this is not, valid json]"), .rejected(.malformed))
    }

    func testParseWrongShapeRejected() {
        // Valid JSON array, but of strings — not {find,replace,reason}.
        XCTAssertEqual(SpanEditParser.parse(#"["a","b"]"#), .rejected(.wrongShape))
    }

    func testParseMissingKeyRejected() {
        // Object missing "reason".
        XCTAssertEqual(SpanEditParser.parse(#"[{"find":"a","replace":"b"}]"#), .rejected(.wrongShape))
    }
}
