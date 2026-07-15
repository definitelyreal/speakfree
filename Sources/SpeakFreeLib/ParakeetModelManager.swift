// Claude · 2026-06-07 · Session: 26-06-07-parakeet-impl
//
// Parakeet (FluidAudio) model acquisition + cache management.
//
// Ported from VoiceInk's FluidAudioModelManager pattern. Owns the download / cache-existence /
// load lifecycle for the Parakeet CoreML weights and hands a loaded `AsrModels` to the engine
// (Unit 4 / ParakeetEngine) to construct its `AsrManager`.
//
// Licensing attribution (required):
//   - FluidAudio SDK is Apache-2.0 (permissive; include license text + NOTICE in credits).
//   - Parakeet v3/v2 CoreML weights (FluidInference/parakeet-tdt-0.6b-*-coreml) and the upstream
//     nvidia/parakeet-tdt-0.6b-* models are CC-BY-4.0 — attribution required. Credit line, e.g.:
//     "Speech recognition powered by NVIDIA Parakeet (CC-BY-4.0) via FluidAudio (Apache-2.0)."

import Foundation
import FluidAudio

/// Manages download, cache state, and loading of FluidAudio's Parakeet ASR models.
///
/// FluidAudio owns the actual HTTP, on-disk cache, and CoreML compilation; this manager is a thin
/// speakfree-facing facade that maps speakfree model-name strings to `AsrModelVersion` and exposes
/// the small surface `ParakeetEngine` needs (existence check, ensure-downloaded with progress,
/// cache directory, and a fully-loaded `AsrModels`).
///
/// Models are cached in FluidAudio's own directory
/// (`~/Library/Application Support/FluidAudio/Models/<repo>/`), separate from speakfree's whisper
/// `.bin` store. They are download-only at first use and are never bundled.
public final class ParakeetModelManager {

    public static let shared = ParakeetModelManager()

    private init() {}

    // MARK: - FluidAudio serial gate

    /// Serializes ALL FluidAudio calls whose behavior depends on the process-global
    /// `DownloadUtils.enforceOffline` flag, behind ONE process-wide slot. `ensureDownloaded` flips
    /// `enforceOffline = false` for the duration of its deliberate fetch; because every download AND
    /// every cache load runs through this single gate, that false window can never overlap a
    /// concurrent `loadDownloadedModels` (which would otherwise silently re-download on a
    /// load/compile failure) or another version's download. There is only ONE global slot — the UI is
    /// single-select, so parallel v2/v3 acquisition is unnecessary, and a single owner of the
    /// `enforceOffline` window is the only safe design for a process-global flag.
    ///
    /// `isModelDownloaded` (pure on-disk existence, independent of `enforceOffline`) stays un-gated.
    private actor DownloadGate {
        /// Runs `op` exclusively: at most one `op` executes at a time, FIFO across awaiting callers.
        /// Implemented as an async mutex via a busy flag plus a queue of `CheckedContinuation`s, so
        /// the gate yields the actor between operations (no lock is ever held across the `await op()`).
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func run<T>(_ op: () async throws -> T) async rethrows -> T {
            await acquire()
            defer { release() }
            return try await op()
        }

        private func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            // Resumed already holding the slot (handed off by `release`); `busy` stays true.
        }

        private func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                // Hand the slot directly to the next waiter without clearing `busy`, preserving
                // mutual exclusion across the handoff.
                let next = waiters.removeFirst()
                next.resume()
            }
        }
    }

    private let downloadGate = DownloadGate()

    // MARK: - Registry host pinning (security)

    /// Guards `pinRegistryHostIfNeeded()` so the host is pinned exactly once.
    nonisolated(unsafe) private static var didPinRegistry = false
    private static let pinLock = NSLock()

    /// Pins FluidAudio's model-registry host to the canonical HuggingFace origin before the
    /// first download/load, so the network destination cannot be redirected at runtime.
    ///
    /// Defense rationale: FluidAudio's `ModelRegistry.baseURL` resolves its host from, in order,
    /// a programmatic override → the `REGISTRY_URL` env var → the `MODEL_REGISTRY_URL` env var →
    /// the default. Without a programmatic override, anyone able to set those env vars could point
    /// our model downloads at an attacker-controlled host. Combined with FluidAudio's
    /// `Authorization: Bearer <HF_TOKEN>` header (DownloadUtils reads `HF_TOKEN` /
    /// `HUGGING_FACE_HUB_TOKEN` / `HUGGINGFACEHUB_API_TOKEN` from the environment), a redirected
    /// host would receive any HuggingFace token verbatim — a token-exfiltration vector. Setting the
    /// programmatic override here makes it win the priority chain, neutralizing both the
    /// REGISTRY_URL/MODEL_REGISTRY_URL redirect and the token-exfil path.
    ///
    /// Auth note: the Parakeet v2/v3 CoreML repos are PUBLIC, so no HuggingFace token is required.
    /// FluidAudio only ingests a token from the environment (there is no programmatic API to clear
    /// or disable it on the download/load path), so we rely on the public, unauthenticated fetch:
    /// with the host pinned to huggingface.co, any stray `HF_TOKEN` in the environment is sent only
    /// to the genuine HuggingFace origin, never to a redirected host.
    private static func pinRegistryHostIfNeeded() {
        pinLock.lock()
        defer { pinLock.unlock() }
        guard !didPinRegistry else { return }
        ModelRegistry.baseURL = "https://huggingface.co"
        // Block all network access by default. FluidAudio's load/compile paths silently fall back
        // to a full ~600MB re-download (`loadFromCache` recovers via download on any load/compile
        // failure), which we never want on the transcribe path. The only sanctioned fetch is the
        // deliberate `downloadAndLoad` inside `ensureDownloaded`, which flips this off transiently
        // and restores it via `defer`. Set once here, before `didPinRegistry` flips true.
        DownloadUtils.enforceOffline = true
        didPinRegistry = true
        DiagnosticLogger.shared.log(
            "ParakeetModelManager: pinned FluidAudio registry host to https://huggingface.co; "
                + "enforceOffline = true")
    }

    // MARK: - Model name → version mapping

    /// Maps a speakfree Parakeet model-id string to FluidAudio's `AsrModelVersion`.
    ///
    /// The model-id → version-string ("v2"/"v3") mapping is owned by
    /// `EngineCatalog.versionString(forParakeetModelID:)` (single source of truth); this is the
    /// only place that converts that string into FluidAudio's enum: `"v2"` → `.v2`, else `.v3`
    /// (so v3 — multilingual — is the default for "v3" and any unknown id).
    private func version(for modelName: String) -> AsrModelVersion {
        EngineCatalog.versionString(forParakeetModelID: modelName) == "v2" ? .v2 : .v3
    }

    /// Whether `modelName` is a known Parakeet catalog id. `version(for:)` silently defaults any
    /// unknown id to a real v3 download, so a typo'd or tampered id would otherwise trigger a ~600MB
    /// fetch (or a v3 cache load) for something the catalog never advertised. Callers that touch the
    /// network/cache validate against this first and throw `modelAssetsMissing` for unknown ids.
    private func isKnownModelID(_ modelName: String) -> Bool {
        EngineCatalog.parakeetModels.contains { $0.id == modelName }
    }

    // MARK: - Cache directory

    /// FluidAudio's default cache directory for the given speakfree model name.
    public func cacheDirectory(for modelName: String) -> URL {
        AsrModels.defaultCacheDirectory(for: version(for: modelName))
    }

    // MARK: - Download state

    /// Whether the given model's weights are already present in FluidAudio's cache.
    ///
    /// Unknown ids return `false` up front: `version(for:)` silently maps any unrecognized id to
    /// `.v3`, so without this guard a typo'd/tampered id would report "downloaded" whenever the real
    /// v3 weights happen to be cached — falsely claiming an asset the catalog never advertised exists.
    /// This mirrors the `isKnownModelID` guard already enforced by `ensureDownloaded`,
    /// `downloadOnly`, and `loadDownloadedModels` (which throw `modelAssetsMissing` for unknown ids).
    public func isModelDownloaded(_ modelName: String) -> Bool {
        guard isKnownModelID(modelName) else { return false }
        return cacheIsComplete(version: version(for: modelName))
    }

    // MARK: - Cache integrity

    /// Whether the cache for `v` is not just present-by-name but actually loadable.
    ///
    /// `AsrModels.modelsExist` is existence-only: an interrupted prior download can leave every
    /// required file present *by name* while a `.mlmodelc` bundle is missing its compiled
    /// `coremldata.bin`. That passes the naive check, so onboarding/launch is skipped, yet
    /// `loadFromCache` later throws `modelAssetsMissing`, and because `enforceOffline` is held true
    /// outside `ensureDownloaded`, FluidAudio can't self-heal, leaving the user stuck with no progress
    /// UI. This adds the same `coremldata.bin` integrity check FluidAudio's own loader performs, so a
    /// partial cache is treated as "not downloaded" (re-triggering the visible download, which purges
    /// and refetches it).
    private func cacheIsComplete(version v: AsrModelVersion) -> Bool {
        let dir = AsrModels.defaultCacheDirectory(for: v)
        // Names must all be present first (also covers a wholly missing model dir).
        guard AsrModels.modelsExist(at: dir, version: v) else { return false }
        // The vocab is required to decode; FluidAudio's existence check only confirms the file
        // is present-by-name. An interrupted download can leave a 0-byte or truncated
        // parakeet_vocab.json that passes existence yet makes loadFromCache throw. Treat a
        // missing/empty/unparseable vocab as "not downloaded" so the visible download re-fetches it.
        guard Self.parakeetVocabIsValid(inDir: dir) else {
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: cache vocab missing/empty/unparseable — treating cache as incomplete")
            return false
        }
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }
        var foundModel = false
        for case let url as URL in enumerator where url.pathExtension == "mlmodelc" {
            enumerator.skipDescendants()  // don't walk the (large) compiled-weights tree
            foundModel = true
            let marker = url.appendingPathComponent("coremldata.bin")
            let size = (try? fm.attributesOfItem(atPath: marker.path))?[.size] as? NSNumber
            if (size?.intValue ?? 0) <= 0 { return false }  // present but empty/missing → corrupt
        }
        return foundModel
    }

    /// Whether `parakeet_vocab.json` in `dir` exists, is non-empty, and parses as JSON.
    /// FluidAudio's TDT models (both v2 and v3) name the vocab `parakeet_vocab.json`
    /// (`ModelNames.Parakeet.vocabularyFile`); it is small (~18 KB v2 / ~150 KB v3), so a full
    /// `JSONSerialization` parse per launch is cheap. `internal static` so it is unit-testable
    /// against a temp directory without a real FluidAudio cache.
    static func parakeetVocabIsValid(inDir dir: URL) -> Bool {
        let vocab = dir.appendingPathComponent("parakeet_vocab.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: vocab.path),
            let size = (try? fm.attributesOfItem(atPath: vocab.path))?[.size] as? NSNumber,
            size.intValue > 0,
            let data = try? Data(contentsOf: vocab),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        // P6: "parseable JSON" is too weak — `{}`, `[]`, a bare number/string, or a collection
        // whose entries aren't strings all parse yet make FluidAudio's decoder throw at load,
        // leaving the user stuck (enforceOffline blocks self-heal). Require one of the two shapes
        // FluidAudio actually parses: a non-empty array of strings, or a non-empty object of
        // string values.
        if let arr = json as? [String] { return !arr.isEmpty }
        if let dict = json as? [String: String] { return !dict.isEmpty }
        return false
    }

    /// Removes any `.mlmodelc` bundle in the cache whose compiled `coremldata.bin` is missing or
    /// empty (the corruption `cacheIsComplete` detects). FluidAudio's downloader skips files that
    /// already exist on disk, so a corrupt-but-present bundle is never refetched unless removed.
    /// Deleting *only the bad bundles* (not the whole model dir) lets FluidAudio refetch exactly
    /// those while resuming/keeping every valid or merely-missing file, so it heals a corrupt or
    /// mixed cache in a single download cycle without re-pulling the full ~600 MB.
    ///
    /// Throws on a failed removal rather than swallowing it: a silent failure would let FluidAudio
    /// re-skip the corrupt bundle and leave the user stuck, exactly the bug this closes. Only ever
    /// deletes `.mlmodelc` subdirectories of the per-model cache dir
    /// (`…/FluidAudio/Models/parakeet-tdt-0.6b-vN`), never the model dir, a sibling, or the Models root.
    @discardableResult
    private func purgeCorruptBundles(version v: AsrModelVersion) throws -> Int {
        let dir = AsrModels.defaultCacheDirectory(for: v)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
            let enumerator = fm.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }
        var corrupt: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "mlmodelc" {
            enumerator.skipDescendants()  // don't walk into the (large) compiled-weights tree
            let marker = url.appendingPathComponent("coremldata.bin")
            let size = (try? fm.attributesOfItem(atPath: marker.path))?[.size] as? NSNumber
            if (size?.intValue ?? 0) <= 0 { corrupt.append(url) }  // missing/empty → corrupt
        }
        for url in corrupt {  // remove after enumerating so we never mutate the tree mid-walk
            try fm.removeItem(at: url)
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: purged corrupt bundle \(url.lastPathComponent)")
        }
        return corrupt.count
    }

    // MARK: - Direct pre-fetch (smooth byte-accurate progress)

    /// Whether `modelName` has a direct-download plan (so the UI can show a true byte-progress bar
    /// before handing off to FluidAudio). Currently only the default English v2 model.
    public func hasDirectDownloadPlan(_ modelName: String) -> Bool {
        ParakeetDirectDownloader.plan(forModelID: modelName) != nil
    }

    /// Best-effort: pre-fetches the large model bundles directly from HuggingFace with real
    /// `(downloadedBytes, totalBytes)` progress, into FluidAudio's cache, BEFORE FluidAudio's own
    /// download. FluidAudio then skips the placed files and fetches only the small remainder +
    /// compiles. No-op for models without a plan. Errors are swallowed: FluidAudio's subsequent
    /// download fills in anything missing, so a failed pre-fetch only loses the smooth bar.
    public func prefetchLargeFiles(
        _ modelName: String,
        progress: @escaping (_ downloaded: Int64, _ total: Int64) -> Void
    ) async throws {
        guard isKnownModelID(modelName) else { return }
        let cacheDir = cacheDirectory(for: modelName)
        do {
            try await ParakeetDirectDownloader.prefetch(
                modelID: modelName, into: cacheDir, progress: progress)
        } catch is CancellationError {
            throw CancellationError()  // user paused/stopped — propagate so the flow stops
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()  // same: a cancelled URLSession download is a user pause/stop
        } catch {
            // Network/list failure is non-fatal: swallow it so FluidAudio's own download (called next)
            // fetches everything normally. We only lose the smooth progress bar, never the install.
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: direct pre-fetch failed (FluidAudio will download normally): "
                    + "\(error.localizedDescription)")
        }
    }

    // MARK: - Download

    /// Ensures the model's weights are downloaded into FluidAudio's cache, reporting progress in
    /// `[0, 1]`. No-ops (and reports `1.0`) if the model is already present.
    ///
    /// The `progress` closure may be invoked on an arbitrary queue (FluidAudio dispatches progress
    /// off-main); callers that touch UI must hop to the main actor themselves.
    public func ensureDownloaded(
        _ modelName: String,
        progress: @escaping (Double) -> Void
    ) async throws {
        // Reject unknown/typo'd/tampered ids up front: `version(for:)` would otherwise silently
        // default them to a real v3 download.
        guard isKnownModelID(modelName) else {
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: refusing to download unknown model id \(modelName)")
            throw TranscriptionEngineError.modelAssetsMissing(modelName)
        }

        // Pin the registry host before any FluidAudio network call (see pinRegistryHostIfNeeded).
        Self.pinRegistryHostIfNeeded()

        let v = version(for: modelName)

        // Completeness (not just existence) is a pure on-disk check independent of `enforceOffline`,
        // so it stays outside the gate to avoid holding the global slot for a no-op.
        if cacheIsComplete(version: v) {
            progress(1.0)
            return
        }

        // Serialize behind the single global gate so the `enforceOffline = false` window below can
        // never overlap a concurrent cache load or another download. Re-check inside the gate: a
        // download that completed while we were queued makes ours a no-op.
        try await downloadGate.run {
            if cacheIsComplete(version: v) {
                progress(1.0)
                return
            }

            // Remove any present-but-corrupt bundle (bad coremldata.bin) that FluidAudio's
            // existence-only check would otherwise skip; valid and merely-missing files are left for
            // FluidAudio to keep/resume. (We only get here with cacheIsComplete == false.)
            try purgeCorruptBundles(version: v)

            DiagnosticLogger.shared.log(
                "ParakeetModelManager: downloading \(modelName) (version \(v))")
            let start = Date()

            // FluidAudio's `@Sendable (DownloadProgress) -> Void` re-emits a per-spec 0→1 sweep for
            // every model component (download() + load() each loop the specs), so `.fractionCompleted`
            // sawtooths. Funnel it through `ProgressNormalizer` so callers get one monotonic [0, 1) ramp.
            let normalizer = ProgressNormalizer()
            let handler: DownloadUtils.ProgressHandler = { p in
                progress(normalizer.map(p))
            }

            // This is the ONLY sanctioned network fetch. Flip `enforceOffline` off for the duration
            // of the deliberate download and restore it via `defer`. The gate guarantees we are the
            // sole owner of this window, so no other FluidAudio path (e.g. a `loadFromCache`
            // recovery) can observe `enforceOffline == false` and silently hit the network.
            DownloadUtils.enforceOffline = false
            defer { DownloadUtils.enforceOffline = true }

            // `downloadAndLoad` both fetches and compiles; we discard the loaded result here since
            // callers that want the loaded models use `loadDownloadedModels(_:)`. The cache is now
            // warm so a subsequent `loadDownloadedModels` resolves from disk fast.
            _ = try await AsrModels.downloadAndLoad(version: v, progressHandler: handler)

            let elapsed = Date().timeIntervalSince(start)
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: \(modelName) downloaded + compiled in "
                    + "\(String(format: "%.1f", elapsed))s")
        }

        progress(1.0)
    }

    /// Acquires the model's files via `AsrModels.download()`, reporting a **monotonic** [0, 1)
    /// display fraction (the caller pegs 1.0 only on success). `AsrModels.download()` loops over
    /// the model's component specs and re-runs a full download→compile pass per spec, re-emitting
    /// its own 0→0.5(bytes)→1.0(CoreML compile) sweep each time; forwarding that verbatim makes a
    /// progress bar jump backward. `ProgressNormalizer` collapses that sawtooth into one
    /// never-decreasing ramp. Note `AsrModels.download()` already compiles each spec internally;
    /// `compileAndCache()` is still called afterward to load + validate from the warm cache.
    public func downloadOnly(
        _ modelName: String,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard isKnownModelID(modelName) else {
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: refusing to download unknown model id \(modelName)")
            throw TranscriptionEngineError.modelAssetsMissing(modelName)
        }
        Self.pinRegistryHostIfNeeded()
        let v = version(for: modelName)

        if cacheIsComplete(version: v) {
            return  // already downloaded and loadable
        }

        try await downloadGate.run {
            if cacheIsComplete(version: v) {
                return
            }
            // Remove any present-but-corrupt bundle (bad coremldata.bin) that FluidAudio would skip;
            // valid and merely-missing files are left for FluidAudio to keep/resume.
            try purgeCorruptBundles(version: v)
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: downloading \(modelName) via download-only API")
            let start = Date()
            let normalizer = ProgressNormalizer()
            let handler: DownloadUtils.ProgressHandler = { p in progress(normalizer.map(p)) }
            DownloadUtils.enforceOffline = false
            defer { DownloadUtils.enforceOffline = true }
            _ = try await AsrModels.download(version: v, progressHandler: handler)
            let elapsed = Date().timeIntervalSince(start)
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: \(modelName) download done in \(String(format: "%.1f", elapsed))s")
        }
    }

    /// Compiles / loads pre-downloaded model files from FluidAudio's cache.
    /// Call after `downloadOnly()` completes. Discards the loaded model — subsequent
    /// transcription calls will load from the warm cache.
    public func compileAndCache(_ modelName: String) async throws {
        DiagnosticLogger.shared.log("ParakeetModelManager: compiling \(modelName)")
        let start = Date()
        _ = try await loadDownloadedModels(modelName)
        let elapsed = Date().timeIntervalSince(start)
        DiagnosticLogger.shared.log(
            "ParakeetModelManager: \(modelName) compiled in \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Load

    /// Loads a fully constructed `AsrModels` for `modelName` STRICTLY from FluidAudio's on-disk
    /// cache. This is the transcribe-path entry point: it never downloads.
    ///
    /// If the weights are absent (or `loadFromCache` cannot construct them), throws
    /// `TranscriptionEngineError.modelAssetsMissing(modelName)` — acquisition must go through
    /// `ensureDownloaded`, the only method permitted to fetch from the network. Because
    /// `DownloadUtils.enforceOffline` is held `true` outside `ensureDownloaded`, even FluidAudio's
    /// internal `loadFromCache` re-download recovery is blocked here; it would throw rather than pull
    /// ~600MB on a load/compile failure.
    ///
    /// Hand the returned value to `AsrManager(config:)` + `loadModels(_:)` in the engine (Unit 4).
    /// `AsrModels` is a `Sendable` struct in FluidAudio 0.15.1, so it crosses the actor boundary
    /// cleanly.
    public func loadDownloadedModels(_ modelName: String) async throws -> AsrModels {
        // Reject unknown/typo'd/tampered ids up front (see `isKnownModelID`): otherwise a v3 cache
        // load would be attempted for an id the catalog never advertised.
        guard isKnownModelID(modelName) else {
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: refusing to load unknown model id \(modelName)")
            throw TranscriptionEngineError.modelAssetsMissing(modelName)
        }

        // Pin the registry host (and enforce offline) before any FluidAudio load call. See
        // pinRegistryHostIfNeeded.
        Self.pinRegistryHostIfNeeded()

        let v = version(for: modelName)
        let cacheDir = AsrModels.defaultCacheDirectory(for: v)

        guard AsrModels.modelsExist(at: cacheDir, version: v) else {
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: \(modelName) not present in cache; refusing to download")
            throw TranscriptionEngineError.modelAssetsMissing(modelName)
        }

        DiagnosticLogger.shared.log("ParakeetModelManager: loading \(modelName) from cache")
        do {
            // Route through the single global gate so this load can never run while
            // `ensureDownloaded` has `enforceOffline` flipped false. `enforceOffline` is true here
            // (the gate guarantees no concurrent download owns the false window), so `loadFromCache`
            // cannot silently re-download on a load/compile failure — it surfaces the error instead.
            return try await downloadGate.run {
                try await AsrModels.loadFromCache(version: v)
            }
        } catch {
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: \(modelName) failed to load from cache: "
                    + "\(error.localizedDescription)")
            throw TranscriptionEngineError.modelAssetsMissing(modelName)
        }
    }

    /// Cache-only load, retained as the engine's existing call name.
    ///
    /// Forwards to `loadDownloadedModels(_:)`; never downloads. Acquisition is owned exclusively by
    /// `ensureDownloaded(_:progress:)`.
    public func loadedModels(_ modelName: String) async throws -> AsrModels {
        try await loadDownloadedModels(modelName)
    }
}

/// Collapses FluidAudio's chunky, non-monotonic `DownloadProgress` stream into a single
/// never-decreasing display fraction in [0, 1).
///
/// FluidAudio acquires a Parakeet model by looping over its component specs (preprocessor,
/// encoder, decoder, joint) and re-running a full download→compile pass per spec, re-emitting its
/// own 0→0.5 (byte download) → 0.5→1.0 (CoreML compile) sweep each time. Forwarded verbatim, that
/// fraction sawtooths (e.g. 1.0→0.5→1.0…), so the progress bar jumps backward and reads as broken,
/// the original "download progress isn't showing" bug. This maps the real byte download into the
/// bulk of the bar and lets the (path-dependent, count-unknown) compile passes creep the tail
/// toward (but never reaching) 1.0; the caller pegs 1.0 only when the operation actually succeeds.
///
/// `@unchecked Sendable`: FluidAudio invokes the progress handler from an arbitrary queue, so the
/// mutable `displayed` cursor is guarded by a lock.
final class ProgressNormalizer: @unchecked Sendable {
    /// Byte download fills [0, downloadCeiling]; compile passes creep within (downloadCeiling, tailCeiling].
    private static let downloadCeiling = 0.85
    private static let tailCeiling = 0.99
    /// Each compile callback closes this fraction of the remaining gap to `tailCeiling`.
    private static let compileStep = 0.25

    private let lock = NSLock()
    private var displayed = 0.0

    /// Maps one FluidAudio progress snapshot to a monotonic [0, 1) display fraction.
    func map(_ p: DownloadUtils.DownloadProgress) -> Double {
        lock.lock()
        defer { lock.unlock() }
        switch p.phase {
        case .listing, .downloading:
            // FluidAudio's byte-weighted download fraction lives in [0, 0.5]; rescale it across the
            // download band. `max` keeps it monotonic against the per-spec "already on disk" 0.5 spikes.
            let raw = p.fractionCompleted.isFinite ? min(max(p.fractionCompleted, 0), 0.5) : 0
            let mapped = (raw / 0.5) * Self.downloadCeiling
            displayed = max(displayed, mapped)
        case .compiling:
            // Number of compile passes is path-dependent (download vs download+load), so advance
            // by a fixed fraction of the remaining gap on each callback, always forward, never 1.0.
            displayed = max(displayed, Self.downloadCeiling)
            displayed += (Self.tailCeiling - displayed) * Self.compileStep
        }
        return displayed
    }
}
