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
        reveal(app.textFields["standardTextField"])
        for identifier in [
            "emailTextField", "urlTextField", "numberTextField", "numberPadTextField",
            "decimalPadTextField", "phonePadTextField", "namePhonePadTextField",
            "socialTextField", "searchTextField"
        ] {
            let field = app.textFields[identifier]
            reveal(field)
            XCTAssertTrue(field.exists, "Missing host field \(identifier)")
        }
        let secureField = app.secureTextFields["secureTextField"]
        reveal(secureField)
        XCTAssertTrue(secureField.exists)
        let privacyPolicy = app.descendants(matching: .any)["keyboardPrivacyPolicy"]
        reveal(privacyPolicy)
    }

    func testTapTypingUsesTheSpeakFreeExtension() {
        let field = focusField("standardTextField")
        typeKeys(["key_h", "key_e", "key_l", "key_l", "key_o"])

        XCTAssertEqual(field.value as? String, "Hello")
    }

    func testPortraitKeyboardUsesFullHeightInsteadOfCompressedLandscapeMetrics() {
        _ = focusField("standardTextField")
        let surface = app.descendants(matching: .any)["keyboardSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(
            surface.frame.height,
            200,
            "Portrait keyboard surface was compressed to the landscape row height: \(surface.frame)"
        )
    }

    func testModelDownloadShowsPersistentProgressAndCanBeCancelled() {
        app.terminate()
        app.launchArguments.append("-SpeakFreeModelDownloadUITestFixture")
        app.launch()

        XCTAssertTrue(app.progressIndicators["dictationModelProgress"].waitForExistence(timeout: 2))
        XCTAssertEqual(
            app.staticTexts["dictationStatus"].label,
            "Downloading Parakeet in the background…"
        )
        XCTAssertEqual(
            app.staticTexts["dictationModelDownloadDetail"].label,
            "344 MB of 689 MB"
        )
        let cancel = app.buttons["cancelDictationModelDownload"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(app.buttons["prepareDictationModel"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.buttons["prepareDictationModel"].label, "Resume Local Model Download")
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

    func testNumberPadLayoutExposesOnlyNumberPadControls() {
        let numberPad = focusField("numberPadTextField")

        typeKeys(labels: ["1", "0"])
        XCTAssertEqual(numberPad.value as? String, "10")
        XCTAssertTrue(key(label: "Delete").exists)
        XCTAssertFalse(hasKey(label: "."), "Number pad must not expose a decimal separator")
        XCTAssertFalse(hasKey("key_q"), "Number pad must not expose alphabetic keys")
    }

    func testDecimalPadLayoutExposesItsDecimalSeparator() {
        let decimalPad = focusField("decimalPadTextField")
        typeKeys(labels: ["1", ".", "5"])
        XCTAssertEqual(decimalPad.value as? String, "1.5")
        XCTAssertTrue(key(label: "Delete").exists)
    }

    func testNumbersAndPunctuationPreservesLiteralSpacing() {
        let number = focusField("numberTextField")
        tapKey(label: "1")
        tapKey(label: "Space")
        tapKey(label: ".")

        XCTAssertEqual(
            number.value as? String,
            "1 .",
            "Numeric layouts must not apply prose punctuation or autocorrection rules"
        )
    }

    func testPhonePadUsesItsLayoutOrTheSystemKeyboardFallback() {
        let phonePad = focusField("phonePadTextField", allowingSystemKeyboardFallback: true)
        guard speakFreeKeyboardIsVisible else {
            assertSystemKeyboardFallback()
            return
        }
        typeKeys(labels: ["1", "+", "#"])
        XCTAssertEqual(phonePad.value as? String, "1+#")
        XCTAssertFalse(hasKey(label: "."), "Phone pad must not expose the decimal separator")
    }

    func testNamePhonePadUsesItsLayoutOrTheSystemKeyboardFallback() {
        let namePhone = focusField("namePhonePadTextField", allowingSystemKeyboardFallback: true)
        guard speakFreeKeyboardIsVisible else {
            assertSystemKeyboardFallback()
            return
        }
        typeKeys(["key_j"])
        tapKey(label: "+")
        XCTAssertEqual(namePhone.value as? String, "J+")
        XCTAssertTrue(key(label: "Space").exists)
    }

    func testSocialLayoutExposesHandleAndHashtagControls() {
        let social = focusField("socialTextField")
        typeKeys(["key_a"])
        tapKey(label: "@")
        typeKeys(["key_b"])
        tapKey(label: "#")
        XCTAssertEqual(social.value as? String, "a@b#")
        XCTAssertTrue(key(label: "Space").exists)
    }

    func testSecureFieldFallsBackToTheSystemKeyboard() {
        let secureField = app.secureTextFields["secureTextField"]
        reveal(secureField)
        secureField.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.descendants(matching: .any)["keyboardSurface"].waitForExistence(timeout: 1),
            "iOS must use its protected system keyboard for secure text fields"
        )
    }

    @available(iOS 17.0, *)
    func testKeyboardLabPassesVoiceOverDescriptionAndHitRegionAudits() throws {
        try app.performAccessibilityAudit(for: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait])
    }

    func testSpeakFreeKeysExposeVoiceOverLabelsAndActivateFromAccessibilityElements() {
        let field = focusField("socialTextField")
        let at = key(label: "@")
        let hashtag = key(label: "#")
        let space = key(label: "Space")

        XCTAssertTrue(at.isHittable)
        XCTAssertTrue(hashtag.isHittable)
        XCTAssertTrue(space.isHittable)
        at.tap()
        hashtag.tap()
        space.tap()
        XCTAssertEqual(field.value as? String, "@# ")
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

    func testDeleteWordDragDeletesAHostSelectionExactlyOnce() {
        let field = focusField("standardTextField")
        typeKeys(["key_h", "key_e", "key_l", "key_l", "key_o"])
        tapKey(label: "Space")
        typeKeys(["key_w", "key_o", "key_r", "key_l", "key_d"])

        field.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).doubleTap()
        XCTAssertTrue(
            app.menuItems["Copy"].waitForExistence(timeout: 2),
            "The host must have an active text selection before exercising selection deletion"
        )

        let delete = key(label: "Delete")
        let deleteStart = delete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        deleteStart.press(
            forDuration: 0.1,
            thenDragTo: deleteStart.withOffset(CGVector(dx: -44, dy: 0))
        )
        XCTAssertTrue(
            ["Hello", "Hello "].contains(field.value as? String),
            "Deleting the selection once must preserve the full preceding word"
        )
    }

    func testDeleteLongPressRepeatsWithoutReleaseTap() {
        let field = focusField("standardTextField")
        typeKeys(["key_h", "key_e", "key_l", "key_l", "key_o"])

        key(label: "Delete").press(forDuration: 1.4)
        assertEmpty(field)
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

    func testSwipeCandidateReplacementAndImmediateDeleteUndo() {
        let field = focusField("standardTextField")
        let surface = app.descendants(matching: .any)["keyboardSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 2))
        performStraightSwipe(on: surface)

        let alternate = app.buttons["candidate1"]
        XCTAssertTrue(alternate.waitForExistence(timeout: 6))
        let replacement = alternate.label
        XCTAssertFalse(replacement.isEmpty)
        alternate.tap()
        XCTAssertEqual(field.value as? String, replacement + " ")

        tapKey("key_delete")
        assertEmpty(field)
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

    func testClaimedDictationRevisesOnlyItsOwnedTailAndFinalizes() {
        app.terminate()
        app.launchArguments.append("-SpeakFreeDictationUITestFixture")
        app.launch()

        let field = focusField("standardTextField")
        let mic = key("key_dictation", wait: 3)
        XCTAssertEqual(mic.label, "Insert SpeakFree dictation")
        mic.tap()
        // The claimed local hypothesis appears in the host immediately, revises in place, then
        // the independent terminal pass replaces that owned suffix and applies sentence casing.
        waitForValue("hello wor", in: field, timeout: 4)
        waitForValue("hello world", in: field, timeout: 4)
        waitForValue("Hello world from SpeakFree", in: field, timeout: 10)
    }

    private func focusField(
        _ identifier: String,
        allowingSystemKeyboardFallback: Bool = false
    ) -> XCUIElement {
        // Some system numeric keyboards have no globe key. Prime the selected input mode from a
        // standard field first so a prior fallback test cannot strand the suite on that keyboard.
        if [
            "numberPadTextField", "decimalPadTextField",
            "phonePadTextField", "namePhonePadTextField"
        ].contains(identifier) {
            let bootstrap = app.textFields["standardTextField"]
            reveal(bootstrap)
            bootstrap.tap()
            activateSpeakFreeKeyboard()
        }
        let field = app.textFields[identifier]
        reveal(field)
        XCTAssertTrue(field.exists, "Missing host field \(identifier)")
        field.tap()
        activateSpeakFreeKeyboard(allowingSystemKeyboardFallback: allowingSystemKeyboardFallback)
        return field
    }

    private func assertEmpty(
        _ field: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = field.value as? String
        XCTAssertTrue(
            value == nil || value == "" || value == "Standard text",
            "Expected an empty field, got \(String(describing: value))",
            file: file,
            line: line
        )
    }

    private func reveal(_ element: XCUIElement) {
        guard !element.isHittable else { return }
        // SwiftUI Form virtualizes offscreen rows, and whole-app swipes can land on the custom
        // keyboard after a bootstrap field is focused. Walk forward using gestures confined above
        // the keyboard. If the row is actually above us, reset to the top and make a second pass.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        for _ in 0..<16 where !element.isHittable {
            middle.press(forDuration: 0.01, thenDragTo: upper)
        }
        guard !element.isHittable else { return }
        for _ in 0..<12 { upper.press(forDuration: 0.01, thenDragTo: middle) }
        for _ in 0..<20 where !element.isHittable {
            middle.press(forDuration: 0.01, thenDragTo: upper)
        }
        XCTAssertTrue(element.isHittable, "Element is not reachable: \(element)")
    }

    private var speakFreeKeyboardIsVisible: Bool {
        app.descendants(matching: .any)["keyboardSurface"].waitForExistence(timeout: 0.5)
    }

    private func assertSystemKeyboardFallback() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(speakFreeKeyboardIsVisible)
    }

    private func activateSpeakFreeKeyboard(allowingSystemKeyboardFallback: Bool = false) {
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

        if allowingSystemKeyboardFallback { return }
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

    private func key(_ identifier: String, wait: TimeInterval = 2) -> XCUIElement {
        let key = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(key.waitForExistence(timeout: wait), "Missing SpeakFree key \(identifier)")
        return key
    }

    private func key(label: String, wait: TimeInterval = 2) -> XCUIElement {
        let key = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: wait), "Missing SpeakFree key labeled \(label)")
        return key
    }

    private func hasKey(_ identifier: String) -> Bool {
        app.descendants(matching: .any)[identifier].waitForExistence(timeout: 0.5)
    }

    private func hasKey(label: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
            .waitForExistence(timeout: 0.5)
    }

    private func typeKeys(_ identifiers: [String]) {
        for identifier in identifiers { tapKey(identifier) }
    }

    private func typeKeys(labels: [String]) {
        for label in labels { tapKey(label: label) }
    }

    private func performStraightSwipe(on surface: XCUIElement) {
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.125))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.125))
        start.press(forDuration: 0.08, thenDragTo: end)
    }

    private func waitForValue(
        _ expected: String,
        in field: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: field
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected \(expected), got \(String(describing: field.value))",
            file: file,
            line: line
        )
    }
}
