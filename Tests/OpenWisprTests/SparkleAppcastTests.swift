import XCTest
@testable import OpenWisprLib

final class SparkleAppcastTests: XCTestCase {

    private func appcastURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/OpenWisprTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // project root
            .appendingPathComponent("docs/appcast.xml")
    }

    func testAppcastEdSignatureIsValid() throws {
        let content = try String(contentsOf: appcastURL(), encoding: .utf8)

        // Use capture group — not replacingOccurrences (fragile on whitespace variation)
        let pattern = #"sparkle:edSignature="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range) else {
            XCTFail("No sparkle:edSignature found in appcast.xml")
            return
        }
        guard let captureRange = Range(match.range(at: 1), in: content) else {
            XCTFail("Failed to extract sparkle:edSignature capture group")
            return
        }
        let signatureBase64 = String(content[captureRange])

        guard let signatureData = Data(base64Encoded: signatureBase64, options: .ignoreUnknownCharacters) else {
            XCTFail("sparkle:edSignature is not valid base64: \(signatureBase64)")
            return
        }

        // Ed25519 signatures are always exactly 64 bytes
        XCTAssertEqual(signatureData.count, 64,
            "Ed25519 signature must be exactly 64 bytes, got \(signatureData.count) (base64: \(signatureBase64))")
    }

    func testAppcastHasRequiredFields() throws {
        let content = try String(contentsOf: appcastURL(), encoding: .utf8)
        XCTAssertTrue(content.contains("<sparkle:version>"), "appcast must include <sparkle:version> element")
        XCTAssertTrue(content.contains("<sparkle:minimumSystemVersion>"), "appcast must include <sparkle:minimumSystemVersion> element")
        XCTAssertTrue(content.contains("sparkle:edSignature="), "appcast must include Ed25519 edSignature (not legacy DSA)")
    }
}
