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
        ///
        /// Checked 2026-09-24 against CLI 2.1.281: all three IDs are in its model catalog (an
        /// unknown ID makes the CLI print "isn't described by this version's model catalog";
        /// these do not). Opus moved from `claude-opus-5` to the current `claude-opus-5-5`.
        public var modelID: String {
            switch self {
            case .sonnet: return "claude-sonnet-5"
            case .opus:   return "claude-opus-5-5"
            case .haiku:  return "claude-haiku-4-5-20251001"
            }
        }

        /// The name shown in the window and Settings.
        public var displayName: String {
            switch self {
            case .sonnet: return "Sonnet"
            case .opus:   return "Opus"
            case .haiku:  return "Haiku"
            }
        }

        /// Lenient parse of a stored value; unknown or nil falls back to Sonnet, the default.
        public static func resolve(_ raw: String?) -> Model {
            guard let raw = raw?.lowercased(), let m = Model(rawValue: raw) else { return .sonnet }
            return m
        }
    }

    public enum CleanupError: Error, Equatable {
        case executableNotFound       // no `claude` at the override or any known location
        case preflightFailed(String)  // `--version` did not succeed from the sanitized environment
        case launchFailed(String)     // Process.run() threw
        case timedOut                 // both the call and its one retry exceeded the timeout
        case outputTooLarge           // stdout exceeded the byte cap (runaway / non-conforming output)
        case badOutput(SpanEditParseError)  // stdout was not the contracted JSON array
        case notLoggedIn              // the CLI answered "Not logged in"
        case usageLimit(String)       // the account hit a usage limit (message carries the reset time)
        case cliError(String)         // the CLI exited non-zero with some other message
        case cancelled                // cleanup was turned off (or the session ended) mid-call

        /// True when every further call in this session would fail the same way, so the session
        /// stops sending instead of repeating a doomed call per paragraph.
        public var isSessionWide: Bool {
            switch self {
            case .executableNotFound, .preflightFailed, .notLoggedIn, .usageLimit: return true
            default: return false
            }
        }

        /// Plain-English cause for the window (failures are visible and specific, never silent).
        public var userMessage: String {
            switch self {
            case .executableNotFound:
                return "Claude command line tool not found"
            case .preflightFailed(let why):
                return "Claude command line tool did not start (\(why))"
            case .launchFailed:
                return "Claude could not be started"
            case .timedOut:
                return "Claude timed out"
            case .outputTooLarge, .badOutput:
                return "Claude returned something that was not a list of fixes"
            case .notLoggedIn:
                return "not logged in to Claude"
            case .usageLimit(let message):
                return message.isEmpty ? "Claude usage limit reached" : message
            case .cliError(let message):
                return message.isEmpty ? "Claude reported an error" : "Claude: \(message)"
            case .cancelled:
                return "cleanup was turned off"
            }
        }

        /// Classify a non-zero CLI exit from its stdout (the CLI prints errors on stdout, exit 1;
        /// observed 2026-09-24 on CLI 2.1.281).
        static func classifyFailure(stdout: String) -> CleanupError {
            let line = stdout.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let lower = line.lowercased()
            if lower.contains("not logged in") || lower.contains("/login") { return .notLoggedIn }
            if lower.contains("limit") { return .usageLimit(String(line.prefix(120))) }
            return .cliError(String(line.prefix(120)))
        }
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
    //             apiKeyHelper ONLY ("OAuth and keychain are never read"), which breaks the maintainer's
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
    /// RESOLVED 2026-09-24 (CLI 2.1.281, run with `env -i` so nothing leaked from a parent
    /// session): with only HOME/PATH/TERM the CLI answers "Not logged in". It reads the
    /// subscription credential from the login Keychain through `/usr/bin/security`, keyed by the
    /// account name, so it also needs USER and LOGNAME and `/usr/bin:/bin` on PATH. With those five
    /// variables it gave an authenticated answer. Still nothing else is inherited: no API key, no shell rc exports, no
    /// CLAUDE_CONFIG_DIR, no proxy settings.
    static func sanitizedEnvironment(executablePath: String, home: String,
                                     user: String = NSUserName()) -> [String: String] {
        [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": (executablePath as NSString).deletingLastPathComponent + ":/usr/bin:/bin",
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
        - SELF-CORRECTIONS ARE THE ONE EXCEPTION to "repair only": when the speaker obviously \
        corrected themselves, delete the false start and the correction marker ("no wait", \
        "I mean", "sorry", "actually") and keep only the correction. Example: PIPELINE "Meet \
        Tuesday no wait Wednesday." gives [{"find": "Tuesday no wait Wednesday", "replace": \
        "Wednesday", "reason": "self-correction"}]. Adding commas around the marker is wrong; it \
        keeps the false start.
        - NEVER change the meaning: never add or remove a negation (not, never, no, don't) except \
        the "no" inside an obvious self-correction.
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
    public func cleanup(raw: String, pipelineText: String, model: Model,
                        cancellation: CleanupCancellation = CleanupCancellation()) async
        -> Result<[SpanEdit], CleanupError>
    {
        // Cloud-off is immediate: a cancelled request never launches anything,
        // not even the local `--version` preflight.
        if cancellation.isCancelled { return .failure(.cancelled) }
        guard let exe = resolvedExecutable() else {
            return .failure(.executableNotFound)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = Self.sanitizedEnvironment(executablePath: exe, home: home)

        // Preflight `--version` once per instance, from the SAME sanitized environment the real
        // call uses — an env too minimal to launch the CLI fails here, loudly, instead of silently
        // failing every segment (M7/C6). It is local: `--version` makes no network call.
        if let error = await preflightIfNeeded(exe: exe, env: env) {
            return .failure(error)
        }
        if cancellation.isCancelled { return .failure(.cancelled) }

        let prompt = Self.buildPrompt(raw: raw, pipelineText: pipelineText)
        let args = Self.baseFlags + ["--model", model.modelID]

        // Fresh empty scratch CWD per call so the CLI cannot auto-discover anything in a real project
        // directory (belt-and-suspenders with --safe-mode's CLAUDE.md kill).
        let cwd = Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: cwd) }

        // Attempt + one retry on timeout only (a bad-output or launch error will not fix itself).
        for attempt in 0..<2 {
            // No retry after cloud-off: the check sits before every launch.
            if cancellation.isCancelled { return .failure(.cancelled) }
            let outcome = await runOnce(exe: exe, args: args, env: env, cwd: cwd,
                                        stdin: prompt, timeout: timeout, cancellation: cancellation)
            if cancellation.isCancelled { return .failure(.cancelled) }
            switch outcome {
            case .failedExit(let data):
                // swiftlint:disable:next optional_data_string_conversion
                return .failure(CleanupError.classifyFailure(stdout: String(decoding: data, as: UTF8.self)))
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
        // Only success is cached: a CLI installed or repaired after a failure is picked up on the
        // next call instead of staying "failed" for the rest of the launch.
        if cached == true { return nil }

        let cwd = Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let outcome = await runOnce(exe: exe, args: ["--version"], env: env, cwd: cwd,
                                    stdin: nil, timeout: min(timeout, 15),
                                    cancellation: CleanupCancellation())
        let ok: Bool
        var error: CleanupError?
        switch outcome {
        case .failedExit:
            ok = false; error = .preflightFailed("--version failed")
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
        case failedExit(Data)   // non-zero exit; stdout carries the CLI's message
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
                         stdin: String?, timeout: TimeInterval,
                         cancellation: CleanupCancellation) async -> RunOutcome {
        // A dedicated thread, not the global pool (2026-09-23): runBlocking parks for the whole
        // call, and a saturated width-limited pool delayed it past the timeout (the flaky
        // "--version timed out" under load).
        await withCheckedContinuation { continuation in
            Self.runOnDedicatedThread {
                continuation.resume(returning: self.runBlocking(
                    exe: exe, args: args, env: env, cwd: cwd, stdin: stdin, timeout: timeout,
                    cancellation: cancellation))
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

    private static func runOnDedicatedThread(_ work: @escaping () -> Void) {
        let thread = Thread(block: work)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func runBlocking(exe: String, args: [String], env: [String: String], cwd: URL,
                             stdin: String?, timeout: TimeInterval,
                             cancellation: CleanupCancellation) -> RunOutcome {
        let process = Process()
        // Exit arrives via Foundation's own process monitor, never a pool thread parked in
        // waitUntilExit. Set before run() so an instant exit cannot be missed.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
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
        // Cloud-off mid-call: SIGTERM now, SIGKILL if it is still running half a second later.
        // `isRunning` (not a second wait on `exited`) decides the KILL, so a pid that already
        // exited and was reused is never signalled.
        cancellation.onCancel {
            guard process.isRunning else { return }
            process.terminate()
            Self.runOnDedicatedThread {
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
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
        Self.runOnDedicatedThread {
            let handle = outPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collector.append(chunk)
            }
            readDone.signal()
        }
        Self.runOnDedicatedThread {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Wait for exit with a wall-clock cap. On timeout: SIGTERM, brief grace, then SIGKILL — a
        // stalled CLI (observed 70s tails) must never hold the caller.
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            let pid = process.processIdentifier
            Self.runOnDedicatedThread {
                if exited.wait(timeout: .now() + 0.5) == .timedOut { kill(pid, SIGKILL) }
            }
            _ = readDone.wait(timeout: .now() + 1)
            return .timedOut
        }
        _ = readDone.wait(timeout: .now() + 2)

        let (data, overflowed) = collector.snapshot
        if overflowed { return .outputTooLarge }
        if process.terminationStatus != 0 { return .failedExit(data) }
        return .completed(data)
    }
}

/// Cancels one cleanup request: a request cancelled before launch never launches; one cancelled
/// mid-call has its process terminated and is never retried (cloud-off takes
/// effect immediately). Thread-safe; handlers registered after cancellation run at once.
public final class CleanupCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let toRun = handlers
        handlers = []
        lock.unlock()
        toRun.forEach { $0() }
    }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}
