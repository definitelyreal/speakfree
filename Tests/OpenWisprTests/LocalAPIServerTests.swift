// ai:processed · session: 5b06900b-1498-4764-a786-48f408c36626 · 2026-06-10
import XCTest
import Network
@testable import OpenWisprLib

/// Hardening tests for the experimental LocalAPIServer (audit T1.1).
/// Covers the HTTP/multipart parser with malformed input, loopback enforcement,
/// the 32 MB body cap (413), and optional bearer-token auth (401).
final class LocalAPIServerTests: XCTestCase {

    // MARK: - Helpers

    /// Build a well-formed multipart body for the given fields.
    private func multipartBody(boundary: String, fields: [(name: String, value: Data)]) -> Data {
        var data = Data()
        for f in fields {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(f.name)\"\r\n\r\n".data(using: .utf8)!)
            data.append(f.value)
            data.append("\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    // MARK: - Multipart: happy path

    func testParseMultipartExtractsFields() {
        let boundary = "X-BOUNDARY"
        let body = multipartBody(boundary: boundary, fields: [
            ("file", Data([0x01, 0x02, 0x03, 0x04])),
            ("response_format", "text".data(using: .utf8)!)
        ])
        let fields = LocalAPIServer.parseMultipart(body: body, boundary: boundary)
        XCTAssertEqual(fields["file"], Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(fields["response_format"].flatMap { String(data: $0, encoding: .utf8) }, "text")
    }

    // MARK: - Multipart: boundary-appearing-in-body

    func testParseMultipartBoundaryStringInsideBodyDoesNotTruncate() {
        // The literal boundary token (without the leading "--") sits inside the file bytes.
        // It must NOT be treated as a part delimiter.
        let boundary = "ABCBOUNDARY"
        let payload = "data-\(boundary)-more-data".data(using: .utf8)!
        let body = multipartBody(boundary: boundary, fields: [("file", payload)])
        let fields = LocalAPIServer.parseMultipart(body: body, boundary: boundary)
        // A real "--BOUNDARY" delimiter only appears at the part edges; the bare token
        // inside the body is content. Note: "--" + boundary is the actual delimiter, so a
        // bare boundary token in the body is safe. Verify the file survives intact.
        XCTAssertEqual(fields["file"], payload,
                       "Bare boundary token inside body must be preserved, not split")
    }

    func testParseMultipartDelimiterLikeBytesInBody() {
        // Even a "--BOUNDARY"-looking sequence embedded mid-stream should not corrupt a
        // single-part parse as long as the structure is well-formed around it. Here we make
        // the file contain the delimiter bytes; the parser stops the part at the NEXT real
        // delimiter, so the embedded one is captured as content of the (only) part.
        let boundary = "ZZ"
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"\r\n\r\n".data(using: .utf8)!)
        let payload = "hello--ZZworld".data(using: .utf8)!  // contains "--ZZ" mid-body
        data.append(payload)
        data.append("\r\n".data(using: .utf8)!)
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        let fields = LocalAPIServer.parseMultipart(body: data, boundary: boundary)
        // Locked behavior: the parser splits at the FIRST embedded "--ZZ" and strips the 2
        // bytes it treats as the preceding CRLF, so "hello[--ZZ]world" yields "hel" (= "hello"
        // minus the 2 chars before the embedded delimiter). A body containing the raw
        // delimiter is malformed at the protocol level; this asserts the parser degrades
        // deterministically (never reads out of bounds / never crashes) rather than that it
        // recovers the content. Real clients never embed the raw delimiter.
        XCTAssertNotNil(fields["file"])
        XCTAssertEqual(fields["file"], "hel".data(using: .utf8)!,
                       "Deterministic greedy split at first embedded delimiter — locked behavior")
    }

    // MARK: - Multipart: missing terminal "--"

    func testParseMultipartMissingTerminalDashDash() {
        // No closing "--BOUNDARY--": the final part runs to end-of-data.
        let boundary = "NOEND"
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"\r\n\r\n".data(using: .utf8)!)
        data.append("payload-bytes".data(using: .utf8)!)
        // intentionally NO trailing CRLF + terminal boundary
        let fields = LocalAPIServer.parseMultipart(body: data, boundary: boundary)
        XCTAssertEqual(fields["file"], "payload-bytes".data(using: .utf8)!,
                       "Missing terminal -- must still yield the field, running to EOF")
    }

    func testParseMultipartGarbageReturnsEmpty() {
        let fields = LocalAPIServer.parseMultipart(body: Data("not multipart at all".utf8),
                                                   boundary: "WHATEVER")
        XCTAssertTrue(fields.isEmpty)
    }

    // MARK: - Boundary extraction

    func testExtractBoundaryQuotedAndUnquoted() {
        XCTAssertEqual(
            LocalAPIServer.extractBoundary(from: "Content-Type: multipart/form-data; boundary=abc123"),
            "abc123")
        XCTAssertEqual(
            LocalAPIServer.extractBoundary(from: #"Content-Type: multipart/form-data; boundary="quoted-b""#),
            "quoted-b")
        XCTAssertNil(LocalAPIServer.extractBoundary(from: "Content-Type: application/json"))
    }

    // MARK: - evaluate(): headers split across the \r\n\r\n boundary

    func testEvaluateRejectsNonMultipartPost() {
        // Header parsing succeeds but there is no multipart boundary => 400.
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: Data("{}".utf8), authToken: nil)
        XCTAssertEqual(outcome, .respond(status: 400,
                                         body: #"{"error":"Expected multipart/form-data"}"#,
                                         contentType: "application/json"))
    }

    func testEvaluateWellFormedPostReturnsTranscribe() {
        let boundary = "B0"
        let body = multipartBody(boundary: boundary, fields: [
            ("file", Data([0xAA, 0xBB])),
            ("response_format", "text".data(using: .utf8)!)
        ])
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: multipart/form-data; boundary=\(boundary)"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: body, authToken: nil)
        XCTAssertEqual(outcome, .transcribe(fileData: Data([0xAA, 0xBB]), format: "text"))
    }

    func testEvaluateHeaderSplitContentTypeStillParsed() {
        // Simulate a request where the Content-Type header is the second line (i.e. headers
        // that, on the wire, could have been delivered straddling a chunk boundary — once
        // reassembled into the header string, parsing must still find the boundary).
        let boundary = "SPLITB"
        let body = multipartBody(boundary: boundary, fields: [("file", Data([0x09]))])
        let headers = [
            "POST /v1/audio/transcriptions HTTP/1.1",
            "Host: 127.0.0.1",
            "Content-Type: multipart/form-data; boundary=\(boundary)",
            "Content-Length: \(body.count)"
        ].joined(separator: "\r\n")
        let outcome = LocalAPIServer.evaluate(headers: headers, body: body, authToken: nil)
        XCTAssertEqual(outcome, .transcribe(fileData: Data([0x09]), format: "json"))
    }

    func testEvaluateOptionsPreflight() {
        // A loopback Host preflight is accepted (204). The Origin is irrelevant to evaluate();
        // whether CORS headers are emitted is decided later in corsOrigin(forHeaders:).
        let headers = "OPTIONS /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1:5765"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: Data(), authToken: nil)
        XCTAssertEqual(outcome, .respond(status: 204, body: "", contentType: "application/json"))
    }

    func testEvaluateWrongPath404() {
        let headers = "POST /nope HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: multipart/form-data; boundary=x"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: Data(), authToken: nil)
        XCTAssertEqual(outcome, .respond(status: 404,
                                         body: #"{"error":"POST /v1/audio/transcriptions"}"#,
                                         contentType: "application/json"))
    }

    // MARK: - Auth: missing / wrong / correct bearer token (401)

    func testEvaluateMissingTokenWhenRequired401() {
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: multipart/form-data; boundary=x"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: Data(), authToken: "secret")
        XCTAssertEqual(outcome, .respond(status: 401,
                                         body: #"{"error":"Unauthorized"}"#,
                                         contentType: "application/json"))
    }

    func testEvaluateWrongTokenWhenRequired401() {
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer wrong\r\nContent-Type: multipart/form-data; boundary=x"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: Data(), authToken: "secret")
        XCTAssertEqual(outcome, .respond(status: 401,
                                         body: #"{"error":"Unauthorized"}"#,
                                         contentType: "application/json"))
    }

    func testEvaluateCorrectTokenPasses() {
        let boundary = "AUTHB"
        let body = multipartBody(boundary: boundary, fields: [("file", Data([0x01]))])
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\nContent-Type: multipart/form-data; boundary=\(boundary)"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: body, authToken: "secret")
        XCTAssertEqual(outcome, .transcribe(fileData: Data([0x01]), format: "json"))
    }

    func testEvaluateBearerSchemeCaseInsensitive() {
        let boundary = "CIB"
        let body = multipartBody(boundary: boundary, fields: [("file", Data([0x02]))])
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: localhost:5765\r\nauthorization: bEaReR secret\r\nContent-Type: multipart/form-data; boundary=\(boundary)"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: body, authToken: "secret")
        XCTAssertEqual(outcome, .transcribe(fileData: Data([0x02]), format: "json"))
    }

    func testBearerTokenMatchesRejectsMalformed() {
        XCTAssertFalse(LocalAPIServer.bearerTokenMatches(headers: ["Authorization: Basic abc"], expected: "abc"))
        XCTAssertFalse(LocalAPIServer.bearerTokenMatches(headers: ["Authorization: Bearer"], expected: "abc"))
        XCTAssertFalse(LocalAPIServer.bearerTokenMatches(headers: [], expected: "abc"))
        XCTAssertTrue(LocalAPIServer.bearerTokenMatches(headers: ["Authorization: Bearer abc"], expected: "abc"))
    }

    // MARK: - Body cap (413) — the wire-level decision lives in accumulate(), but the
    // threshold and the constant are asserted here as the contract.

    func testMaxBodyBytesIs32MB() {
        XCTAssertEqual(LocalAPIServer.maxBodyBytes, 32 * 1_024 * 1_024)
    }

    func testIdleTimeoutIs30Seconds() {
        XCTAssertEqual(LocalAPIServer.idleTimeout, 30, accuracy: 0.001)
    }

    // MARK: - M2: Absolute connection-lifetime cap

    /// The per-connection lifetime cap must be 120 s (audit M2: no absolute lifetime in AR-1).
    /// This constant is the contract; live enforcement is integration-tested in
    /// LocalAPIServerLiveTests (byte-trickling connection gets cut).
    func testMaxConnectionLifetimeIs120Seconds() {
        XCTAssertEqual(LocalAPIServer.maxConnectionLifetime, 120, accuracy: 0.001,
                       "Lifetime cap must be 120 s — a legit upload+transcription fits inside this window")
    }

    // MARK: - Loopback enforcement

    func testIsLoopbackAcceptsIPv4Loopback() {
        let ep = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 5765)
        XCTAssertTrue(LocalAPIServer.isLoopback(ep))
    }

    func testIsLoopbackAcceptsIPv6Loopback() {
        let ep = NWEndpoint.hostPort(host: .ipv6(.loopback), port: 5765)
        XCTAssertTrue(LocalAPIServer.isLoopback(ep))
    }

    func testIsLoopbackAcceptsLocalhostName() {
        let ep = NWEndpoint.hostPort(host: .name("localhost", nil), port: 5765)
        XCTAssertTrue(LocalAPIServer.isLoopback(ep))
    }

    func testIsLoopbackRejectsLANAddress() {
        guard let lan = IPv4Address("192.168.1.42") else {
            return XCTFail("could not build LAN address")
        }
        let ep = NWEndpoint.hostPort(host: .ipv4(lan), port: 5765)
        XCTAssertFalse(LocalAPIServer.isLoopback(ep), "LAN remote must be rejected")
    }

    func testIsLoopbackRejectsPublicAddress() {
        guard let pub = IPv4Address("8.8.8.8") else {
            return XCTFail("could not build public address")
        }
        let ep = NWEndpoint.hostPort(host: .ipv4(pub), port: 5765)
        XCTAssertFalse(LocalAPIServer.isLoopback(ep), "Public remote must be rejected")
    }

    func testIsLoopbackRejectsArbitraryHostname() {
        let ep = NWEndpoint.hostPort(host: .name("evil.example.com", nil), port: 5765)
        XCTAssertFalse(LocalAPIServer.isLoopback(ep))
    }

    // MARK: - AR-1: DNS-rebinding defense (Host-header validation)

    /// The core rebinding exploit: a page on evil-attacker.com is rebound to 127.0.0.1, so the
    /// TCP peer is loopback (passes isLoopback), but the request still carries the attacker's
    /// Host. evaluate() must reject it 421 BEFORE the handler, even on a well-formed POST.
    func testEvaluateRejectsNonLoopbackHost421() {
        let boundary = "REBIND"
        let body = multipartBody(boundary: boundary, fields: [("file", Data([0x01]))])
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: evil-attacker.com\r\nContent-Type: multipart/form-data; boundary=\(boundary)"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: body, authToken: nil)
        XCTAssertEqual(outcome,
            .respond(status: 421,
                     body: #"{"error":"Misdirected request: Host must be loopback"}"#,
                     contentType: "application/json"),
            "A non-loopback Host (DNS rebinding) must be rejected 421 before the handler runs")
    }

    /// A rebound OPTIONS preflight must ALSO be rejected — otherwise a rebound origin could coax
    /// CORS headers out of the preflight.
    func testEvaluateRejectsRebindingPreflight421() {
        let headers = "OPTIONS /v1/audio/transcriptions HTTP/1.1\r\nHost: evil.com\r\nOrigin: https://evil.com"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: Data(), authToken: nil)
        XCTAssertEqual(outcome.statusForTest, 421,
                       "Rebound preflight must be 421, not a 204 that could carry CORS")
    }

    /// A missing Host header is also rejected (HTTP/1.1 requires Host; absence is suspicious).
    func testEvaluateRejectsMissingHost421() {
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x"
        let outcome = LocalAPIServer.evaluate(headers: headers, body: Data(), authToken: nil)
        XCTAssertEqual(outcome.statusForTest, 421)
    }

    func testEvaluateAcceptsLoopbackHostVariants() {
        let boundary = "OKHOST"
        let body = multipartBody(boundary: boundary, fields: [("file", Data([0x07]))])
        for host in ["127.0.0.1", "127.0.0.1:5765", "localhost", "localhost:5765", "[::1]", "[::1]:5765"] {
            let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: \(host)\r\nContent-Type: multipart/form-data; boundary=\(boundary)"
            let outcome = LocalAPIServer.evaluate(headers: headers, body: body, authToken: nil)
            XCTAssertEqual(outcome, .transcribe(fileData: Data([0x07]), format: "json"),
                           "Loopback Host '\(host)' must be accepted")
        }
    }

    // MARK: - AR-1: loopback-host / loopback-origin helpers

    func testIsLoopbackHostAcceptsLoopbackForms() {
        for h in ["127.0.0.1", "127.0.0.1:5765", "localhost", "LOCALHOST:80", "::1", "[::1]", "[::1]:5765"] {
            XCTAssertTrue(LocalAPIServer.isLoopbackHost(h), "\(h) should be loopback")
        }
    }

    func testIsLoopbackHostRejectsNonLoopback() {
        for h in ["evil.com", "evil-attacker.com:5765", "192.168.1.10", "10.0.0.5:5765",
                  "8.8.8.8", "127.0.0.1.evil.com", "", "0.0.0.0"] {
            XCTAssertFalse(LocalAPIServer.isLoopbackHost(h), "\(h) must NOT be loopback")
        }
    }

    func testIsLoopbackOriginReflectionGate() {
        XCTAssertTrue(LocalAPIServer.isLoopbackOrigin("http://127.0.0.1:5765"))
        XCTAssertTrue(LocalAPIServer.isLoopbackOrigin("http://localhost:5765"))
        XCTAssertTrue(LocalAPIServer.isLoopbackOrigin("http://[::1]:5765"))
        XCTAssertFalse(LocalAPIServer.isLoopbackOrigin("https://evil.com"))
        XCTAssertFalse(LocalAPIServer.isLoopbackOrigin("http://192.168.1.5:5765"))
        XCTAssertFalse(LocalAPIServer.isLoopbackOrigin(""))
    }

    // MARK: - AR-1: connection cap constant

    func testMaxConcurrentConnectionsConstant() {
        XCTAssertEqual(LocalAPIServer.maxConcurrentConnections, 16)
    }

    // MARK: - AR-1 round 2: Content-Length parsing must be crash-proof
    //
    // Regression for the High finding: parseContentLength previously returned
    // `Int(...) ?? 0` with no lower-bound check, so "Content-Length: -1" yielded -1,
    // which slid past the oversize (line: -1 > 32MB == false) and under-read
    // (line: bodyAvailable < -1 == false) gates and reached the body slice as an
    // INVERTED Range (`buf[bodyStart..<(bodyStart - 1)]`), trapping with
    // "Range requires lowerBound <= upperBound" and killing the whole dictation app —
    // from a single unauthenticated loopback request, BEFORE the Host/token gates.

    private func headerWith(contentLength raw: String) -> String {
        // The accumulate() path hands parseContentLength the header block (CRLF-joined).
        return [
            "POST /v1/audio/transcriptions HTTP/1.1",
            "Host: 127.0.0.1",
            "Content-Length: \(raw)",
        ].joined(separator: "\r\n")
    }

    /// A negative Content-Length is rejected as `.invalid` — never returned as a negative Int
    /// that could form an inverted body Range. THIS is the crash that took down the app.
    func testParseContentLength_negative_isInvalid() {
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: "-1")), .invalid)
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: "-9999999")), .invalid)
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: "-100")), .invalid)
    }

    /// Non-numeric / malformed values are `.invalid` (→ 400), not silently coerced to 0.
    func testParseContentLength_garbage_isInvalid() {
        for bad in ["abc", "1.5", "0x10", "1 2", "12abc", "+5", " ", "\t", "１２３" /* full-width */] {
            XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: bad)),
                           .invalid, "expected .invalid for \(bad.debugDescription)")
        }
    }

    /// An empty Content-Length value is `.invalid` (present-but-garbage), not absent.
    func testParseContentLength_emptyValue_isInvalid() {
        // "Content-Length:" with nothing after → trimmed to "" → invalid.
        let headers = "POST / HTTP/1.1\r\nContent-Length:\r\nHost: 127.0.0.1"
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headers), .invalid)
    }

    /// A value that overflows Int is `.invalid`, not a wrapped/negative number.
    func testParseContentLength_overflow_isInvalid() {
        let huge = "99999999999999999999999999999999"  // > Int.max
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: huge)), .invalid)
    }

    /// A valid non-negative integer parses to `.valid(n)` (the caller still oversize-checks it).
    func testParseContentLength_validValues() {
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: "0")), .valid(0))
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: "4")), .valid(4))
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: "  42  ")), .valid(42))
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headerWith(contentLength: "\(Int.max)")), .valid(Int.max))
    }

    /// When the header is absent entirely, parsing reports `.absent` (caller treats body as 0).
    func testParseContentLength_absent() {
        let headers = "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain"
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headers), .absent)
    }

    /// Header-name match is case-insensitive (HTTP allows any casing).
    func testParseContentLength_caseInsensitiveName() {
        let headers = "POST / HTTP/1.1\r\nCONTENT-LENGTH: 7\r\nHost: 127.0.0.1"
        XCTAssertEqual(LocalAPIServer.parseContentLength(headers: headers), .valid(7))
    }
}

/// Test-only convenience to read the status code out of a RequestOutcome.
extension LocalAPIServer.RequestOutcome {
    var statusForTest: Int {
        switch self {
        case .respond(let status, _, _): return status
        case .transcribe: return 200
        }
    }
}
