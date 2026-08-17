// ai-suggestion:unverified · session:unknown · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class TypingLayoutTests: XCTestCase {
    func testEveryKeyboardContextSelectsItsExpectedLayout() {
        let expected: [TypingKeyboardType: TypingLayout] = [
            .default: .alphabetic,
            .asciiCapable: .alphabetic,
            .numbersAndPunctuation: .numbersAndPunctuation,
            .url: .url,
            .numberPad: .numeric,
            .phonePad: .phone,
            .namePhonePad: .nameAndPhone,
            .emailAddress: .email,
            .decimalPad: .decimal,
            .twitter: .social,
            .webSearch: .webSearch,
            .asciiCapableNumberPad: .numeric
        ]

        XCTAssertEqual(expected.count, TypingKeyboardType.allCases.count)
        for keyboardType in TypingKeyboardType.allCases {
            XCTAssertEqual(TypingLayout.select(for: keyboardType), expected[keyboardType])
        }
    }

    func testLongPressAlternatesAreStableAndCaseInsensitive() {
        XCTAssertEqual(TypingAlternates.alternatives(for: "E"), ["È", "É", "Ê", "Ë", "Ē", "Ė", "Ę"])
        XCTAssertEqual(TypingAlternates.alternatives(for: "?"), ["¿"])
        XCTAssertEqual(TypingAlternates.alternatives(for: "x"), [])
    }
}
