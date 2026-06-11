// ai:suggestion · session: 26-06-07-parakeet-impl · 2026-06-07
import SwiftUI

/// Engine selector for the Transcription settings GroupBox. Lets the user pick the
/// transcription backend (Whisper or Parakeet) and, when Parakeet is selected, choose
/// a Parakeet model and download its assets via FluidAudio.
///
/// Rendered as the FIRST item inside the Transcription GroupBox. When the engine is
/// "whisper" it renders only the engine row, leaving the existing Whisper language/model
/// pickers below untouched. When the engine is "parakeet" it adds a Parakeet model picker
/// and a download banner driven by `ParakeetModelManager`.
struct EnginePickerView: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// True while a Parakeet model download is in flight.
    @State private var isDownloading = false
    /// Download progress in 0...1, mirrored from ParakeetModelManager.ensureDownloaded.
    @State private var downloadProgress: Double = 0
    /// Set when a download fails so the user sees why.
    @State private var downloadError: String?
    /// Re-checked after downloads / model switches to drive the banner.
    @State private var isModelDownloaded = false
    /// Retained so re-opening the picker reflects real in-flight state (M1). NOTE: FluidAudio's
    /// download/compile path has no cancellation support (no Task.checkCancellation in
    /// DownloadUtils.download or AsrModels.load), so cancelling this task does NOT stop the
    /// 600 MB fetch + CoreML compile — they keep running in the background. We therefore
    /// never expose a "Cancel" control; the only honest action is "Hide" (run in background).
    @State private var downloadTask: Task<Void, Never>?

    private let labelWidth: CGFloat = 110

    /// Headroom required before we attempt a Parakeet download (~600 MB weights plus
    /// CoreML compile scratch). ~1.5 GB keeps us clear of the compile pause running out
    /// of disk mid-way.
    private let requiredFreeBytes: Int64 = 1_500_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Engine")
                        .frame(width: labelWidth, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    Picker("", selection: $viewModel.engine) {
                        ForEach(EngineCatalog.engines, id: \.id) { engine in
                            Text(engine.displayName).tag(engine.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 160, alignment: .leading)
                }

                if viewModel.engine == "parakeet" {
                    GridRow {
                        Text("Parakeet Model")
                        VStack(alignment: .leading, spacing: 2) {
                            Picker("", selection: $viewModel.parakeetModel) {
                                ForEach(EngineCatalog.parakeetModels, id: \.id) { model in
                                    Text("\(model.displayName) (\(model.sizeDescription))").tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 260, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.engine == "parakeet" {
                // H2: Parakeet has no live preview while recording.
                Text("Parakeet transcribes after you finish speaking \u{2014} no live preview while recording.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                parakeetDownloadBanner

                // M4: CC-BY attribution (license obligation).
                Text("Speech recognition by NVIDIA Parakeet (CC-BY-4.0) via FluidAudio (Apache-2.0).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .onChange(of: viewModel.engine) { _ in
            viewModel.save()
            // M (MID-DOWNLOAD SWITCH): a download may still be running for the previous
            // selection (FluidAudio can't be cancelled). Clear the transient banner so the
            // old progress/labels don't bleed into the new selection, then re-evaluate the
            // on-disk state for the now-selected engine/model. The background task finishes
            // on its own; its completion handler is a no-op for this view's current state.
            downloadTask = nil
            resetTransientDownloadUI()
            refreshDownloadState()
        }
        .onChange(of: viewModel.parakeetModel) { _ in
            viewModel.save()
            // M (MID-DOWNLOAD SWITCH): same as engine — reset transient UI and re-check the
            // newly selected model's downloaded state instead of showing stale progress.
            downloadTask = nil
            resetTransientDownloadUI()
            refreshDownloadState()
        }
        .onAppear {
            restoreInFlightState()
        }
        .onDisappear {
            // Keep the background task running but drop the transient banner state so a
            // re-open starts from a coherent baseline (restoreInFlightState rebuilds it).
            resetTransientDownloadUI()
        }
    }

    // MARK: - Parakeet download banner

    @ViewBuilder
    private var parakeetDownloadBanner: some View {
        if isDownloading {
            VStack(alignment: .leading, spacing: 4) {
                // L2: single phase-spanning label. FluidAudio does expose a phase signal
                // (DownloadProgress.phase: .listing/.downloading/.compiling), but our
                // manager flattens it to a 0..1 fraction. The CoreML compile phase makes
                // the bar jump near the end, so we use one "Downloading / preparing" label
                // covering both fetch and compile rather than implying a stalled download.
                HStack {
                    Text("Downloading / preparing \(parakeetDisplayName)\u{2026} \(Int(downloadProgress * 100))%")
                        .font(.callout.weight(.medium))
                    Spacer()
                    // M1 (HONEST CANCEL): FluidAudio cannot be cancelled, so we offer "Hide"
                    // instead of "Cancel" — it dismisses the banner but the download keeps
                    // running in the background. Re-opening the picker shows real state.
                    Button("Hide") { hideDownload() }
                        .buttonStyle(.bordered)
                }
                ProgressView(value: downloadProgress, total: 1.0)
                    .progressViewStyle(.linear)
                Text("Download continues in the background \u{2014} it can\u{2019}t be stopped once started. You can close this and keep using the app.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } else if !isModelDownloaded {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // L3: surface the model size so the download cost is clear.
                    Text("\(parakeetDisplayName) (\(parakeetSizeDescription)) needs to be downloaded.")
                        .font(.callout.weight(.medium))
                    if let downloadError = downloadError {
                        Text(downloadError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
                Spacer()
                Button("Download") { startDownload() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Text("\(parakeetDisplayName) (\(parakeetSizeDescription)) is downloaded and ready.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private var parakeetModelInfo: ParakeetModelInfo? {
        EngineCatalog.parakeetModels.first(where: { $0.id == viewModel.parakeetModel })
    }

    private var parakeetDisplayName: String {
        parakeetModelInfo?.displayName ?? viewModel.parakeetModel
    }

    private var parakeetSizeDescription: String {
        parakeetModelInfo?.sizeDescription ?? "~600 MB"
    }

    /// Refresh the downloaded-state flag for the currently selected Parakeet model.
    private func refreshDownloadState() {
        guard viewModel.engine == "parakeet" else { return }
        downloadError = nil
        isModelDownloaded = ParakeetModelManager.shared.isModelDownloaded(viewModel.parakeetModel)
    }

    /// Free space (bytes) on the volume backing FluidAudio's cache for this model, or nil if
    /// it can't be determined.
    private func availableFreeBytes(for modelName: String) -> Int64? {
        let cacheDir = ParakeetModelManager.shared.cacheDirectory(for: modelName)
        // The cache directory may not exist yet; walk up to the nearest existing ancestor so
        // the volume capacity query has a real path to resolve.
        var probe = cacheDir
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) && probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        // Fallback to the plain available-capacity key.
        if let attrs = try? fm.attributesOfFileSystem(forPath: probe.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// M1 (HONEST CANCEL): Dismiss the in-flight banner WITHOUT cancelling the work.
    /// FluidAudio's fetch + compile can't be stopped, so we deliberately do not call
    /// `downloadTask?.cancel()` (it would do nothing but mislead). We keep `downloadTask`
    /// set so re-opening the picker can restore the live banner via `restoreInFlightState`.
    private func hideDownload() {
        isDownloading = false
    }

    /// Reset only the transient banner UI (progress/error/flag). Does not touch a running
    /// download task — used on disappear and on engine/model switch to keep UI coherent.
    private func resetTransientDownloadUI() {
        isDownloading = false
        downloadProgress = 0
        downloadError = nil
    }

    /// If a download is still running (task retained), restore the live banner; otherwise
    /// re-check the on-disk downloaded state.
    private func restoreInFlightState() {
        if downloadTask != nil {
            isDownloading = true
        } else {
            isDownloading = false
        }
        refreshDownloadState()
    }

    private func startDownload() {
        let modelName = viewModel.parakeetModel
        downloadError = nil

        // H3: disk-space precheck before committing to a download. If we can read the
        // volume capacity and it's short, refuse early with a concrete number.
        if let free = availableFreeBytes(for: modelName), free < requiredFreeBytes {
            // L3: message must match the real gate (~1.5 GB: ~600 MB model + CoreML compile scratch).
            downloadError = "Need ~1.5 GB free (\u{2248}600 MB model + compile scratch), you have \(Self.formatBytes(free))."
            return
        }

        downloadProgress = 0
        isDownloading = true
        downloadTask = Task {
            do {
                try await ParakeetModelManager.shared.ensureDownloaded(modelName) { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress
                    }
                }
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadTask = nil
                    self.refreshDownloadState()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadTask = nil
                    self.refreshDownloadState()
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadTask = nil
                    self.downloadError = Self.userFacingMessage(for: error)
                    self.refreshDownloadState()
                }
            }
        }
    }

    /// Maps a download error to a user-facing message, special-casing out-of-disk (H3).
    private static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        // POSIX ENOSPC (28) or Cocoa "out of space" surface here when the CoreML compile or
        // download fills the volume mid-way.
        let isOutOfSpace =
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28) ||
            (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
        if isOutOfSpace {
            return "Ran out of disk space. Free up ~1.5 GB (model + compile scratch) and try again."
        }
        return error.localizedDescription
    }
}
