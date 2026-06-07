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
    public func isModelDownloaded(_ modelName: String) -> Bool {
        let v = version(for: modelName)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: v), version: v)
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

        // Existence is a pure on-disk check independent of `enforceOffline`, so it stays outside the
        // gate to avoid holding the global slot for a no-op.
        if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: v), version: v) {
            progress(1.0)
            return
        }

        // Serialize behind the single global gate so the `enforceOffline = false` window below can
        // never overlap a concurrent cache load or another download. Re-check existence inside the
        // gate: a download that completed while we were queued makes ours a no-op.
        try await downloadGate.run {
            if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: v), version: v) {
                progress(1.0)
                return
            }

            DiagnosticLogger.shared.log(
                "ParakeetModelManager: downloading \(modelName) (version \(v))")
            let start = Date()

            // FluidAudio's progress handler is `@Sendable (DownloadProgress) -> Void`. Map its
            // `.fractionCompleted` (already a 0..1 Double) onto our `(Double) -> Void`.
            let handler: DownloadUtils.ProgressHandler = { p in
                progress(p.fractionCompleted)
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
