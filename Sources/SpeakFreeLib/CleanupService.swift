// ai-processed:unverified · session:unknown · 2026-09-17
import Foundation

/// Runs the background LLM cleanup for an edit segment: hands the RAW pre-pipeline transcript plus
/// the pipeline reference text to a CONFINED `claude` subprocess and parses back span edits (C6).
///
/// Everything about the subprocess is hostile-input hardened, because the transcript is untrusted
/// (a dictation could say anything, including text engineered to steer the model — prompt
/// injection). The span applier's unique-exact-match rule is the last line of defense; this service
/// is the first: the CLI is resolved to an absolute path (never found via PATH), launched in an
/// empty scratch CWD with a minimal explicit environment, with every customization surface
/// (CLAUDE.md, skills, plugins, hooks, MCP servers, custom agents) disabled and every built-in tool
/// removed, so the worst a malicious transcript can do is make the model emit bad JSON — which the
/// parser rejects.
public final class CleanupService {

    /// Selectable cleanup model. Default is Sonnet 5 (ab/SUMMARY.md: quality near-tie with Opus at
    /// n=12, same wall-clock, ~half the credit burn; Haiku is slower AND no better via the CLI).
    public enum Model: String, Codable, Equatable, CaseIterable {
        case sonnet
        case opus
        case haiku

        /// Full model IDs (DESIGN.md decision 3 / PLAN item 4).
        public var modelID: String {
            switch self {
            case .sonnet: return "claude-sonnet-5"
            case .opus:   return "claude-opus-5"
            case .haiku:  return "claude-haiku-4-5-20251001"
            }
        }
    }

    public enum CleanupError: Error, Equatable {
        case executableNotFound       // no `claude` at the override or any known location
        case preflightFailed(String)  // `--version` did not succeed from the sanitized environment
        case launchFailed(String)     // Process.run() threw
        case timedOut                 // both the call and its one retry exceeded the timeout
        case outputTooLarge           // stdout exceeded the byte cap (runaway / non-conforming output)
        case badOutput(SpanEditParseError)  // stdout was not the contracted JSON array
    }

    // MARK: - Confinement flags (RECORDED per PLAN item 4)
    //
    // Installed CLI inspected 2026-08-28: `claude --version` → 2.1.247 (Claude Code).
    // Chosen invocation (verified accepted + clean stdout against the real CLI on 2026-08-28):
    //
    //   claude --print --safe-mode --no-session-persistence --tools "" \
    //          --model <id> --output-format text
    //
    // Flag by flag, and why each:
    //   --print                    non-interactive: print the answer and exit (required for a subprocess).
    //   --safe-mode                disables ALL customization at once — CLAUDE.md, skills, plugins,
    //                              hooks, MCP servers, custom commands/agents, output styles,
    //                              workflows, themes, keybindings — while auth, model selection, and
    //                              permissions keep working NORMALLY. This is the hooks/MCP/skills
    //                              kill-switch C6 asks for.
    //   --tools ""                 removes every built-in tool (Bash/Read/Edit/…). --safe-mode keeps
    //                              built-in tools working, so this is what actually prevents the
    //                              model from touching the scratch CWD or the filesystem: with no
    //                              tools it can only emit text.
    //   --no-session-persistence   nothing is written to ~/.claude session storage (only works with
    //                              --print). Keeps the confined call from leaving a resumable trace.
    //   --output-format text       stdout is the raw model answer (we parse the JSON array ourselves);
    //                              no envelope, no decoration.
    //   --model <id>               pins the arm.
    //
    // Deliberately NOT used:
    //   --bare  — would be the strongest confinement, but it forces auth to ANTHROPIC_API_KEY /
    //             apiKeyHelper ONLY ("OAuth and keychain are never read"), which breaks Michael's
    //             subscription auth AND would violate the estate no-API-key rule. --safe-mode gives
    //             the same customization kill without touching auth, so it is the right tool here.
    static let baseFlags = ["--print", "--safe-mode", "--no-session-persistence",
                            "--tools", "", "--output-format", "text"]

    /// Known absolute locations, tried in order after the settings override. We NEVER shell out to
    /// resolve PATH: a PATH lookup would inherit whatever the user's shell rc puts first, which is
    /// exactly the injection surface we are closing.
    public static let knownLocations: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }()

    private let configuredExecutablePath: String?
    private let candidateLocations: [String]
    private let timeout: TimeInterval
    private let maxOutputBytes: Int
    /// Preflight `--version` runs once per service instance (once per launch in production, where the
    /// EditSessionController owns one instance). nil = not yet run; true/false = result.
    private var preflightPassed: Bool?
    private let preflightLock = NSLock()

    /// - Parameters:
    ///   - configuredExecutablePath: settings override (highest precedence); tests point this at the
    ///     fake-claude fixture.
    ///   - timeout: per-attempt wall-clock cap. 25s (PLAN item 4). ab/SUMMARY: sonnet p90 8.9s but
    ///     rare 60–70s stalls exist, so a bounded timeout + one retry is mandatory and cleanup must
    ///     never block the UI or a commit.
    public init(configuredExecutablePath: String? = nil,
                candidateLocations: [String] = CleanupService.knownLocations,
                timeout: TimeInterval = 25,
                maxOutputBytes: Int = 64 * 1024) {
        self.configuredExecutablePath = configuredExecutablePath
        self.candidateLocations = candidateLocations
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    // MARK: - Executable resolution

    /// Resolve the `claude` executable: settings override → known absolute locations. Pure and
    /// injectable so the precedence is unit-testable.
    static func resolveExecutable(configuredPath: String?,
                                  candidates: [String],
                                  fileExists: (String) -> Bool) -> String? {
        if let p = configuredPath, !p.isEmpty, fileExists(p) { return p }
        return candidates.first(where: fileExists)
    }

    private func resolvedExecutable() -> String? {
        Self.resolveExecutable(configuredPath: configuredExecutablePath,
                               candidates: candidateLocations,
                               fileExists: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // MARK: - Environment

    /// The minimal explicit environment for the subprocess (PLAN item 4): HOME (so the CLI can reach
    /// its OAuth credentials at ~/.claude/.credentials.json), PATH pinned to the executable's own
    /// directory (no inherited PATH), TERM=dumb (non-interactive). Nothing else is inherited — no
    /// ANTHROPIC_API_KEY, no shell rc exports, no XDG overrides.
    ///
    /// OPEN — Phase 2 live-preflight (M9/M25): a probe on 2026-08-28 showed the real CLI reporting
    /// "Not logged in" when launched under exactly this stripped env, while it authed under a full
    /// env. That probe ran INSIDE a Claude Code session, so the full-env success was likely
    /// piggybacking on the parent session's auth relay (CLAUDE_CODE_MESSAGING_SOCKET), which the
    /// standalone speakfree process will NOT have — so the result is inconclusive, not proof either
    /// way. The Phase-1 preflight here only runs `--version`, which does NOT exercise auth. Phase 2's
    /// app-level preflight MUST make a trivial REAL call from the actual (non-Claude-Code) process
    /// and, if it 401s, widen this env to whatever the credential read needs. Do not assume this env
    /// authenticates until that check passes from the app.
    static func sanitizedEnvironment(executablePath: String, home: String) -> [String: String] {
        [
            "HOME": home,
            "PATH": (executablePath as NSString).deletingLastPathComponent,
            "TERM": "dumb",
        ]
    }

    // MARK: - Prompt

    /// The hardened single system-style prompt (failure modes are the observed A/B misses,
    /// ab/SUMMARY.md). Static + pure so a test can assert every hardening line is present — the
    /// prompt contract is load-bearing and must not drift silently.
    static func buildPrompt(raw: String, pipelineText: String) -> String {
        """
        You are a transcription REPAIR tool. You are given the RAW speech-to-text output and a \
        cleaned PIPELINE version of one short dictation segment. Return ONLY corrections, as span \
        edits, so obvious mistranscriptions are fixed without rewriting the person's words.

        Output ONLY a JSON array. No prose, no explanation, no markdown code fences. Each element is \
        an object with exactly these keys: "find" (exact substring of the PIPELINE text to replace), \
        "replace" (the corrected text), "reason" (a short phrase). If nothing needs fixing, output [].

        Rules:
        - REPAIR ONLY. Never rewrite, rephrase, summarize, or add content. The edits are corrections, \
        not an improved draft.
        - Keep any unfinished trailing fragment VERBATIM. Do not complete or trim a sentence the \
        speaker left hanging.
        - NEVER add words or punctuation that the raw speech does not support. Do not invent \
        specifics, names, or numbers.
        - ALWAYS attempt to repair a garbled spoken-punctuation command: a spoken "comma" that came \
        through as Kama / Gamma / comment should become "," ; a spoken "period" that came through as \
        "paired" should become "." ; a spoken "colon" that came through as "column" should become ":" \
        — only when the context makes the punctuation intent clear.
        - "find" MUST be an exact, unique substring of the PIPELINE text. If a correction cannot be \
        anchored uniquely, omit it.
        - "replace" MUST NOT contain newlines.

        RAW:
        \(raw)

        PIPELINE:
        \(pipelineText)
        """
    }

    // MARK: - Public entry point

    /// Clean up one segment. Never throws — returns a Result so the caller (the reducer) can settle
    /// a segment to `.failed` and offer retry without unwinding. Runs the confined subprocess with a
    /// bounded timeout and exactly one retry; on success parses stdout into span edits.
    public func cleanup(raw: String, pipelineText: String, model: Model) async
        -> Result<[SpanEdit], CleanupError>
    {
        guard let exe = resolvedExecutable() else {
            return .failure(.executableNotFound)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = Self.sanitizedEnvironment(executablePath: exe, home: home)

        // Preflight `--version` once per instance, from the SAME sanitized environment the real
        // call uses — an env too minimal to launch the CLI fails here, loudly, instead of silently
        // failing every segment (M7/C6).
        if let error = await preflightIfNeeded(exe: exe, env: env) {
            return .failure(error)
        }

        let prompt = Self.buildPrompt(raw: raw, pipelineText: pipelineText)
        let args = Self.baseFlags + ["--model", model.modelID]

        // Fresh empty scratch CWD per call so the CLI cannot auto-discover anything in a real project
        // directory (belt-and-suspenders with --safe-mode's CLAUDE.md kill).
        let cwd = Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: cwd) }

        // Attempt + one retry on timeout only (a bad-output or launch error will not fix itself).
        for attempt in 0..<2 {
            let outcome = await runOnce(exe: exe, args: args, env: env, cwd: cwd,
                                        stdin: prompt, timeout: timeout)
            switch outcome {
            case .completed(let data):
                // Preserve replacement characters for malformed subprocess UTF-8 before parsing.
                // swiftlint:disable:next optional_data_string_conversion
                switch SpanEditParser.parse(String(decoding: data, as: UTF8.self)) {
                case .parsed(let edits):
                    return .success(edits)
                case .rejected(let err):
                    return .failure(.badOutput(err))
                }
            case .outputTooLarge:
                return .failure(.outputTooLarge)
            case .launchFailed(let msg):
                return .failure(.launchFailed(msg))
            case .timedOut:
                if attempt == 0 { continue }   // one retry
                return .failure(.timedOut)
            }
        }
        return .failure(.timedOut)
    }

    private func preflightIfNeeded(exe: String, env: [String: String]) async -> CleanupError? {
        preflightLock.lock()
        let cached = preflightPassed
        preflightLock.unlock()
        if let cached = cached { return cached ? nil : .preflightFailed("cached failure") }

        let cwd = Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let outcome = await runOnce(exe: exe, args: ["--version"], env: env, cwd: cwd,
                                    stdin: nil, timeout: min(timeout, 15))
        let ok: Bool
        var error: CleanupError?
        switch outcome {
        case .completed(let data):
            // A working CLI prints a version line and exits 0; treat any non-empty stdout as pass.
            ok = !data.isEmpty
            if !ok { error = .preflightFailed("empty --version output") }
        case .timedOut:
            ok = false; error = .preflightFailed("--version timed out")
        case .launchFailed(let msg):
            ok = false; error = .preflightFailed(msg)
        case .outputTooLarge:
            ok = false; error = .preflightFailed("--version output too large")
        }
        preflightLock.lock()
        preflightPassed = ok
        preflightLock.unlock()
        return error
    }

    // MARK: - Process plumbing

    private enum RunOutcome {
        case completed(Data)
        case timedOut
        case launchFailed(String)
        case outputTooLarge
    }

    private static func makeScratchDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-cleanup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    private func runOnce(exe: String, args: [String], env: [String: String], cwd: URL,
                         stdin: String?, timeout: TimeInterval) async -> RunOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runBlocking(
                    exe: exe, args: args, env: env, cwd: cwd, stdin: stdin, timeout: timeout))
            }
        }
    }

    /// Thread-safe capped stdout collector. `availableData` reads on a background thread while the
    /// main watchdog waits on exit; the lock makes the handoff safe.
    private final class OutputCollector {
        private let lock = NSLock()
        private var data = Data()
        private var overflowed = false
        let cap: Int
        init(cap: Int) { self.cap = cap }
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if overflowed { return }
            if data.count + chunk.count > cap {
                overflowed = true
            } else {
                data.append(chunk)
            }
        }
        var snapshot: (data: Data, overflowed: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (data, overflowed)
        }
    }

    private func runBlocking(exe: String, args: [String], env: [String: String], cwd: URL,
                             stdin: String?, timeout: TimeInterval) -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }

        // Feed the prompt then close stdin so the CLI sees EOF and produces output.
        if let stdin = stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        // Drain stdout (capped) and stderr on background threads so a large/streaming output can
        // never deadlock the pipe while we wait on exit.
        let collector = OutputCollector(cap: maxOutputBytes)
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = outPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collector.append(chunk)
            }
            readDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Wait for exit with a wall-clock cap. On timeout: SIGTERM, brief grace, then SIGKILL — a
        // stalled CLI (observed 70s tails) must never hold the caller.
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
            _ = readDone.wait(timeout: .now() + 1)
            return .timedOut
        }
        _ = readDone.wait(timeout: .now() + 2)

        let (data, overflowed) = collector.snapshot
        if overflowed { return .outputTooLarge }
        return .completed(data)
    }
}
