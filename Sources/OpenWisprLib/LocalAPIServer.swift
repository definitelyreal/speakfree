// ai:processed · session: 5b06900b-1498-4764-a786-48f408c36626 · 2026-06-10
import Network
import Foundation
import AVFoundation

/// Minimal loopback-only HTTP server exposing POST /v1/audio/transcriptions.
/// Compatible with OpenAI-format clients. EXPERIMENTAL — for local integrations only.
///
/// Hardening (audit T1.1):
///  - Loopback enforced two ways: connections from a non-loopback remote endpoint are
///    cancelled before any bytes are read (primary), and the listener requests the
///    `.loopback` interface type (secondary). We do NOT use `requiredLocalEndpoint`
///    (wrong API for a listener).
///  - DNS-rebinding defense (audit AR-1): the HTTP `Host` header is validated against a
///    loopback allowlist (127.0.0.1 / localhost / [::1], any port). A browser page on
///    `evil.com` rebound to 127.0.0.1 IS a loopback TCP peer, so the remote-endpoint check
///    alone cannot stop it — but its requests still carry `Host: evil.com`, which we reject
///    with `421 Misdirected Request` before any handler runs.
///  - No wildcard CORS (audit AR-1). When `localAPIAllowBrowser` is enabled we reflect the
///    request `Origin` back in `Access-Control-Allow-Origin` ONLY if that origin is itself a
///    loopback origin; all other origins get no CORS headers, so a cross-origin page cannot
///    read the response even if it reaches the socket.
///  - Request body capped at 32 MB (413 over).
///  - Per-connection idle timeout cancels stalled reads.
///  - Absolute per-connection lifetime cap (audit M2): 120 s regardless of activity.
///    A byte-trickling sender can reschedule the idle timer but never the lifetime timer.
///  - Concurrent connections capped (audit AR-1); excess connections are dropped before any
///    buffer is allocated, bounding worst-case memory.
///  - Optional `Authorization: Bearer <token>` when `localAPIToken` is set (else loopback-only).
final class LocalAPIServer {

    /// Maximum accumulated request size before a 413 is returned.
    static let maxBodyBytes = 32 * 1_024 * 1_024
    /// Idle timeout: a connection that sends no bytes for this long is cancelled.
    static let idleTimeout: TimeInterval = 30
    /// Absolute per-connection lifetime cap (audit M2). A connection is cancelled once this
    /// deadline elapses regardless of ongoing activity. Prevents a slow-dripping sender from
    /// holding a slot (and up to 32 MB of buffer) indefinitely — a legitimate transcription
    /// upload + processing fits comfortably inside 120 s.
    static let maxConnectionLifetime: TimeInterval = 120
    /// Maximum simultaneously-accepted connections. Excess connections are cancelled
    /// immediately (before any 32 MB buffer can be allocated) to bound memory under abuse.
    static let maxConcurrentConnections = 16

    private var listener: NWListener?
    private weak var transcriber: Transcriber?
    private let listenPort: UInt16
    private let serverQueue = DispatchQueue(label: "com.speakfree.localapi.server")
    private let requestQueue = DispatchQueue(label: "com.speakfree.localapi.requests", attributes: .concurrent)

    /// Per-instance lifetime override. Seam so tests can shorten the 120 s production default
    /// without waiting that long. Nil = use the static `maxConnectionLifetime`.
    var connectionLifetimeOverride: TimeInterval? = nil

    // Hardening config, captured at start().
    private var allowBrowser = false
    private var authToken: String?

    // Concurrent-connection cap (audit AR-1). Mutated only on `serverQueue` (the listener's
    // newConnectionHandler queue) and decremented from the same queue, so no extra locking.
    private var activeConnections = 0
    private let connectionCountLock = NSLock()

    init(port: UInt16 = 5765) {
        self.listenPort = port
    }

    var port: UInt16 { listenPort }

    // MARK: - Lifecycle

    func start(transcriber: Transcriber, allowBrowser: Bool = false, authToken: String? = nil) {
        stop()
        self.transcriber = transcriber
        self.allowBrowser = allowBrowser
        // Treat empty/whitespace token as "no auth".
        let trimmed = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = (trimmed?.isEmpty == false) ? trimmed : nil

        guard let endpointPort = NWEndpoint.Port(rawValue: listenPort) else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Secondary loopback control: bias the listener to the loopback interface.
        // The primary control is the per-connection remote-endpoint check in accept().
        params.requiredInterfaceType = .loopback

        do {
            listener = try NWListener(using: params, on: endpointPort)
        } catch {
            print("LocalAPI: failed to create listener on port \(listenPort): \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("LocalAPI (experimental): http://127.0.0.1:\(self?.listenPort ?? 0)/v1/audio/transcriptions")
            case .failed(let error):
                print("LocalAPI: listener failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        listener?.start(queue: serverQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionCountLock.lock()
        activeConnections = 0
        connectionCountLock.unlock()
    }

    // MARK: - Loopback enforcement

    /// Returns true only if the connection's remote endpoint is loopback (127.0.0.1 / ::1).
    /// Anything else (LAN, public) is rejected before any bytes are read.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return addr.isLoopback
            case .ipv6(let addr):
                return addr.isLoopback
            case .name(let name, _):
                let lower = name.lowercased()
                return lower == "localhost" || lower == "127.0.0.1" || lower == "::1"
            @unknown default:
                return false
            }
        default:
            // Unknown endpoint kind — fail closed.
            return false
        }
    }

    // MARK: - DNS-rebinding defense (audit AR-1)

    /// True if `host` (an HTTP `Host` header value or the host part of an `Origin`) names a
    /// loopback address. Accepts an optional `:port` suffix and bracketed IPv6 literals.
    /// Examples that pass: `127.0.0.1`, `127.0.0.1:5765`, `localhost`, `localhost:5765`,
    /// `[::1]`, `[::1]:5765`. Anything else (a rebound `evil.com`, a LAN IP) fails closed.
    static func isLoopbackHost(_ host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.isEmpty { return false }

        // Bracketed IPv6 literal: [::1] or [::1]:port
        if h.hasPrefix("[") {
            guard let close = h.firstIndex(of: "]") else { return false }
            let inner = String(h[h.index(after: h.startIndex)..<close])
            return inner == "::1" || inner == "0:0:0:0:0:0:0:1"
        }

        // Strip a trailing :port (only one colon — bare IPv6 without brackets is invalid in Host).
        if let colon = h.lastIndex(of: ":"), h.firstIndex(of: ":") == colon {
            h = String(h[h.startIndex..<colon])
        }

        return h == "127.0.0.1" || h == "localhost" || h == "::1"
        // Note: 127.0.0.0/8 is all loopback, but browsers/clients use 127.0.0.1; keep the
        // allowlist tight rather than parsing the whole /8.
    }

    /// True if `origin` (a full `Origin` header value, e.g. `http://127.0.0.1:5765`) is a
    /// loopback origin. Used to decide whether to reflect it in `Access-Control-Allow-Origin`.
    static func isLoopbackOrigin(_ origin: String) -> Bool {
        let o = origin.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: o), let host = url.host else { return false }
        // Reconstruct host[:port] the way isLoopbackHost expects (bracket IPv6 if needed).
        return isLoopbackHost(host.contains(":") ? "[\(host)]" : host)
    }

    /// Extract the value of the first header line matching `name:` (case-insensitive).
    static func headerValue(_ name: String, in lines: [String]) -> String? {
        let prefix = name.lowercased() + ":"
        for line in lines where line.lowercased().hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        // PRIMARY loopback control: reject non-loopback remotes before reading bytes.
        if !Self.isLoopback(conn.endpoint) {
            print("LocalAPI: rejected non-loopback connection from \(conn.endpoint)")
            conn.cancel()
            return
        }

        // Concurrent-connection cap (audit AR-1): reject before allocating any read buffer so a
        // flood of stalled connections can't each pin up to 32 MB. We reserve a slot atomically;
        // if the cap is hit, drop immediately.
        guard reserveConnectionSlot() else {
            print("LocalAPI: connection cap (\(Self.maxConcurrentConnections)) reached — dropping")
            conn.cancel()
            return
        }

        // Per-connection idle timeout: cancel if no progress within idleTimeout.
        // The idle timer is rescheduled on every received byte (see accumulate).
        let idleTimer = DispatchSource.makeTimerSource(queue: requestQueue)
        idleTimer.schedule(deadline: .now() + Self.idleTimeout)
        idleTimer.setEventHandler { [weak conn] in
            conn?.cancel()
        }
        idleTimer.resume()

        // Absolute lifetime cap (audit M2): cancel regardless of activity after the lifetime limit.
        // A slow-dripping attacker can keep rescheduling the idle timer but cannot extend this one,
        // so a connection that trickles bytes forever still gets cut.
        // Production uses maxConnectionLifetime (120 s); tests can shorten via connectionLifetimeOverride.
        let lifetime = connectionLifetimeOverride ?? Self.maxConnectionLifetime
        let lifetimeTimer = DispatchSource.makeTimerSource(queue: requestQueue)
        lifetimeTimer.schedule(deadline: .now() + lifetime)
        lifetimeTimer.setEventHandler { [weak conn] in
            DiagnosticLogger.shared.log("LocalAPI: connection lifetime cap (\(lifetime)s) reached — cancelling")
            conn?.cancel()
        }
        lifetimeTimer.resume()

        // Single state handler: release the slot AND cancel both timers when the connection ends.
        var slotReleased = false
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                idleTimer.cancel()
                lifetimeTimer.cancel()
                if !slotReleased {
                    slotReleased = true
                    self?.releaseConnectionSlot()
                }
            default:
                break
            }
        }

        conn.start(queue: requestQueue)
        accumulate(conn, data: Data(), idleTimer: idleTimer)
    }

    /// Atomically reserve a connection slot. Returns false if the cap is already reached.
    private func reserveConnectionSlot() -> Bool {
        connectionCountLock.lock()
        defer { connectionCountLock.unlock() }
        if activeConnections >= Self.maxConcurrentConnections { return false }
        activeConnections += 1
        return true
    }

    /// Release a previously-reserved connection slot.
    private func releaseConnectionSlot() {
        connectionCountLock.lock()
        defer { connectionCountLock.unlock() }
        if activeConnections > 0 { activeConnections -= 1 }
    }

    /// Current active-connection count (test/observability helper).
    var currentActiveConnections: Int {
        connectionCountLock.lock()
        defer { connectionCountLock.unlock() }
        return activeConnections
    }

    private func accumulate(_ conn: NWConnection, data: Data, idleTimer: DispatchSourceTimer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, error in
            guard let self = self else { idleTimer.cancel(); return }
            if error != nil { idleTimer.cancel(); conn.cancel(); return }

            // Bytes arrived — push the idle deadline forward.
            idleTimer.schedule(deadline: .now() + Self.idleTimeout)

            var buf = data
            if let chunk = chunk { buf.append(chunk) }

            if buf.count > Self.maxBodyBytes {
                idleTimer.cancel()
                self.send(conn, status: 413, body: #"{"error":"Request too large"}"#); return
            }

            guard let headerRange = self.findHeaderEnd(buf) else {
                if isComplete { idleTimer.cancel(); conn.cancel(); return }
                self.accumulate(conn, data: buf, idleTimer: idleTimer); return
            }

            let headerData = buf[buf.startIndex..<headerRange.lowerBound]
            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                idleTimer.cancel()
                self.send(conn, status: 400, body: #"{"error":"Bad headers"}"#); return
            }

            let bodyStart = headerRange.upperBound

            // Parse Content-Length DEFENSIVELY before any body arithmetic. A negative or
            // garbage value (e.g. "Content-Length: -1") would otherwise flow into the body
            // slice as an inverted Range and crash the whole process — reachable by a single
            // unauthenticated loopback request, before evaluate()'s Host/token gates run.
            let contentLength: Int
            switch Self.parseContentLength(headers: headerStr) {
            case .invalid:
                idleTimer.cancel()
                self.send(conn, status: 400, body: #"{"error":"Invalid Content-Length"}"#); return
            case .absent:
                contentLength = 0
            case .valid(let n):
                contentLength = n
            }

            // Reject oversize declared bodies up front (don't accumulate to OOM).
            if contentLength > Self.maxBodyBytes {
                idleTimer.cancel()
                self.send(conn, status: 413, body: #"{"error":"Request too large"}"#); return
            }

            let bodyAvailable = buf.endIndex - bodyStart

            if bodyAvailable < contentLength {
                if isComplete { idleTimer.cancel(); conn.cancel(); return }
                self.accumulate(conn, data: buf, idleTimer: idleTimer); return
            }

            idleTimer.cancel()
            let body = Data(buf[bodyStart..<(bodyStart + contentLength)])
            self.handle(conn: conn, headers: headerStr, body: body)
        }
    }

    // MARK: - Request dispatch (pure decision split out for testing)

    /// What the server should do with a parsed request. Pure, side-effect-free
    /// so it can be unit-tested without a live socket.
    enum RequestOutcome: Equatable {
        case respond(status: Int, body: String, contentType: String)
        case transcribe(fileData: Data, format: String)
    }

    /// Decide the outcome of a request from its already-parsed header string and body.
    /// `authToken` nil => no auth required; non-nil => require matching bearer token.
    static func evaluate(headers: String, body: Data, authToken: String?) -> RequestOutcome {
        let lines = headers.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .respond(status: 400, body: #"{"error":"Bad request"}"#, contentType: "application/json")
        }
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.first?.uppercased() ?? ""
        let path = parts.count >= 2 ? parts[1] : ""

        // DNS-rebinding defense (audit AR-1): the TCP peer being loopback is NOT sufficient —
        // a page on evil.com rebound to 127.0.0.1 connects over loopback but sends
        // `Host: evil.com`. Require a loopback Host before any handler (including the OPTIONS
        // preflight, so a rebound origin can never coax CORS headers out of us).
        let hostHeader = headerValue("Host", in: lines) ?? ""
        if !isLoopbackHost(hostHeader) {
            return .respond(status: 421,
                            body: #"{"error":"Misdirected request: Host must be loopback"}"#,
                            contentType: "application/json")
        }

        if method == "OPTIONS" {
            return .respond(status: 204, body: "", contentType: "application/json")
        }

        // Auth gate (applies to all non-preflight requests when a token is configured).
        if let token = authToken {
            if !bearerTokenMatches(headers: lines, expected: token) {
                return .respond(status: 401,
                                body: #"{"error":"Unauthorized"}"#,
                                contentType: "application/json")
            }
        }

        guard method == "POST", path.hasPrefix("/v1/audio/transcriptions") else {
            return .respond(status: 404,
                            body: #"{"error":"POST /v1/audio/transcriptions"}"#,
                            contentType: "application/json")
        }

        var contentTypeLine = ""
        for line in lines where line.lowercased().hasPrefix("content-type:") {
            contentTypeLine = line; break
        }

        guard let boundary = extractBoundary(from: contentTypeLine) else {
            return .respond(status: 400,
                            body: #"{"error":"Expected multipart/form-data"}"#,
                            contentType: "application/json")
        }

        let fields = parseMultipart(body: body, boundary: boundary)

        guard let fileData = fields["file"], !fileData.isEmpty else {
            return .respond(status: 400,
                            body: #"{"error":"Missing 'file' field"}"#,
                            contentType: "application/json")
        }

        let responseFormat = fields["response_format"].flatMap { String(data: $0, encoding: .utf8) } ?? "json"
        return .transcribe(fileData: fileData, format: responseFormat)
    }

    /// Case-insensitive `Authorization: Bearer <token>` match.
    static func bearerTokenMatches(headers lines: [String], expected: String) -> Bool {
        for line in lines where line.lowercased().hasPrefix("authorization:") {
            let value = line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
            // Expect "Bearer <token>" (scheme case-insensitive).
            let comps = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard comps.count == 2, comps[0].lowercased() == "bearer" else { return false }
            let presented = String(comps[1]).trimmingCharacters(in: .whitespaces)
            return constantTimeEquals(presented, expected)
        }
        return false
    }

    /// Length-then-constant-time string comparison to avoid token timing leaks.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        if ab.count != bb.count { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    private func handle(conn: NWConnection, headers: String, body: Data) {
        // Decide the CORS reflection target for this request (audit AR-1). Only when the
        // browser opt-in is on AND the request carries a *loopback* Origin do we echo it back;
        // any other origin (a rebound evil.com) gets no Access-Control-Allow-Origin, so the
        // browser's same-origin policy blocks it from reading the response.
        let allowedOrigin = corsOrigin(forHeaders: headers)

        switch Self.evaluate(headers: headers, body: body, authToken: authToken) {
        case .respond(let status, let respBody, let ct):
            send(conn, status: status, body: respBody, contentType: ct, allowOrigin: allowedOrigin)
        case .transcribe(let fileData, let format):
            transcribeData(fileData, format: format, conn: conn, allowOrigin: allowedOrigin)
        }
    }

    /// The value to put in `Access-Control-Allow-Origin`, or nil to emit no CORS headers.
    /// nil unless `allowBrowser` is on and the request's `Origin` is itself loopback.
    private func corsOrigin(forHeaders headers: String) -> String? {
        guard allowBrowser else { return nil }
        let lines = headers.components(separatedBy: "\r\n")
        guard let origin = Self.headerValue("Origin", in: lines), !origin.isEmpty else {
            // No Origin header => not a CORS request (e.g. curl, native client). No CORS needed.
            return nil
        }
        return Self.isLoopbackOrigin(origin) ? origin : nil
    }

    // MARK: - Transcription

    private func transcribeData(_ fileData: Data, format: String, conn: NWConnection, allowOrigin: String?) {
        guard let transcriber = transcriber else {
            send(conn, status: 503, body: #"{"error":"Transcription engine not ready"}"#,
                 allowOrigin: allowOrigin); return
        }

        let tmpDir = Config.configDir.appendingPathComponent("tmp/api")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpFile = tmpDir.appendingPathComponent("\(UUID().uuidString).audio")

        do { try fileData.write(to: tmpFile) } catch {
            send(conn, status: 500, body: #"{"error":"Failed to write temp file"}"#,
                 allowOrigin: allowOrigin); return
        }

        Task {
            defer { try? FileManager.default.removeItem(at: tmpFile) }
            do {
                let samples = try Self.decodePCM(from: tmpFile)
                let text = try await transcriber.transcribe(audioURL: tmpFile, samples: samples)
                let body: String
                switch format {
                case "text":
                    body = text
                default:
                    body = #"{"text":"\#(Self.jsonEscape(text))"}"#
                }
                let ct = format == "text" ? "text/plain" : "application/json"
                self.send(conn, status: 200, body: body, contentType: ct, allowOrigin: allowOrigin)
            } catch {
                self.send(conn, status: 500,
                          body: #"{"error":"\#(Self.jsonEscape(error.localizedDescription))"}"#,
                          allowOrigin: allowOrigin)
            }
        }
    }

    // MARK: - Audio decoding

    static func decodePCM(from url: URL) throws -> [Float] {
        let targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1, interleaved: false)!
        let srcFile = try AVAudioFile(forReading: url)
        let srcFmt = srcFile.processingFormat
        let srcFrames = AVAudioFrameCount(srcFile.length)

        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: srcFrames) else {
            throw LocalAPIError.audioDecodeFailed
        }
        try srcFile.read(into: srcBuf)

        guard let converter = AVAudioConverter(from: srcFmt, to: targetFmt) else {
            throw LocalAPIError.audioDecodeFailed
        }

        let ratio = targetFmt.sampleRate / srcFmt.sampleRate
        let outCapacity = AVAudioFrameCount(Double(srcFrames) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outCapacity) else {
            throw LocalAPIError.audioDecodeFailed
        }

        var fed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return srcBuf
        }
        if let e = convErr { throw e }

        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: n))
    }

    // MARK: - HTTP parsing

    private func findHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
    }

    /// Result of parsing the Content-Length header.
    ///
    /// The distinction matters for safety: a *present but invalid* value (negative,
    /// non-numeric, overflowing) must be rejected with 400 BEFORE any buffer arithmetic,
    /// because a negative length silently produces an inverted `Range` at the body slice
    /// (`buf[bodyStart..<(bodyStart + (-1))]`) which traps and kills the whole process —
    /// reachable by a single unauthenticated loopback request, before evaluate() runs.
    enum ContentLengthParse: Equatable {
        case absent              // header not present → treat body as 0 bytes
        case valid(Int)          // a valid, non-negative integer (caller still oversize-checks)
        case invalid             // present but garbage / negative / overflow → 400
    }

    /// Parse the Content-Length header defensively.
    ///
    /// Accepts ONLY a plain, non-negative base-10 integer (optionally surrounded by
    /// whitespace). Rejects: negatives ("-1"), non-numeric ("abc", ""), explicit-sign
    /// forms ("+5"), and anything that overflows `Int`. Static + pure so it is unit-testable
    /// without a socket.
    static func parseContentLength(headers: String) -> ContentLengthParse {
        for line in headers.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let raw = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            // Require at least one digit and ONLY digits (no sign, no separators, no whitespace
            // inside). This rejects "-1", "+5", "1 2", "0x10", "", and "abc" up front.
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return .invalid
            }
            // `Int(_:)` returns nil on overflow even for an all-digit string.
            guard let value = Int(raw), value >= 0 else { return .invalid }
            return .valid(value)
        }
        return .absent
    }

    static func extractBoundary(from line: String) -> String? {
        for part in line.components(separatedBy: ";") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("boundary=") {
                return String(t.dropFirst("boundary=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    // MARK: - Multipart parser

    static func parseMultipart(body: Data, boundary: String) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let delimData = ("--" + boundary).data(using: .utf8),
              let crlf2 = "\r\n\r\n".data(using: .utf8) else { return result }

        var search = body.startIndex..<body.endIndex

        while let delimRange = body.range(of: delimData, in: search) {
            let afterDelim = delimRange.upperBound

            // Terminal boundary: ends with "--"
            if afterDelim + 2 <= body.endIndex,
               body[afterDelim..<(afterDelim + 2)] == Data([0x2D, 0x2D]) { break }

            guard afterDelim + 2 <= body.endIndex else { break }
            let hdrStart = afterDelim + 2  // skip \r\n after boundary line

            guard let hdrEndRange = body.range(of: crlf2, in: hdrStart..<body.endIndex) else { break }
            guard let hdrStr = String(data: body[hdrStart..<hdrEndRange.lowerBound], encoding: .utf8),
                  let name = extractFieldName(from: hdrStr) else {
                search = delimRange.upperBound..<body.endIndex; continue
            }

            let partBodyStart = hdrEndRange.upperBound

            if let nextDelim = body.range(of: delimData, in: partBodyStart..<body.endIndex) {
                let end = nextDelim.lowerBound - 2  // strip trailing \r\n before next boundary
                result[name] = end > partBodyStart ? Data(body[partBodyStart..<end]) : Data()
                search = nextDelim.lowerBound..<body.endIndex
            } else {
                result[name] = Data(body[partBodyStart...])
                break
            }
        }

        return result
    }

    static func extractFieldName(from headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            guard line.lowercased().contains("content-disposition:") else { continue }
            for part in line.components(separatedBy: ";") {
                let t = part.trimmingCharacters(in: .whitespaces)
                if t.lowercased().hasPrefix("name=") {
                    return String(t.dropFirst("name=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        return nil
    }

    // MARK: - HTTP response

    private func send(_ conn: NWConnection, status: Int, body: String,
                      contentType: String = "application/json", allowOrigin: String? = nil) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 421: statusText = "Misdirected Request"
        case 429: statusText = "Too Many Requests"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default:  statusText = "Unknown"
        }
        var headerLines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType); charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close"
        ]
        // CORS (audit AR-1): never a wildcard. `allowOrigin` is non-nil only when the browser
        // opt-in is on AND the request's Origin was itself a loopback origin (validated in
        // corsOrigin(forHeaders:)). We reflect exactly that origin and send Vary: Origin so
        // intermediaries don't cache the response under the wrong origin. A cross-origin page
        // (rebound evil.com) gets no ACAO header and therefore cannot read the response.
        if let origin = allowOrigin {
            headerLines.append("Access-Control-Allow-Origin: \(origin)")
            headerLines.append("Vary: Origin")
            headerLines.append("Access-Control-Allow-Methods: POST, OPTIONS")
            headerLines.append("Access-Control-Allow-Headers: Content-Type, Authorization")
        }
        if status == 401 {
            headerLines.append("WWW-Authenticate: Bearer")
        }
        headerLines.append("")
        headerLines.append("")
        let header = headerLines.joined(separator: "\r\n")

        var response = header.data(using: .utf8)!
        response.append(bodyData)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}

enum LocalAPIError: LocalizedError {
    case audioDecodeFailed
    var errorDescription: String? { "Failed to decode audio to PCM samples" }
}
