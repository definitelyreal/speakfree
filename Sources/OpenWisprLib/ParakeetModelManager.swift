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
        didPinRegistry = true
        DiagnosticLogger.shared.log(
            "ParakeetModelManager: pinned FluidAudio registry host to https://huggingface.co")
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

        DiagnosticLogger.shared.log("ParakeetModelManager: downloading \(modelName) (version \(v))")
        let start = Date()

        // FluidAudio's progress handler is `@Sendable (DownloadUtils.DownloadProgress) -> Void`.
        // Map its `.fractionCompleted` (already a 0..1 Double) onto our simpler `(Double) -> Void`.
        let handler: DownloadUtils.ProgressHandler = { p in
            progress(p.fractionCompleted)
        }

        // `downloadAndLoad` both fetches and compiles; we discard the loaded result here since
        // callers that want the loaded models use `loadedModels(_:)`. The cache is now warm so a
        // subsequent `loadedModels` call resolves from disk quickly.
        _ = try await AsrModels.downloadAndLoad(version: v, progressHandler: handler)

        let elapsed = Date().timeIntervalSince(start)
        DiagnosticLogger.shared.log(
            "ParakeetModelManager: \(modelName) downloaded + compiled in \(String(format: "%.1f", elapsed))s")
        progress(1.0)
    }

    // MARK: - Load

    /// Returns a fully loaded `AsrModels` for the given model name, downloading first if needed.
    ///
    /// Hand the returned value to `AsrManager(config:)` + `loadModels(_:)` in the engine (Unit 4).
    /// `AsrModels` is a `Sendable` struct in FluidAudio 0.15.1, so it crosses the actor boundary
    /// cleanly.
    public func loadedModels(_ modelName: String) async throws -> AsrModels {
        // Pin the registry host before any FluidAudio load/download call (it may hit the network
        // on a cache miss). See pinRegistryHostIfNeeded.
        Self.pinRegistryHostIfNeeded()

        let v = version(for: modelName)
        let cacheDir = AsrModels.defaultCacheDirectory(for: v)

        if AsrModels.modelsExist(at: cacheDir, version: v) {
            DiagnosticLogger.shared.log("ParakeetModelManager: loading \(modelName) from cache")
            return try await AsrModels.loadFromCache(version: v)
        }

        DiagnosticLogger.shared.log(
            "ParakeetModelManager: \(modelName) not cached, downloading + loading")
        return try await AsrModels.downloadAndLoad(version: v)
    }
}
