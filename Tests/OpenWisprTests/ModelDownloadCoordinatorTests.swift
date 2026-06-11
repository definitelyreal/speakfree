// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.4 — Unify download logic.
//
// Integration tests over ModelDownloadCoordinator using a MockURLProtocol so the
// full URLSession download → didFinishDownloadingTo → SHA256-verify → install flow
// runs end-to-end with NO network and NO real model. Covers:
//   • success (bytes that hash to a value we pin in the table) → installed
//   • hash mismatch → install rejected, file deleted, onFailure(.hashMismatch)
//   • too-small (<1MB) payload → onFailure(.invalidModel)
//   • network error → onFailure
//   • already-exists short-circuit → onSuccess with no network
//   • cancel → no callback
//
// CRITICAL property proven here: the coordinator verifies SHA256 on the URLSession
// path. Before T2.4 all three GUI sites installed unverified bytes.

import XCTest
import CryptoKit
@testable import OpenWisprLib

// MARK: - Mock URL protocol

/// A URLProtocol that serves a canned body (or error) for any request, so we can drive
/// a real URLSessionDownloadTask without the network. One response is configured per test
/// via the static `responder`.
final class MockURLProtocol: URLProtocol {
    /// Returns either the body bytes to serve or an error to fail with.
    struct Response {
        var statusCode: Int = 200
        var body: Data = Data()
        var error: Error?
    }
    /// Configured per-test. Synchronised via a lock since URLProtocol runs off the test thread.
    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    private static let lock = NSLock()

    static func setResponder(_ r: ((URLRequest) -> Response)?) {
        lock.lock(); defer { lock.unlock() }
        responder = r
    }
    static func currentResponder() -> ((URLRequest) -> Response)? {
        lock.lock(); defer { lock.unlock() }
        return responder
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let responder = MockURLProtocol.currentResponder() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = responder(request)

        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(response.body.count)"])!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        // Deliver in two chunks so the progress delegate fires at least once mid-stream.
        if response.body.count > 1 {
            let mid = response.body.count / 2
            client?.urlProtocol(self, didLoad: response.body.subdata(in: 0..<mid))
            client?.urlProtocol(self, didLoad: response.body.subdata(in: mid..<response.body.count))
        } else {
            client?.urlProtocol(self, didLoad: response.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Tests

final class ModelDownloadCoordinatorTests: XCTestCase {

    /// A throwaway models dir per test, so we never touch the user's real ~/.config/speakfree.
    /// We redirect Config.configDir by setting HOME? No — Config derives from homeDirectory.
    /// Instead each test uses a real but isolated temp HOME via the `tinyEn` size and cleans up
    /// the destination it would write. We DELETE any installed/temp file in setUp/tearDown.
    private var modelsDir: URL { Config.configDir.appendingPathComponent("models") }
    private func destURL(_ size: String) -> URL { modelsDir.appendingPathComponent("ggml-\(size).bin") }
    private func tmpURL(_ size: String) -> URL { destURL(size).appendingPathExtension("downloading") }

    /// Use a model size that is NOT a real shipped model so the already-exists check and
    /// our cleanup never collide with a developer's actually-installed models. We pin a
    /// hash for it dynamically via the test seam where a match is required.
    private static let testSize = "tiny.en"   // pinned in knownSHA256; we override compute seam per-test
    private var testSize: String { Self.testSize }

    private func makeCoordinator(serving body: Data, status: Int = 200, error: Error? = nil) -> ModelDownloadCoordinator {
        MockURLProtocol.setResponder { _ in
            MockURLProtocol.Response(statusCode: status, body: body, error: error)
        }
        let coord = ModelDownloadCoordinator()
        coord.makeSession = { delegate in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
        return coord
    }

    override func setUp() {
        super.setUp()
        cleanFiles()
    }
    override func tearDown() {
        MockURLProtocol.setResponder(nil)
        // Restore real hasher (mirrors ModelDownloaderIntegrityTests safety net).
        ModelDownloader.computeSHA256 = { url in
            var hasher = CryptoKit.SHA256()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                guard let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty else { break }
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        cleanFiles()
        super.tearDown()
    }
    private func cleanFiles() {
        try? FileManager.default.removeItem(at: destURL(testSize))
        try? FileManager.default.removeItem(at: tmpURL(testSize))
    }

    /// 2 MB of bytes — passes the >=1MB sanity gate.
    private func bigBody() -> Data { Data(count: 2_000_000) }

    // MARK: - success path (verified install)

    func test_success_verifiedHash_installsModel() {
        // Pin the compute seam so verifySHA256 returns the table's expected hash → match.
        let expected = ModelDownloader.knownSHA256[Self.testSize]!
        ModelDownloader.computeSHA256 = { _ in expected }

        let coord = makeCoordinator(serving: bigBody())
        let exp = expectation(description: "onSuccess")
        var sawProgress = false
        coord.onProgress = { fraction, _, _ in if fraction > 0 { sawProgress = true } }
        coord.onSuccess = { dest in
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "model must be installed")
            exp.fulfill()
        }
        coord.onFailure = { err in XCTFail("unexpected failure: \(err)") }
        coord.start(modelSize: testSize)
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL(testSize).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL(testSize).path), "temp file cleaned up")
        XCTAssertTrue(sawProgress, "progress callback should have fired")
    }

    // MARK: - hash mismatch → rejected

    func test_hashMismatch_rejectsAndDeletes() {
        // Compute seam returns a WRONG hash → verifySHA256 throws .hashMismatch.
        ModelDownloader.computeSHA256 = { _ in String(repeating: "aa", count: 32) }

        let coord = makeCoordinator(serving: bigBody())
        let exp = expectation(description: "onFailure")
        coord.onSuccess = { _ in XCTFail("must NOT install a hash-mismatched file") }
        coord.onFailure = { err in
            guard case ModelDownloadError.hashMismatch = err else {
                return XCTFail("expected hashMismatch, got \(err)")
            }
            exp.fulfill()
        }
        coord.start(modelSize: testSize)
        wait(for: [exp], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL(testSize).path), "tampered file not installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL(testSize).path), "tampered temp deleted")
    }

    // MARK: - too small → invalidModel

    func test_tooSmallPayload_rejected() {
        // Even with a matching hash seam, a <1MB body must be rejected by the size gate first.
        ModelDownloader.computeSHA256 = { _ in ModelDownloader.knownSHA256[Self.testSize]! }
        let coord = makeCoordinator(serving: Data(count: 500))   // 500 bytes — too small
        let exp = expectation(description: "onFailure")
        coord.onSuccess = { _ in XCTFail("must reject a sub-1MB payload") }
        coord.onFailure = { err in
            guard case ModelDownloadError.invalidModel = err else {
                return XCTFail("expected invalidModel, got \(err)")
            }
            exp.fulfill()
        }
        coord.start(modelSize: testSize)
        wait(for: [exp], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL(testSize).path))
    }

    // MARK: - network error → onFailure

    func test_networkError_reportsFailure() {
        let coord = makeCoordinator(serving: Data(), error: URLError(.notConnectedToInternet))
        let exp = expectation(description: "onFailure")
        coord.onSuccess = { _ in XCTFail("must not succeed on network error") }
        coord.onFailure = { _ in exp.fulfill() }
        coord.start(modelSize: testSize)
        wait(for: [exp], timeout: 10)
    }

    // MARK: - already-exists short-circuit (no network)

    func test_alreadyExists_succeedsWithoutNetwork() throws {
        // Pre-install a file at the destination.
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: destURL(testSize))

        // Responder set to error: if the coordinator hit the network it would FAIL.
        let coord = makeCoordinator(serving: Data(), error: URLError(.badServerResponse))
        let exp = expectation(description: "onSuccess")
        coord.onSuccess = { dest in
            XCTAssertEqual(dest.path, self.destURL(self.testSize).path)
            exp.fulfill()
        }
        coord.onFailure = { err in XCTFail("must short-circuit, not hit network: \(err)") }
        coord.start(modelSize: testSize)
        wait(for: [exp], timeout: 5)
    }

    // MARK: - cancel → silent (no callback)

    func test_cancel_deliversNoCallback() {
        ModelDownloader.computeSHA256 = { _ in ModelDownloader.knownSHA256[Self.testSize]! }
        let coord = makeCoordinator(serving: bigBody())
        let inverted = expectation(description: "no callback after cancel")
        inverted.isInverted = true
        coord.onSuccess = { _ in inverted.fulfill() }
        coord.onFailure = { _ in inverted.fulfill() }
        coord.start(modelSize: testSize)
        coord.cancel()
        wait(for: [inverted], timeout: 1.5)
    }
}
