// Claude · 2026-09-29 · Pass 1 adversarial tests (words-only, no source read)
import XCTest
@testable import SpeakFreeLib

final class EditModePass1RealCallsTests: XCTestCase {

    // MARK: - Helpers

    private let listJSON = #"[{"find":"Kama","replace":",","reason":"spoken punctuation"}]"#

    private func isParsed(_ p: SpanEditParse) -> [SpanEdit]? {
        if case .parsed(let e) = p { return e }
        return nil
    }

    private func requireReal() throws {
        if ProcessInfo.processInfo.environment["SPEAKFREE_REAL_CLAUDE"] != "1" {
            throw XCTSkip("set SPEAKFREE_REAL_CLAUDE=1 for real Claude calls")
        }
    }

    /// Production path: cleanup -> screen -> apply(kept, to: pipelineText)
    private func pipeline(_ text: String, model: CleanupService.Model = .sonnet) async -> (String, String) {
        let service = CleanupService()
        let r = await service.cleanup(raw: text, pipelineText: text, model: model)
        switch r {
        case .success(let edits):
            let s = CleanupFaithfulness.screen(edits)
            let out = SpanEditApplier.apply(s.kept, to: text).text
            let log = "edits=\(edits.map { "[\($0.find)->\($0.replace)]" }) kept=\(s.kept.count) rejectedByScreen=\(s.rejected.count)"
            print("PASS1 IN : \(text)\nPASS1 OUT: \(out)\nPASS1 LOG: \(log)")
            return (out, log)
        case .failure(let e):
            print("PASS1 IN : \(text)\nPASS1 ERR: \(e)")
            return (text, "error: \(e)")
        }
    }

    private func assertNatural(_ out: String, _ ctx: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(out.contains(" ,"), "space before comma: \(out) | \(ctx)", file: file, line: line)
        XCTAssertFalse(out.contains(" ."), "space before period: \(out) | \(ctx)", file: file, line: line)
        XCTAssertFalse(out.contains(" :"), "space before colon: \(out) | \(ctx)", file: file, line: line)
    }

    // MARK: - (a) Fenced list handling, offline

    func test_a1_plainListParses_baseline() {
        XCTAssertNotNil(isParsed(SpanEditParser.parse(listJSON)), "plain list should parse")
    }

    func test_a2_singleJsonFenceAccepted() {
        let out = "```json\n\(listJSON)\n```"
        let e = isParsed(SpanEditParser.parse(out))
        XCTAssertNotNil(e, "single ```json fence should be accepted")
        XCTAssertEqual(e?.first?.find, "Kama")
        XCTAssertEqual(e?.first?.replace, ",")
    }

    func test_a3_singleBareFenceAccepted() {
        let out = "```\n\(listJSON)\n```"
        XCTAssertNotNil(isParsed(SpanEditParser.parse(out)), "single bare fence should be accepted")
    }

    func test_a4_fenceWithSurroundingWhitespaceAccepted() {
        let out = "\n  ```json\n\(listJSON)\n```  \n"
        XCTAssertNotNil(isParsed(SpanEditParser.parse(out)), "exactly one block, only whitespace around, should be accepted")
    }

    func test_a5_proseBeforeFenceRefused() {
        let out = "Here are the fixes:\n```json\n\(listJSON)\n```"
        XCTAssertNil(isParsed(SpanEditParser.parse(out)), "prose before block must be refused")
    }

    func test_a6_proseAfterFenceRefused() {
        let out = "```json\n\(listJSON)\n```\nLet me know if you need more."
        XCTAssertNil(isParsed(SpanEditParser.parse(out)), "prose after block must be refused")
    }

    func test_a7_twoBlocksRefused() {
        let out = "```json\n\(listJSON)\n```\n```json\n\(listJSON)\n```"
        XCTAssertNil(isParsed(SpanEditParser.parse(out)), "two blocks must be refused")
    }

    func test_a8_twoBlocksNoSeparatorRefused() {
        let out = "```json\n\(listJSON)\n``````json\n[]\n```"
        XCTAssertNil(isParsed(SpanEditParser.parse(out)), "two adjacent blocks must be refused")
    }

    func test_a9_fenceHoldingNonListRefused() {
        let out = "```json\n{\"find\":\"Kama\",\"replace\":\",\",\"reason\":\"x\"}\n```"
        XCTAssertNil(isParsed(SpanEditParser.parse(out)), "fence holding a non-list must be refused")
    }

    func test_a10_fenceHoldingProseRefused() {
        let out = "```\nI cleaned it up: I went home, then slept.\n```"
        XCTAssertNil(isParsed(SpanEditParser.parse(out)), "fence holding prose must be refused")
    }

    func test_a11_unclosedFenceRefused() {
        let out = "```json\n\(listJSON)\n"
        XCTAssertNil(isParsed(SpanEditParser.parse(out)), "unclosed fence is not exactly one block")
    }

    func test_a12_proseOnlyRefused() {
        XCTAssertNil(isParsed(SpanEditParser.parse("I went home, then slept.")), "rewritten prose must be refused")
    }

    // MARK: - (c) Punctuation spacing and undo, offline

    func test_c1_commaNoSpaceBefore() {
        let t = "I went home Kama then I slept"
        let r = SpanEditApplier.apply([SpanEdit(find: "Kama", replace: ",", reason: "spoken comma")], to: t)
        XCTAssertEqual(r.text, "I went home, then I slept")
    }

    func test_c2_periodNoSpaceBefore() {
        let t = "I went home paired Then I slept"
        let r = SpanEditApplier.apply([SpanEdit(find: "paired", replace: ".", reason: "spoken period")], to: t)
        XCTAssertEqual(r.text, "I went home. Then I slept")
    }

    func test_c3_colonNoSpaceBefore() {
        let t = "Here is the list column eggs and bread"
        let r = SpanEditApplier.apply([SpanEdit(find: "column", replace: ":", reason: "spoken colon")], to: t)
        XCTAssertEqual(r.text, "Here is the list: eggs and bread")
    }

    func test_c4_periodAtEndOfText() {
        let t = "I went home paired"
        let r = SpanEditApplier.apply([SpanEdit(find: "paired", replace: ".", reason: "spoken period")], to: t)
        XCTAssertEqual(r.text, "I went home.")
    }

    func test_c5_undoSingleFixRestoresExactText() {
        let t = "I went home Kama then I slept"
        let r = SpanEditApplier.apply([SpanEdit(find: "Kama", replace: ",", reason: "spoken comma")], to: t)
        XCTAssertEqual(r.applied.count, 1)
        guard let a = r.applied.first else { return }
        // Undo interpretation: reverse the recorded applied fix.
        let undo = SpanEditApplier.apply([SpanEdit(find: a.replace, replace: a.find, reason: "undo")], to: r.text)
        XCTAssertEqual(undo.text, t, "undo of the one fix should give back exactly the text before it; applied=\(a)")
    }

    func test_c6_undoPeriodFixRestoresExactText() {
        let t = "Done for today paired See you soon"
        let r = SpanEditApplier.apply([SpanEdit(find: "paired", replace: ".", reason: "spoken period")], to: t)
        guard let a = r.applied.first else { return XCTFail("not applied") }
        let undo = SpanEditApplier.apply([SpanEdit(find: a.replace, replace: a.find, reason: "undo")], to: r.text)
        XCTAssertEqual(undo.text, t, "applied=\(a)")
    }

    /// Reproduces the exact edit list Sonnet returned in test_r7 (overlapping context words).
    func test_c7_overlappingContextEditsAllLand() {
        let t = "here is the shopping list column eggs Kama bread Kama and butter"
        let edits = [
            SpanEdit(find: "list column eggs", replace: "list: eggs", reason: "spoken colon"),
            SpanEdit(find: "eggs Kama bread", replace: "eggs, bread", reason: "spoken comma"),
            SpanEdit(find: "bread Kama and butter", replace: "bread, and butter", reason: "spoken comma"),
        ]
        let s = CleanupFaithfulness.screen(edits)
        let r = SpanEditApplier.apply(s.kept, to: t)
        print("PASS1 C7 OUT: \(r.text) applied=\(r.applied.count) rejected=\(r.rejected)")
        XCTAssertFalse(r.text.contains("Kama"), "a garbled comma survived: \(r.text)")
        XCTAssertEqual(r.text, "here is the shopping list: eggs, bread, and butter")
    }

    // MARK: - (b) Screen keeps self-corrections, still guards meaning, offline

    func test_b0_screenKeepsSelfCorrectionEdits() {
        let edits = [
            SpanEdit(find: "Tuesday no wait Wednesday", replace: "Wednesday", reason: "self-correction"),
            SpanEdit(find: "Mark I mean Mike", replace: "Mike", reason: "self-correction"),
            SpanEdit(find: "three sorry four", replace: "four", reason: "self-correction"),
            SpanEdit(find: "blue folder actually the red folder", replace: "red folder", reason: "self-correction"),
        ]
        let s = CleanupFaithfulness.screen(edits)
        XCTAssertEqual(s.kept.count, 4, "all self-correction edits should be kept; rejected=\(s.rejected)")
    }

    func test_b0b_screenRejectsNegationRemoval() {
        let s = CleanupFaithfulness.screen([SpanEdit(find: "do not want", replace: "want", reason: "cleanup")])
        XCTAssertEqual(s.kept.count, 0, "removing a negation must not be kept")
    }

    func test_b0c_screenRejectsNumberChange() {
        let s = CleanupFaithfulness.screen([SpanEdit(find: "12 people", replace: "13 people", reason: "cleanup")])
        XCTAssertEqual(s.kept.count, 0, "changing a number must not be kept")
    }

    func test_b0d_screenRejectsDateChangeWithoutMarker() {
        let s = CleanupFaithfulness.screen([SpanEdit(find: "on Tuesday", replace: "on Wednesday", reason: "cleanup")])
        XCTAssertEqual(s.kept.count, 0, "changing a date with no self-correction marker must not be kept")
    }

    // MARK: - Real calls (Sonnet unless noted)

    private let selfCorrections: [(String, String, [String])] = [
        ("let's meet on Tuesday no wait Wednesday at noon", "Wednesday", ["Tuesday", "no wait"]),
        ("send the file to Mark I mean Mike before lunch", "Mike", ["Mark", "I mean"]),
        ("the call starts at three sorry four o'clock", "four", ["three", "sorry"]),
        ("put the papers in the blue folder actually the red folder", "red folder", ["blue", "actually"]),
    ]

    private func runSelfCorrections(model: CleanupService.Model) async {
        for (input, keep, gone) in selfCorrections {
            let (out, log) = await pipeline(input, model: model)
            XCTAssertTrue(out.contains(keep), "[\(model)] kept word missing. IN: \(input) OUT: \(out) \(log)")
            for g in gone {
                XCTAssertFalse(out.lowercased().contains(g.lowercased()),
                               "[\(model)] '\(g)' should be removed. IN: \(input) OUT: \(out) \(log)")
            }
        }
    }

    func test_r1_selfCorrections_sonnet_run1() async throws { try requireReal(); await runSelfCorrections(model: .sonnet) }
    func test_r2_selfCorrections_sonnet_run2() async throws { try requireReal(); await runSelfCorrections(model: .sonnet) }
    func test_r3_selfCorrections_opus() async throws { try requireReal(); await runSelfCorrections(model: .opus) }

    private let benignMarkers: [(String, String)] = [
        ("I mean it when I say the plan is good", "I mean it"),
        ("what I mean is that the budget is tight this month", "I mean is"),
        ("the draft is actually pretty good now", "actually pretty good"),
        ("it actually worked on the first try", "actually worked"),
        ("sorry I missed your call yesterday", "orry I missed"),
    ]

    private func runBenign() async {
        for (input, phrase) in benignMarkers {
            let (out, log) = await pipeline(input)
            XCTAssertTrue(out.contains(phrase), "benign marker phrase removed. IN: \(input) OUT: \(out) \(log)")
        }
    }

    func test_r4_benignMarkersLeftAlone_run1() async throws { try requireReal(); await runBenign() }
    func test_r5_benignMarkersLeftAlone_run2() async throws { try requireReal(); await runBenign() }

    func test_r6_spokenPunctuationReadsNaturally() async throws {
        try requireReal()
        let input = "I bought apples Kama pears and milk paired then I went home"
        let (out, log) = await pipeline(input)
        XCTAssertTrue(out.contains("apples, pears"), "IN: \(input) OUT: \(out) \(log)")
        XCTAssertTrue(out.contains("milk."), "IN: \(input) OUT: \(out) \(log)")
        XCTAssertFalse(out.contains("Kama") || out.contains("paired"), "IN: \(input) OUT: \(out) \(log)")
        assertNatural(out, log)
    }

    func test_r7_spokenColonReadsNaturally() async throws {
        try requireReal()
        let input = "here is the shopping list column eggs Kama bread Kama and butter"
        let (out, log) = await pipeline(input)
        XCTAssertTrue(out.contains("list:"), "IN: \(input) OUT: \(out) \(log)")
        XCTAssertTrue(out.contains("eggs, bread"), "IN: \(input) OUT: \(out) \(log)")
        XCTAssertFalse(out.contains("column") || out.contains("Kama"), "IN: \(input) OUT: \(out) \(log)")
        assertNatural(out, log)
    }

    func test_r8_negationAndNumbersPreserved() async throws {
        try requireReal()
        let input = "we can't ship on the 14th Kama so plan for the 21st with 12 people and a budget of 4500 dollars"
        let (out, log) = await pipeline(input)
        XCTAssertTrue(out.contains("can't") || out.contains("cannot") || out.contains("can not"), "negation lost. OUT: \(out) \(log)")
        for n in ["14th", "21st", "12", "4500"] {
            XCTAssertTrue(out.contains(n) || (n == "4500" && out.contains("4,500")), "number \(n) lost. OUT: \(out) \(log)")
        }
        assertNatural(out, log)
    }

    func test_r9_negationNotRemovedWhenNoMarker() async throws {
        try requireReal()
        let input = "I do not want the report by Friday I want it by Monday"
        let (out, log) = await pipeline(input)
        XCTAssertTrue(out.contains("not"), "negation removed. OUT: \(out) \(log)")
        XCTAssertTrue(out.contains("Friday") && out.contains("Monday"), "day changed. OUT: \(out) \(log)")
    }

    func test_r10_trailingFragmentKeptVerbatim() async throws {
        try requireReal()
        let input = "I finished the slides for the review and then the"
        let (out, log) = await pipeline(input)
        XCTAssertTrue(out.contains("and then the"), "fragment altered. OUT: \(out) \(log)")
        let tail = out.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(tail.hasSuffix("and then the") || tail.hasSuffix("and then the.") || tail.hasSuffix("and then the..."),
                      "words added after fragment. OUT: \(out) \(log)")
    }

    func test_r11_cleanTextUnchangedInMeaning() async throws {
        try requireReal()
        let input = "The meeting moved to Thursday at 3 pm."
        let (out, log) = await pipeline(input)
        XCTAssertEqual(out, input, "already-clean text should not be rewritten. \(log)")
    }

    func test_r12_selfCorrectionPlusPunctuation() async throws {
        try requireReal()
        let input = "the total is 40 dollars no wait 45 dollars Kama please pay by Friday"
        let (out, log) = await pipeline(input)
        XCTAssertTrue(out.contains("45"), "OUT: \(out) \(log)")
        XCTAssertFalse(out.contains("40"), "false start kept. OUT: \(out) \(log)")
        XCTAssertFalse(out.lowercased().contains("no wait"), "marker kept. OUT: \(out) \(log)")
        XCTAssertTrue(out.contains("Friday"), "OUT: \(out) \(log)")
        assertNatural(out, log)
    }
}
