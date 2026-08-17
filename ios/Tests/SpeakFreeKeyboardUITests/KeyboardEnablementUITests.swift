// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest

/// One-time setup for the dedicated keyboard Simulator. Apple exposes no `simctl` command for
/// enabling third-party keyboards, so this test drives the same Settings UI a person uses.
final class KeyboardEnablementUITests: XCTestCase {
    func testEnableSpeakFreeKeyboardInDedicatedSimulator() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        returnToRoot(in: settings)
        openCell("General", in: settings)
        openCell("Keyboard", in: settings)
        openCell("Keyboards", in: settings)

        if element(labeled: "SpeakFree Keyboard", in: settings).exists {
            return
        }

        openCell("Add New Keyboard", in: settings)
        let keyboard = element(labeled: "SpeakFree Keyboard", in: settings)
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 5),
            "SpeakFree Keyboard was not listed in Settings after installing the containing app. Hierarchy: \(settings.debugDescription)"
        )
        keyboard.tap()

        XCTAssertTrue(
            settings.navigationBars.buttons.firstMatch.waitForExistence(timeout: 2),
            "Settings did not return after adding SpeakFree Keyboard"
        )
    }

    private func element(labeled label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func openCell(
        _ label: String,
        in app: XCUIApplication,
        alternateLabel: String? = nil
    ) {
        var cell = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", label)
        ).firstMatch
        if !cell.waitForExistence(timeout: 3), let alternateLabel {
            cell = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", alternateLabel)
            ).firstMatch
        }
        if !cell.waitForExistence(timeout: 1) {
            cell = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", label)
            ).firstMatch
        }
        XCTAssertTrue(
            cell.waitForExistence(timeout: 3),
            "Missing Settings row: \(label). Hierarchy: \(app.debugDescription)"
        )
        cell.tap()
    }

    private func returnToRoot(in app: XCUIApplication) {
        let general = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "General")
        ).firstMatch
        for _ in 0..<6 {
            if general.waitForExistence(timeout: 1) { return }
            let back = app.navigationBars.buttons.firstMatch
            guard back.waitForExistence(timeout: 1) else { break }
            back.tap()
        }
        XCTAssertTrue(
            general.waitForExistence(timeout: 2),
            "Could not return Settings to its root list. Hierarchy: \(app.debugDescription)"
        )
    }
}
