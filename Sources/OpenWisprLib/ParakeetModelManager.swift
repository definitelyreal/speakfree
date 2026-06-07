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

    // MARK: - Model name → version mapping

    /// Maps a speakfree Parakeet model-name string to FluidAudio's `AsrModelVersion`.
    ///
    /// - `parakeet-tdt-0.6b-v2` → `.v2` (English-only)
    /// - `parakeet-tdt-0.6b-v3` → `.v3` (multilingual, 25 languages) — also the default fallback.
    private func version(for modelName: String) -> AsrModelVersion {
        switch modelName {
        case "parakeet-tdt-0.6b-v2":
            return .v2
        case "parakeet-tdt-0.6b-v3":
            return .v3
        default:
            DiagnosticLogger.shared.log(
                "ParakeetModelManager: unknown model name '\(modelName)', defaulting to v3")
            return .v3
        }
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
