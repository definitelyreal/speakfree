// ai-suggestion:unverified · session:01a0a4bf-8ebb-7b73-8929-dad5ed263731 · 2026-09-15
import SwiftUI

/// Each model retains its own download state when the selection changes. Attempt IDs
/// reject late progress callbacks after a failure or retry.
private struct ParakeetDownloadAttempt {
    let id: UUID
    var progress: Double = 0
    var isInFlight = true
    var detailsHidden = false
    var error: String?
}

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

    @State private var downloads: [String: ParakeetDownloadAttempt] = [:]
    /// Re-checked after downloads / model switches to drive the banner.
    @State private var isModelDownloaded = false
    private var selectedDownload: ParakeetDownloadAttempt? {
        downloads[viewModel.parakeetModel]
    }

    /// Headroom required before we attempt a Parakeet download (~600 MB weights plus
    /// CoreML compile scratch). ~1.5 GB keeps us clear of the compile pause running out
    /// of disk mid-way.
    private let requiredFreeBytes: Int64 = 1_500_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Engine")
                        .frame(width: SettingsLayout.labelWidth, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    Picker("Transcription engine", selection: $viewModel.engine) {
                        ForEach(EngineCatalog.engines, id: \.id) { engine in
                            Text(engine.displayName).tag(engine.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.regular)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.engine == "parakeet" {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Parakeet Model")
                            .frame(width: SettingsLayout.labelWidth, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) {
                            Picker("Parakeet model", selection: $viewModel.parakeetModel) {
                                ForEach(EngineCatalog.parakeetModels, id: \.id) { model in
                                    // Un-downloaded models are greyed and labeled, so
                                    // picking one is a knowing "this will download"
                                    // choice (Michael 2026-08-19).
                                    let downloaded = ParakeetModelManager.shared.isModelDownloaded(model.id)
                                    Text(model.displayName
                                         + (downloaded ? "" : " · Download needed"))
                                        .foregroundColor(downloaded ? .primary : .secondary)
                                        .tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .controlSize(.regular)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)

                            parakeetDownloadBanner
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: viewModel.engine) { _ in
            viewModel.save()
            refreshDownloadState()
        }
        .onChange(of: viewModel.parakeetModel) { _ in
            viewModel.save()
            refreshDownloadState()
        }
        .onAppear {
            downloads[viewModel.parakeetModel]?.detailsHidden = false
            refreshDownloadState()
        }
    }

    // MARK: - Parakeet download banner

    @ViewBuilder
    private var parakeetDownloadBanner: some View {
        if let download = selectedDownload, download.isInFlight {
            if download.detailsHidden {
                HStack(spacing: 8) {
                    Text("Downloading in background · \(Int(download.progress * 100))%")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("Show Progress") {
                        downloads[viewModel.parakeetModel]?.detailsHidden = false
                    }
                    .controlSize(.regular)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // FluidAudio combines downloading and preparation into one fraction.
                    HStack {
                        Text("Downloading / preparing · \(Int(download.progress * 100))%")
                            .font(.callout.weight(.medium))
                        Spacer()
                        // FluidAudio cannot cancel. Hide only collapses the details.
                        Button("Hide") {
                            downloads[viewModel.parakeetModel]?.detailsHidden = true
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                    ProgressView(value: download.progress, total: 1.0)
                        .progressViewStyle(.linear)
                    Text("Downloading and preparation continue if you hide this or close Settings. They cannot be stopped once started.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        } else if !isModelDownloaded {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // L3: surface the model size so the download cost is clear.
                    Text("Download needed (\(parakeetSizeDescription)).")
                        .font(.callout.weight(.medium))
                    if let downloadError = selectedDownload?.error {
                        Text(downloadError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
                Spacer()
                Button("Download") { startDownload() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        } else {
            Label("Downloaded and ready", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundColor(.green)
        }
    }

    // MARK: - Helpers

    private var parakeetModelInfo: ParakeetModelInfo? {
        EngineCatalog.parakeetModels.first(where: { $0.id == viewModel.parakeetModel })
    }

    private var parakeetSizeDescription: String {
        parakeetModelInfo?.sizeDescription ?? "~600 MB"
    }

    /// Refresh the downloaded-state flag for the currently selected Parakeet model.
    private func refreshDownloadState() {
        guard viewModel.engine == "parakeet" else { return }
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

    private func startDownload() {
        let modelName = viewModel.parakeetModel
        guard downloads[modelName]?.isInFlight != true else { return }
        let attemptID = UUID()

        // H3: disk-space precheck before committing to a download. If we can read the
        // volume capacity and it's short, refuse early with a concrete number.
        if let free = availableFreeBytes(for: modelName), free < requiredFreeBytes {
            // L3: message must match the real gate (~1.5 GB: ~600 MB model + CoreML compile scratch).
            downloads[modelName] = ParakeetDownloadAttempt(
                id: attemptID, isInFlight: false,
                error: "Need ~1.5 GB free (\u{2248}600 MB model + compile scratch), you have \(Self.formatBytes(free)).")
            return
        }

        downloads[modelName] = ParakeetDownloadAttempt(id: attemptID)
        // FluidAudio does not support cancellation. The task keeps running independently
        // of the selected engine, model, and whether its progress details are visible.
        Task {
            do {
                try await ParakeetModelManager.shared.ensureDownloaded(modelName) { progress in
                    Task { @MainActor in
                        guard self.downloads[modelName]?.id == attemptID,
                              self.downloads[modelName]?.isInFlight == true else { return }
                        self.downloads[modelName]?.progress = min(1, max(0, progress))
                    }
                }
                await MainActor.run {
                    guard self.downloads[modelName]?.id == attemptID else { return }
                    self.downloads[modelName]?.isInFlight = false
                    self.downloads[modelName]?.progress = 1
                    guard self.viewModel.engine == "parakeet",
                          self.viewModel.parakeetModel == modelName else { return }
                    self.refreshDownloadState()
                    // I1: while the model was undownloaded, reloadConfig took the `.keepCurrent`
                    // branch (see AppDelegate.parakeetReloadDecision) and left the live transcriber
                    // on the OLD engine. Now that the model is on disk, re-save so reloadConfig
                    // re-runs and hits `.rebuild(modelID:)` — otherwise the new engine wouldn't
                    // take effect until the app restarts.
                    self.viewModel.save()
                }
            } catch {
                await MainActor.run {
                    guard self.downloads[modelName]?.id == attemptID else { return }
                    self.downloads[modelName]?.isInFlight = false
                    self.downloads[modelName]?.error = Self.userFacingMessage(for: error)
                    guard self.viewModel.engine == "parakeet",
                          self.viewModel.parakeetModel == modelName else { return }
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
