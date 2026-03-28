import XCTest
@testable import OpenWisprLib

final class WhisperLanguagesTests: XCTestCase {

    func testSearchByNamePrefix() {
        let results = WhisperLanguage.search("jap")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "ja")
        XCTAssertEqual(results.first?.name, "Japanese")
    }

    func testSearchByCodePrefix() {
        let results = WhisperLanguage.search("es")
        let codes = results.map(\.id)
        XCTAssertTrue(codes.contains("es"), "Should include Spanish (es)")
        XCTAssertTrue(codes.contains("et"), "Should include Estonian (et)")
    }

    func testSearchEmptyReturnsAll() {
        let results = WhisperLanguage.search("")
        XCTAssertEqual(results.count, 100, "Empty search should return all 100 languages")
    }

    func testMultilingualModelConversion() {
        XCTAssertEqual(WhisperLanguage.multilingualModel(for: "small.en"), "small")
        XCTAssertEqual(WhisperLanguage.multilingualModel(for: "tiny.en"), "tiny")
        XCTAssertEqual(WhisperLanguage.multilingualModel(for: "large-v3"), "large-v3")
        XCTAssertEqual(WhisperLanguage.multilingualModel(for: "base"), "base")
    }

    func testIsEnglishOnly() {
        XCTAssertTrue(WhisperLanguage.isEnglishOnly("small.en"))
        XCTAssertTrue(WhisperLanguage.isEnglishOnly("tiny.en"))
        XCTAssertFalse(WhisperLanguage.isEnglishOnly("small"))
        XCTAssertFalse(WhisperLanguage.isEnglishOnly("large-v3"))
    }

    func testFindByCode() {
        let en = WhisperLanguage.find("en")
        XCTAssertNotNil(en)
        XCTAssertEqual(en?.name, "English")

        let yue = WhisperLanguage.find("yue")
        XCTAssertNotNil(yue)
        XCTAssertEqual(yue?.name, "Cantonese")

        XCTAssertNil(WhisperLanguage.find("zz"), "Unknown code should return nil")
    }

    func testAllLanguagesHaveUniqueIds() {
        let ids = WhisperLanguage.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "All language codes should be unique")
    }
}
