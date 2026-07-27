// Claude · 2026-07-26 · Session: 78338551-f6c1-40e1-aa9b-b5793e491135
import XCTest
@testable import SpeakFreeLib

/// The repeat-value gate on live-AX cursor context.
///
/// On 2026-07-26, 83 of the day's AX reads in VS Code returned one of exactly two constant
/// strings (22 and 32 chars) while every genuine context length appeared once or twice.
/// speakfree treated that fixed UI string as "the text before your cursor" and therefore
/// prepended a space and lowercased the first word: 57 wrongly-lowercased dictations that
/// day, 63 the day before, 0 on the two days before the Electron AX unlock shipped.
final class LiveAXContextRepeatTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppDelegate.resetLiveAXContextMemory()
    }

    override func tearDown() {
        AppDelegate.resetLiveAXContextMemory()
        super.tearDown()
    }

    /// The exact production shape: the same 32-char string read over and over in VS Code.
    /// First read is allowed (we cannot know yet); every repeat is rejected.
    func testTheConstantStringIsRejectedFromTheSecondReadOnward() {
        let chrome = String(repeating: "x", count: 32)
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat(chrome, bundleID: "com.microsoft.VSCode"),
                       "the first sighting cannot be judged a repeat")
        for read in 2...40 {
            XCTAssertTrue(AppDelegate.liveAXContextIsRepeat(chrome, bundleID: "com.microsoft.VSCode"),
                          "read \(read) of the identical string must be rejected")
        }
    }

    /// Real context changes between dictations — he types, or our own insertion lands in the
    /// field. None of these may be rejected, or the feature is dead rather than fixed.
    func testGenuinelyChangingContextIsAlwaysAccepted() {
        let app = "com.microsoft.VSCode"
        let real = [
            "Please look at ",
            "Please look at today's dictation. ",
            "Please look at today's dictation. There's been ",
            "ok so ",
            "ok so now ",
        ]
        for context in real {
            XCTAssertFalse(AppDelegate.liveAXContextIsRepeat(context, bundleID: app),
                           "changing context must be trusted: \(context)")
        }
    }

    /// Alternating between two fields must not read as a repeat of either.
    func testAlternatingBetweenTwoDistinctContextsIsAccepted() {
        let app = "com.microsoft.VSCode"
        for _ in 0..<10 {
            XCTAssertFalse(AppDelegate.liveAXContextIsRepeat("first field text", bundleID: app))
            XCTAssertFalse(AppDelegate.liveAXContextIsRepeat("second field text", bundleID: app))
        }
    }

    /// The memory is per-app: the same string in a different app is a different observation,
    /// so one app's chrome cannot suppress another app's genuine context.
    func testMemoryIsPerApp() {
        let same = "Search for "
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat(same, bundleID: "com.microsoft.VSCode"))
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat(same, bundleID: "com.apple.MobileSMS"),
                       "a different app has its own memory")
        XCTAssertTrue(AppDelegate.liveAXContextIsRepeat(same, bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(AppDelegate.liveAXContextIsRepeat(same, bundleID: "com.apple.MobileSMS"))
    }

    /// A nil bundle id must not collapse every app into one bucket with real apps.
    func testNilBundleGetsItsOwnBucket() {
        let text = "some context"
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat(text, bundleID: nil))
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat(text, bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(AppDelegate.liveAXContextIsRepeat(text, bundleID: nil))
    }

    /// Returning to an unchanged field after visiting another app costs one skipped
    /// context. Documented deliberately: the failure direction is "no lowercase, no
    /// prepended space", which is the safe direction and what 07-24 did all day.
    func testReturningToAnUnchangedFieldIsRejectedAndThatIsTheSafeDirection() {
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat("Hi there ", bundleID: "com.apple.MobileSMS"))
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat("elsewhere", bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(AppDelegate.liveAXContextIsRepeat("Hi there ", bundleID: "com.apple.MobileSMS"),
                      "unchanged field reads as a repeat — accepted cost, fails toward doing nothing")
    }

    /// Empty string is still a value and must follow the same rule rather than crashing or
    /// being special-cased into always-trusted.
    func testEmptyContextFollowsTheSameRule() {
        XCTAssertFalse(AppDelegate.liveAXContextIsRepeat("", bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(AppDelegate.liveAXContextIsRepeat("", bundleID: "com.microsoft.VSCode"))
    }
}
