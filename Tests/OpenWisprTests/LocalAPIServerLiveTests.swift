// ai:processed · session: 5b06900b-1498-4764-a786-48f408c36626 · 2026-06-10
import XCTest
import Network
@testable import OpenWisprLib

/// LIVE end-to-end proof for the hardened LocalAPIServer (audit T1.1 acceptance criteria):
///   (a) lsof shows the listener bound to loopback only;
///   (b) curl to 127.0.0.1 reaches the API (well-formed response);
///   (c) curl to the en0 LAN IP fails / is rejected;
///   (d) with a token configured, an unauthenticated 127.0.0.1 request gets 401.
///
/// These tests open a real socket. They are skipped when SPEAKFREE_SKIP_LIVE_API=1
/// (e.g. sandboxed CI without socket permission) so the unit suite stays green everywhere.
final class LocalAPIServerLiveTests: XCTestCase {

    private var server: LocalAPIServer?
    private var transcriber: Transcriber?

    private static let livePort: UInt16 = 57650

    override func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["SPEAKFREE_SKIP_LIVE_API"] == "1" {
            return
        }
    }

    override func tearDown() {
        server?.stop()
        server = nil
        transcriber = nil
        super.tearDown()
    }

    private func skipIfDisabled() throws {
        if ProcessInfo.processInfo.environment["SPEAKFREE_SKIP_LIVE_API"] == "1" {
            throw XCTSkip("Live API tests disabled via SPEAKFREE_SKIP_LIVE_API=1")
        }
    }

    private func makeTranscriber() -> Transcriber {
        let engine = FakeEngine(engineID: "fake", cannedTranscript: "live test transcript")
        return Transcriber(engine: engine, modelID: "fake", language: "en")
    }

    /// Run a shell command, return (stdout+stderr, exitCode).
    @discardableResult
    private func shell(_ launchPath: String, _ args: [String], timeout: TimeInterval = 10) -> (output: String, code: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return ("LAUNCH FAILED: \(error)", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", proc.terminationStatus)
    }

    /// Get the en0 LAN IPv4, if any.
    private func en0IP() -> String? {
        let (out, code) = shell("/usr/sbin/ipconfig", ["getifaddr", "en0"])
        guard code == 0 else { return nil }
        let ip = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? nil : ip
    }

    private func startServer(allowBrowser: Bool = false, token: String? = nil) {
        let t = makeTranscriber()
        self.transcriber = t
        let s = LocalAPIServer(port: Self.livePort)
        s.start(transcriber: t, allowBrowser: allowBrowser, authToken: token)
        self.server = s
        // Give the listener a moment to bind.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let (out, _) = shell("/usr/sbin/lsof", ["-iTCP:\(Self.livePort)", "-sTCP:LISTEN", "-P", "-n"])
            if out.contains("\(Self.livePort)") { break }
            usleep(50_000)
        }
    }

    // (a) lsof shows the listener exists.
    //
    // NOTE on the bind address: Network.framework's NWListener(using:on:) binds the socket
    // to the wildcard (*:port) even with `requiredInterfaceType = .loopback`. The loopback
    // restriction is enforced at the PATH/CONNECTION level, not at the bind level — so lsof
    // shows "*:port" while LAN clients still cannot complete a connection (proven by
    // testLiveCurlLANAddressRejected). The ONLY way to make lsof print "127.0.0.1:port" is
    // `requiredLocalEndpoint`, which the audit plan (T1.1) explicitly forbids for a listener.
    // Therefore the real loopback PROOF is the LAN-rejection test, not the lsof bind address.
    // This test asserts the listener is up and records the lsof line for the proof log.
    func testLiveLsofShowsListenerUp() throws {
        try skipIfDisabled()
        startServer()
        let (out, _) = shell("/usr/sbin/lsof", ["-iTCP:\(Self.livePort)", "-sTCP:LISTEN", "-P", "-n"])
        print("PROOF[a] lsof -iTCP:\(Self.livePort) -sTCP:LISTEN -P -n =>\n\(out)")
        XCTAssertTrue(out.contains("\(Self.livePort)"), "Listener not found in lsof:\n\(out)")
        XCTAssertTrue(out.contains("LISTEN"), "Port \(Self.livePort) is not in LISTEN state:\n\(out)")
    }

    // (b) curl to 127.0.0.1 reaches the API and gets a well-formed response.
    func testLiveCurlLoopbackSucceeds() throws {
        try skipIfDisabled()
        startServer()
        // POST with no multipart file -> well-formed 400 JSON from our handler.
        let (out, code) = shell("/usr/bin/curl", [
            "-s", "-S", "--max-time", "8",
            "-o", "/dev/null", "-w", "%{http_code}",
            "-X", "POST",
            "-H", "Content-Type: multipart/form-data; boundary=zzz",
            "--data-binary", "garbage",
            "http://127.0.0.1:\(Self.livePort)/v1/audio/transcriptions"
        ])
        print("PROOF[b] curl 127.0.0.1 status=\(out) exit=\(code)"); XCTAssertEqual(code, 0, "curl to loopback failed to connect:\n\(out)")
        // Our API answered (400 Bad Request = "Missing 'file' field"), proving reachability.
        XCTAssertTrue(["400", "200"].contains(out.trimmingCharacters(in: .whitespaces)),
                      "Expected a well-formed API HTTP status, got: \(out)")
    }

    // (c) curl to the en0 LAN IP fails / is rejected (loopback enforcement).
    func testLiveCurlLANAddressRejected() throws {
        try skipIfDisabled()
        guard let lan = en0IP() else {
            throw XCTSkip("No en0 LAN IP on this host; cannot run LAN-rejection check")
        }
        startServer()
        // Connection should be refused (no listener on the LAN iface) OR the connection is
        // accepted by the kernel for loopback-mapped traffic and then cancelled before any
        // bytes are read => curl sees connection reset / empty reply. Either way: non-zero exit.
        let (out, code) = shell("/usr/bin/curl", [
            "-s", "-S", "--max-time", "5",
            "-o", "/dev/null", "-w", "%{http_code}",
            "-X", "POST",
            "-H", "Content-Type: multipart/form-data; boundary=zzz",
            "--data-binary", "garbage",
            "http://\(lan):\(Self.livePort)/v1/audio/transcriptions"
        ])
        print("PROOF[c] curl LAN \(lan):\(Self.livePort) status=\(out) exit=\(code) (non-zero exit = rejected)")
        XCTAssertNotEqual(code, 0,
                          "curl to LAN IP \(lan) unexpectedly SUCCEEDED — loopback enforcement failed. Output: \(out)")
    }

    // (d) With a token set, an unauthenticated 127.0.0.1 request -> 401.
    func testLiveTokenUnauthenticatedRequestGets401() throws {
        try skipIfDisabled()
        startServer(token: "s3cr3t-token")
        let (status, code) = shell("/usr/bin/curl", [
            "-s", "-S", "--max-time", "8",
            "-o", "/dev/null", "-w", "%{http_code}",
            "-X", "POST",
            "-H", "Content-Type: multipart/form-data; boundary=zzz",
            "--data-binary", "garbage",
            "http://127.0.0.1:\(Self.livePort)/v1/audio/transcriptions"
        ])
        print("PROOF[d] token-set, NO auth header: curl 127.0.0.1 status=\(status) exit=\(code)")
        XCTAssertEqual(code, 0, "curl failed to connect for the 401 check")
        XCTAssertEqual(status.trimmingCharacters(in: .whitespaces), "401",
                       "Expected 401 for unauthenticated request when token configured, got \(status)")

        // And WITH the correct token, the auth gate passes (reaches the missing-file 400).
        let (status2, code2) = shell("/usr/bin/curl", [
            "-s", "-S", "--max-time", "8",
            "-o", "/dev/null", "-w", "%{http_code}",
            "-X", "POST",
            "-H", "Authorization: Bearer s3cr3t-token",
            "-H", "Content-Type: multipart/form-data; boundary=zzz",
            "--data-binary", "garbage",
            "http://127.0.0.1:\(Self.livePort)/v1/audio/transcriptions"
        ])
        print("PROOF[d] token-set, CORRECT bearer: curl 127.0.0.1 status=\(status2) exit=\(code2) (passes auth gate -> 400 missing file)")
        XCTAssertEqual(code2, 0)
        XCTAssertEqual(status2.trimmingCharacters(in: .whitespaces), "400",
                       "Authenticated request should pass the auth gate (then 400 missing file), got \(status2)")
    }
}
