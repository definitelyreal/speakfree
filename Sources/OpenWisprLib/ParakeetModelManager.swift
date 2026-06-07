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

    // MARK: - Download single-flight

    /// Coalesces concurrent `ensureDownloaded` calls for the same model. Without this, two callers
    /// hitting `downloadAndLoad` at once would both write into FluidAudio's shared on-disk cache and
    /// race each other (and the `enforceOffline` flag flip). Keyed by FluidAudio version so a v2 and
    /// a v3 download can still proceed in parallel. The stored `Task` is removed once it completes.
    private let inFlightLock = NSLock()
    private var inFlightDownloads: [AsrModelVersion: InFlightDownload] = [:]
    private var inFlightCounter: UInt64 = 0

    /// A running download task plus a unique token, so the cleanup `defer` clears the slot only if it
    /// still holds *this* task (and not a newer one started after this one failed and was retried).
    /// `Task` is a value type, so identity has to be carried explicitly rather than via `===`.
    private struct InFlightDownload {
        let token: UInt64
        let task: Task<Void, Error>
    }

    /// Runs `body` while holding `inFlightLock`. Kept synchronous (and called only from synchronous
    /// stretches) so the lock is never held across an `await` — NSLock's `lock()`/`unlock()` are
    /// unavailable from async contexts under the Swift 6 language mode.
    private func withInFlightLock<T>(_ body: () -> T) -> T {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return body()
    }

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
        // Pin the registry host before any FluidAudio network call (see pinRegistryHostIfNeeded).
        Self.pinRegistryHostIfNeeded()

        let v = version(for: modelName)

        if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: v), version: v) {
            progress(1.0)
            return
        }

        // Single-flight: if a download for this version is already running, await it instead of
        // launching a second `downloadAndLoad` that would race the shared on-disk cache (and the
        // `enforceOffline` flag). The deduped caller doesn't receive incremental progress (only the
        // first caller's handler is wired into FluidAudio); it gets `1.0` once the shared task lands.
        //
        // Build-or-join under the lock so the check-and-insert is atomic: either we observe an
        // existing task to await, or we install our own — never both racing to create one.
        enum Outcome { case join(Task<Void, Error>); case own(token: UInt64, task: Task<Void, Error>) }

        let outcome: Outcome = withInFlightLock {
            if let existing = inFlightDownloads[v] {
                return .join(existing.task)
            }
            inFlightCounter += 1
            let token = inFlightCounter
            let task = Task<Void, Error> {
                DiagnosticLogger.shared.log(
                    "ParakeetModelManager: downloading \(modelName) (version \(v))")
                let start = Date()

                // FluidAudio's progress handler is `@Sendable (DownloadProgress) -> Void`. Map its
                // `.fractionCompleted` (already a 0..1 Double) onto our `(Double) -> Void`.
                let handler: DownloadUtils.ProgressHandler = { p in
                    progress(p.fractionCompleted)
                }

                // This is the ONLY sanctioned network fetch. Flip `enforceOffline` off for the
                // duration of the deliberate download and restore it via `defer`, so no other
                // FluidAudio path (e.g. a `loadFromCache` recovery) can silently hit the network
                // outside this method.
                DownloadUtils.enforceOffline = false
                defer { DownloadUtils.enforceOffline = true }

                // `downloadAndLoad` both fetches and compiles; we discard the loaded result here
                // since callers that want the loaded models use `loadDownloadedModels(_:)`. The
                // cache is now warm so a subsequent `loadDownloadedModels` resolves from disk fast.
                _ = try await AsrModels.downloadAndLoad(version: v, progressHandler: handler)

                let elapsed = Date().timeIntervalSince(start)
                DiagnosticLogger.shared.log(
                    "ParakeetModelManager: \(modelName) downloaded + compiled in "
                        + "\(String(format: "%.1f", elapsed))s")
            }
            inFlightDownloads[v] = InFlightDownload(token: token, task: task)
            return .own(token: token, task: task)
        }

        switch outcome {
        case .join(let existing):
            try await existing.value
            progress(1.0)

        case .own(let token, let task):
            // Always clear the in-flight slot when the task settles, whether it succeeded or threw,
            // so a failed download doesn't pin a dead task and block retries. Compare by token so a
            // newer retry installed after us isn't clobbered.
            defer {
                withInFlightLock {
                    if inFlightDownloads[v]?.token == token {
                        inFlightDownloads[v] = nil
                    }
                }
            }
            try await task.value
            progress(1.0)
        }
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
            // enforceOffline is true here, so this cannot silently re-download on a load/compile
            // failure — it surfaces the error instead.
            return try await AsrModels.loadFromCache(version: v)
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
