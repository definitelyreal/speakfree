// Screen-aware name correction (2026-07-25): the on-screen spelling of a homophone
// name beats the ASR's common-spelling default — under conservative guards.

import XCTest
@testable import SpeakFreeLib

final class ScreenNameCorrectorTests: XCTestCase {

    // A fake dictionary: everything except names is "real".
    private let fakeRealWord: (String) -> Bool = { word in
        !["kris", "zander", "rohrlich", "kathy"].contains(word)
    }

    private let chatScreen = """
    Aw thank you! Can you please send him a screenshot of your ticket?
    But I'm giving Kris my car to come up. He has no proof he's the +1.
    Kris said he can drive up Friday. Can he have it?
    """

    func test_theKrisCase_onScreenSpellingWins() {
        let out = ScreenNameCorrector.correct(
            "I told Chris he's good to use it.", screenText: chatScreen,
            isRealWord: fakeRealWord)
        XCTAssertEqual(out, "I told Kris he's good to use it.")
    }

    func test_punctuationSurvives() {
        let out = ScreenNameCorrector.correct(
            "Ask Chris, then confirm.", screenText: chatScreen, isRealWord: fakeRealWord)
        XCTAssertEqual(out, "Ask Kris, then confirm.")
    }

    func test_noScreenText_noChange() {
        let out = ScreenNameCorrector.correct(
            "I told Chris he's good.", screenText: nil, isRealWord: fakeRealWord)
        XCTAssertEqual(out, "I told Chris he's good.")
    }

    /// "Can" recurs and is capitalized in the chat — but it's a dictionary word,
    /// so it must never become a rewrite target (Ken → Can would be a disaster).
    func test_commonWordsOnScreen_neverBecomeTargets() {
        let out = ScreenNameCorrector.correct(
            "Ken said hi.", screenText: chatScreen, isRealWord: fakeRealWord)
        XCTAssertEqual(out, "Ken said hi.")
    }

    /// A name appearing only ONCE on screen is not strong enough evidence.
    func test_singleOccurrence_doesNotFire() {
        let screen = "Meeting with Zander tomorrow about the deck."
        let out = ScreenNameCorrector.correct(
            "Xander will join.", screenText: screen, isRealWord: fakeRealWord)
        XCTAssertEqual(out, "Xander will join.")
    }

    func test_recurringName_fires_xanderToZander() {
        let screen = "Zander: sounds good\nZander: see you at 5"
        let out = ScreenNameCorrector.correct(
            "Tell Xander I'm running late.", screenText: screen, isRealWord: fakeRealWord)
        XCTAssertEqual(out, "Tell Zander I'm running late.")
    }

    /// Lowercase transcript tokens are never touched (proper-noun shaped only).
    func test_lowercaseTokens_untouched() {
        let out = ScreenNameCorrector.correct(
            "the crisp morning air", screenText: chatScreen, isRealWord: fakeRealWord)
        XCTAssertEqual(out, "the crisp morning air")
    }

    /// Ambiguity (two on-screen names sharing a phonetic key) must not fire.
    func test_ambiguousKey_doesNotFire() {
        let screen = "Kris is here. Kris left. Chriss joined. Chriss waved."
        let out = ScreenNameCorrector.correct(
            "Ping Chris now.", screenText: screen,
            isRealWord: { !["kris", "chriss"].contains($0) })
        XCTAssertEqual(out, "Ping Chris now.")
    }

    /// Exact match on screen — nothing to correct, no churn.
    func test_exactMatch_noChange() {
        let out = ScreenNameCorrector.correct(
            "Kris has the ticket.", screenText: chatScreen, isRealWord: fakeRealWord)
        XCTAssertEqual(out, "Kris has the ticket.")
    }

    func test_phoneticKeys() {
        XCTAssertEqual(ScreenNameCorrector.phoneticKey("Chris"),
                       ScreenNameCorrector.phoneticKey("Kris"))
        XCTAssertEqual(ScreenNameCorrector.phoneticKey("Xander"),
                       ScreenNameCorrector.phoneticKey("Zander"))
        XCTAssertEqual(ScreenNameCorrector.phoneticKey("Sara"),
                       ScreenNameCorrector.phoneticKey("Sarah"))
        XCTAssertEqual(ScreenNameCorrector.phoneticKey("Marc"),
                       ScreenNameCorrector.phoneticKey("Mark"))
        XCTAssertNotEqual(ScreenNameCorrector.phoneticKey("Kris"),
                          ScreenNameCorrector.phoneticKey("Kevin"))
    }
}
