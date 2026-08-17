// ai-suggestion:unverified · session:unknown · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class VocabularyTrieTests: XCTestCase {
    func testContainsWordsAndPrefixesCaseInsensitively() {
        let trie = VocabularyTrie(entries: [
            VocabularyEntry(word: "Cat", frequency: 10),
            VocabularyEntry(word: "car", frequency: 5),
        ])

        XCTAssertTrue(trie.contains("cat"))
        XCTAssertTrue(trie.contains("CAT"))
        XCTAssertTrue(trie.containsPrefix("ca"))
        XCTAssertFalse(trie.contains("ca"))
        XCTAssertFalse(trie.containsPrefix("cab"))
    }
}
