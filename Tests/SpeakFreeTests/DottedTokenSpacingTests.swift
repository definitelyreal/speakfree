// ai-suggestion:unverified · session:dbe21016-ccd6-4043-9618-b1d92be483fe · 2026-09-25
import XCTest
@testable import SpeakFreeLib

/// `ensureSpaceAfterPunctuation` must not break dotted tokens the engine already wrote
/// correctly ("H.264" → "H. 264", "Frame.io" → "Frame. Io" before 2026-09-25), while it
/// still spaces real sentence glue ("word.Next") and keeps the older protections.
/// All sentences here are synthetic.
final class DottedTokenSpacingTests: XCTestCase {

    private func processed(_ text: String) -> String {
        TextPostProcessor.process(text, hybrid: true)
    }

    private func unchanged(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(processed(text), text, file: file, line: line)
    }

    // MARK: letter.digit

    func testCodecNamesStayWhole() {
        unchanged("Export it as H.264 please.")
        unchanged("Both H.264 and H.265 files are ready.")
        unchanged("We keep the H.264s for review.")
        unchanged("The delivery spec is H.265.")
    }

    func testLetterDotDigitStaysWholeInLowercase() {
        unchanged("Bump it to version.2 in the file.")
    }

    // MARK: lowercase continuation

    func testFrameIoStaysWhole() {
        unchanged("Upload the cut to Frame.io today.")
        unchanged("The review link is on Frame.io.")
        unchanged("Frame.io is where the notes live.")
    }

    func testLowercaseFrameIoIsNotSplitOrRecapitalized() {
        // Casing is not this rule's job; it must simply stop inventing "frame. Io".
        unchanged("Upload the cut to frame.io today.")
    }

    func testFileNamesAndDomainsStayWhole() {
        unchanged("Open config.json and CLAUDE.md first.")
        unchanged("It runs on Node.js with a bit.ly link.")
        unchanged("I ordered it from Amazon.com yesterday.")
        unchanged("Check the rows in data.db and notes.md tonight.")
    }

    // MARK: capital continuations that are still part of a token

    func testAllCapsOrDigitContinuationStaysWhole() {
        unchanged("The name Frame.IO shows up too.")
        unchanged("The notes live on Frame.IO.")
        unchanged("It runs on Node.JS, Socket.IO and ASP.NET today.")
        unchanged("Read CLAUDE.MD first.")
        unchanged("Encode file.V2 again.")
    }

    func testLetterInsideDottedChainStaysWhole() {
        unchanged("Put it on Frame.i.O, then send it.")
        // No final dot: before 2026-09-25 this became "U.S. A next".
        unchanged("She went to the U.S.A next year.")
    }

    // MARK: sentence glue is still spaced

    func testGluedSentenceGetsASpace() {
        XCTAssertEqual(processed("That was the end.Next we start."),
                       "That was the end. Next we start.")
    }

    func testGluedPronounIGetsASpace() {
        XCTAssertEqual(processed("We finished.I think it worked."),
                       "We finished. I think it worked.")
    }

    func testGluedAbbreviationBeforeNameGetsASpace() {
        XCTAssertEqual(processed("We flew to St.Louis last week."),
                       "We flew to St. Louis last week.")
    }

    func testPeriodAfterClosingParenStillSpaced() {
        XCTAssertEqual(processed("See the note (above).Then continue."),
                       "See the note (above). Then continue.")
    }

    func testEllipsisBeforeLowercaseStillSpaced() {
        XCTAssertEqual(processed("Wait...then go."), "Wait... then go.")
    }

    func testGlueBeforeAllCapsWordGetsASpace() {
        XCTAssertEqual(processed("That was the end.OK so we move on."),
                       "That was the end. OK so we move on.")
        XCTAssertEqual(processed("We finished.NASA called later."),
                       "We finished. NASA called later.")
        XCTAssertEqual(processed("The flag is USA.I think it waves."),
                       "The flag is USA. I think it waves.")
    }

    func testGlueAfterAbbreviationChainGetsASpace() {
        XCTAssertEqual(processed("We left the U.S.Then we flew home."),
                       "We left the U.S. Then we flew home.")
        XCTAssertEqual(processed("It ends at 5 p.m.Then we eat."),
                       "It ends at 5 p.m. Then we eat.")
        XCTAssertEqual(processed("Pick a color, e.g.The red one."),
                       "Pick a color, e.g. The red one.")
        XCTAssertEqual(processed("I read J.R.R.Tolkien last year."),
                       "I read J.R.R. Tolkien last year.")
    }

    func testPronounAndArticleAfterAbbreviationChainGetASpace() {
        XCTAssertEqual(processed("Meet at 5 p.m.I think it works."),
                       "Meet at 5 p.m. I think it works.")
        XCTAssertEqual(processed("See you at 5 p.m.I'll be there."),
                       "See you at 5 p.m. I'll be there.")
        XCTAssertEqual(processed("We left the U.S.I think it was May."),
                       "We left the U.S. I think it was May.")
        XCTAssertEqual(processed("She moved to the U.S.A.I think it was May."),
                       "She moved to the U.S.A. I think it was May.")
        XCTAssertEqual(processed("It starts at 9 a.m.A new day begins."),
                       "It starts at 9 a.m. A new day begins.")
        unchanged("The A.I. is ready.")
    }

    func testKnownLimitsArePinned() {
        // An all-caps word after a dotted chain stays glued (same shape as "ASP.NET").
        unchanged("We left the U.S.NASA called later.")
        // A period after a digit is never spaced; it protects decimals and versions.
        unchanged("Update to version 2.Then restart.")
        // A one-letter extension ending a token is spaced, as it was before this change.
        XCTAssertEqual(processed("Link libfoo.a first."), "Link libfoo. A first.")
    }

    func testGlueBeforeOneLetterWordGetsASpace() {
        XCTAssertEqual(processed("The first cut ended.a new one started."),
                       "The first cut ended. A new one started.")
        XCTAssertEqual(processed("We finished.i think it worked."),
                       "We finished. I think it worked.")
        XCTAssertEqual(processed("We finished.i'm sure it worked."),
                       "We finished. I'm sure it worked.")
        // A one-letter lowercase piece that is not a whole word stays inside its token.
        unchanged("Put it on Frame.i.O, then send it.")
        unchanged("Open the notes.io page.")
    }

    func testLowercaseGlueIsLeftAlone() {
        // Deliberate trade-off: "ended.then" has the same shape as "config.json", and in the
        // archive a multi-letter lowercase continuation was far more often a dotted name.
        unchanged("It ended.then we left.")
    }

    // MARK: older protections

    func testDecimalStaysWhole() {
        unchanged("Meet at 4.30 tomorrow.")
    }

    func testThousandsSeparatorStaysWhole() {
        unchanged("It costs 30,000 dollars.")
    }

    func testMeridiemAbbreviationsStayWhole() {
        unchanged("The call is at 5 p.m. today.")
        unchanged("We met at 9 a.m. and left.")
    }

    func testAcronymStaysWhole() {
        unchanged("She moved to the U.S.A. last year.")
        unchanged("I read a Subs.S.A. essay last night.")
    }

    // MARK: other punctuation marks keep the original rule

    func testCommaQuestionAndColonGlueStillSpaced() {
        XCTAssertEqual(processed("Yes,that works."), "Yes, that works.")
        XCTAssertEqual(processed("Really?Yes."), "Really? Yes.")
        XCTAssertEqual(processed("Note:this matters."), "Note: this matters.")
    }

    // MARK: full pipeline (the path the app calls)

    func testPipelineKeepsDottedTokens() {
        let raw = "Send the H.265 master to Frame.io and update config.json."
        let result = TextPipeline.run(
            TextPipeline.Input(raw: raw, punctuationMode: .hybrid, audioDurationSeconds: 5),
            isRealWord: { _ in true })
        XCTAssertEqual(result.finalText, raw)
    }

    func testPipelineKeepsDottedTokensThroughVocabularyCorrection() {
        // Overrides run after the post-processor and are inserted verbatim, so a curated
        // "frameio" → "Frame.io" override and an engine-written "Frame.io" both survive.
        let result = TextPipeline.run(
            TextPipeline.Input(raw: "Upload FrameIO and the H.264 file to Frame.io.",
                               punctuationMode: .hybrid, glossaryWords: "Frame.io",
                               overrides: ["frameio": "Frame.io"], audioDurationSeconds: 5),
            isRealWord: { _ in true })
        XCTAssertEqual(result.finalText, "Upload Frame.io and the H.264 file to Frame.io.")
    }

    func testPipelineStillSpacesSentenceGlue() {
        let result = TextPipeline.run(
            TextPipeline.Input(raw: "It rendered fine.Now upload it.", punctuationMode: .hybrid,
                               audioDurationSeconds: 5),
            isRealWord: { _ in true })
        XCTAssertEqual(result.finalText, "It rendered fine. Now upload it.")
    }
}
