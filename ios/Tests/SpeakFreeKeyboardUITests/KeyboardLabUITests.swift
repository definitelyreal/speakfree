// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import XCTest

final class KeyboardLabUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-AppleLanguages")
        app.launchArguments.append("(en)")
        app.launch()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    func testKeyboardLabExposesEveryContext() {
        XCTAssertTrue(app.textFields["standardTextField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["emailTextField"].exists)
        XCTAssertTrue(app.textFields["urlTextField"].exists)
        XCTAssertTrue(app.textFields["numberTextField"].exists)
        XCTAssertTrue(app.textFields["searchTextField"].exists)
        let privacyPolicy = app.descendants(matching: .any)["keyboardPrivacyPolicy"]
        for _ in 0..<3 where !privacyPolicy.exists { app.swipeUp() }
        XCTAssertTrue(privacyPolicy.waitForExistence(timeout: 2))
    }

    func testTapTypingUsesTheSpeakFreeExtension() {
        let field = focusField("standardTextField")
        typeKeys(["key_h", "key_e", "key_l", "key_l", "key_o"])

        XCTAssertEqual(field.value as? String, "Hello")
    }

    func testShiftCapsLockAndDoubleSpacePeriod() {
        let field = focusField("standardTextField")

        tapKey("key_shift")
        tapKey("key_a")
        XCTAssertEqual(field.value as? String, "a", "Shift-off must override sentence auto-capitalization")

        key("key_shift").doubleTap()
        typeKeys(["key_b", "key_c"])
        XCTAssertEqual(field.value as? String, "aBC", "Double-shift must persist as caps lock")

        tapKey(label: "Space")
        tapKey(label: "Space")
        XCTAssertEqual(field.value as? String, "aBC. ")
    }

    func testTypedCorrectionCandidateAndImmediateBackspaceUndo() {
        let field = focusField("standardTextField")
        typeKeys(["key_w", "key_r", "key_o", "key_k"])

        let correction = app.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "work")
        ).firstMatch
        XCTAssertTrue(correction.waitForExistence(timeout: 5), "Expected the correction candidate for ‘wrok’")
        correction.tap()
        XCTAssertEqual(field.value as? String, "Work ")

        tapKey("key_delete")
        XCTAssertEqual(field.value as? String, "Wrok")
    }

    func testEmailAndURLLayoutsStayVerbatim() {
        let email = focusField("emailTextField")
        typeKeys(["key_e", "key_x", "key_p"])
        tapKey(label: ".")
        typeKeys(["key_c", "key_o", "key_m"])
        XCTAssertEqual(email.value as? String, "exp.com")
        XCTAssertTrue(key(label: "@").exists, "Email layout needs @")

        let url = focusField("urlTextField")
        typeKeys(["key_e", "key_x"])
        tapKey(label: ".com")
        XCTAssertEqual(url.value as? String, "ex.com")
    }

    func testModePageAndPunctuationSpacing() {
        let field = focusField("standardTextField")
        typeKeys(["key_h", "key_i"])
        tapKey(label: "Space")
        tapKey(label: "Numbers")
        XCTAssertTrue(key(label: "Letters").waitForExistence(timeout: 2))
        tapKey(label: ".")
        XCTAssertEqual(field.value as? String, "Hi.")
        tapKey(label: "Letters")
        tapKey("key_w")
        XCTAssertEqual(field.value as? String, "Hi. W")
    }

    func testLongPressAlternateAndCursorDrag() {
        let field = focusField("standardTextField")
        let eKey = key("key_e")
        eKey.press(forDuration: 0.6)
        XCTAssertEqual(field.value as? String, "È")

        typeKeys(["key_t", "key_e", "key_s", "key_t"])
        let space = key(label: "Space")
        let start = space.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.1,
            thenDragTo: start.withOffset(CGVector(dx: -36, dy: 0))
        )
        tapKey("key_x")
        XCTAssertEqual(field.value as? String, "Ètxest")
    }

    func testDeleteWordDrag() {
        let field = focusField("standardTextField")
        typeKeys(["key_h", "key_e", "key_l", "key_l", "key_o"])
        tapKey(label: "Space")
        typeKeys(["key_w", "key_o", "key_r", "key_l", "key_d"])
        let delete = key(label: "Delete")
        let deleteStart = delete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        deleteStart.press(
            forDuration: 0.1,
            thenDragTo: deleteStart.withOffset(CGVector(dx: -44, dy: 0))
        )
        XCTAssertEqual(field.value as? String, "Hello ")
    }

    func testStraightSwipeTraversesTheActualSurfaceAndCommits() {
        let field = focusField("standardTextField")
        let surface = app.descendants(matching: .any)["keyboardSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 2))
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.125))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.125))
        start.press(forDuration: 0.08, thenDragTo: end)

        let predicate = NSPredicate { _, _ in
            guard let value = field.value as? String else { return false }
            return !value.isEmpty && value.hasSuffix(" ")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: field)
        let result = XCTWaiter.wait(for: [expectation], timeout: 6)
        XCTAssertEqual(
            result,
            .completed,
            "Straight surface swipe did not commit. Field=\(String(describing: field.value)), surface=\(String(describing: surface.value))"
        )
        XCTAssertTrue(
            (surface.value as? String)?.contains("source=model") == true,
            "The shipping extension must commit the model result, not a geometric fallback: \(String(describing: surface.value))"
        )
    }

    func testDragsAreSuppressedInNumericAndVerbatimLayouts() {
        for identifier in ["numberTextField", "emailTextField", "urlTextField"] {
            let field = focusField(identifier)
            let initialValue = field.value as? String
            let surface = app.descendants(matching: .any)["keyboardSurface"]
            XCTAssertTrue(surface.waitForExistence(timeout: 2))
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.125))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.125))
            start.press(forDuration: 0.08, thenDragTo: end)
            XCTAssertEqual(
                field.value as? String,
                initialValue,
                "A drag in \(identifier) must not insert an English swipe candidate or degrade into a tap"
            )
        }
    }

    func testCapsLockPersistsAcrossTwoModelSwipeCommits() {
        let field = focusField("standardTextField")
        key("key_shift").doubleTap()
        let surface = app.descendants(matching: .any)["keyboardSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 2))
        performStraightSwipe(on: surface)
        performStraightSwipe(on: surface)

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let value = field.value as? String else { return false }
                return value.split(separator: " ").count == 2
            },
            object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
        let words = (field.value as? String)?.split(separator: " ").map(String.init) ?? []
        XCTAssertEqual(words.count, 2)
        XCTAssertTrue(words.allSatisfy { $0 == $0.uppercased() }, "Caps lock must survive swipe commits: \(words)")
    }

    func testQueuedSentenceSwipesConsumeOneShotCapitalizationOnce() {
        let field = focusField("standardTextField")
        let surface = app.descendants(matching: .any)["keyboardSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 2))
        performStraightSwipe(on: surface)
        performStraightSwipe(on: surface)

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let value = field.value as? String else { return false }
                return value.split(separator: " ").count == 2
            },
            object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
        let words = (field.value as? String)?.split(separator: " ").map(String.init) ?? []
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0], words[0].prefix(1).uppercased() + words[0].dropFirst().lowercased())
        XCTAssertEqual(words[1], words[1].lowercased(), "Only the first queued sentence swipe may consume one-shot shift: \(words)")
    }

    func testRotationKeepsTheExtensionInteractive() {
        let field = focusField("standardTextField")
        XCUIDevice.shared.orientation = .landscapeLeft
        let surface = app.descendants(matching: .any)["keyboardSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        tapKey("key_h")
        XCTAssertEqual(field.value as? String, "H")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        tapKey("key_i")
        XCTAssertEqual(field.value as? String, "Hi")
    }

    private func focusField(_ identifier: String) -> XCUIElement {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing host field \(identifier)")
        if !field.isHittable {
            app.swipeUp()
        }
        field.tap()
        activateSpeakFreeKeyboard()
        return field
    }

    private func activateSpeakFreeKeyboard() {
        let surface = app.descendants(matching: .any)["keyboardSurface"]
        if surface.waitForExistence(timeout: 1) { return }

        let emoji = app.buttons["Emoji"].firstMatch
        if emoji.waitForExistence(timeout: 2), emoji.isHittable {
            emoji.press(forDuration: 1)
            let speakFree = app.staticTexts["SpeakFree Keyboard"].firstMatch
            if speakFree.waitForExistence(timeout: 2) {
                speakFree.tap()
                dismissSystemKeyboardTutorialIfNeeded()
                if surface.waitForExistence(timeout: 2) { return }
            }
        }

        for _ in 0..<5 {
            let nextKeyboard = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label == %@", "next keyboard", "Emoji")
            ).firstMatch
            guard nextKeyboard.waitForExistence(timeout: 1) else { break }
            nextKeyboard.tap()
            dismissSystemKeyboardTutorialIfNeeded()
            if surface.waitForExistence(timeout: 1) { return }
        }

        XCTFail("SpeakFree keyboardSurface never appeared. Enable it with KeyboardEnablementUITests first. Hierarchy: \(app.debugDescription)")
    }

    private func dismissSystemKeyboardTutorialIfNeeded() {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 1), continueButton.isHittable {
            continueButton.tap()
        }
    }

    private func tapKey(_ identifier: String) {
        key(identifier).tap()
    }

    private func tapKey(label: String) {
        key(label: label).tap()
    }

    private func key(_ identifier: String) -> XCUIElement {
        let key = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(key.waitForExistence(timeout: 2), "Missing SpeakFree key \(identifier)")
        return key
    }

    private func key(label: String) -> XCUIElement {
        let key = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 2), "Missing SpeakFree key labeled \(label)")
        return key
    }

    private func typeKeys(_ identifiers: [String]) {
        for identifier in identifiers { tapKey(identifier) }
    }

    private func performStraightSwipe(on surface: XCUIElement) {
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.125))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.125))
        start.press(forDuration: 0.08, thenDragTo: end)
    }
}
