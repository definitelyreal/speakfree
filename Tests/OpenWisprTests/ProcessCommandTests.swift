import XCTest
@testable import OpenWisprLib

final class ProcessCommandTests: XCTestCase {

    func test_ProcessResult_isJSONEncodable() throws {
        let result = ProcessResult(raw: "hello world.", processed: "Hello world.", styled: "Hello world.")
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["raw"] as? String, "hello world.")
        XCTAssertEqual(json["processed"] as? String, "Hello world.")
        XCTAssertEqual(json["styled"] as? String, "Hello world.")
    }

    func test_ProcessResult_fieldNames_matchJSONSpec() throws {
        // JSON spec requires exactly raw, processed, styled — no extras, no renaming.
        let result = ProcessResult(raw: "r", processed: "p", styled: "s")
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["raw", "processed", "styled"])
    }
}
