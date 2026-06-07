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
    /// Retained so the user can cancel an in-flight download (M1).
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
            refreshDownloadState()
        }
        .onChange(of: viewModel.parakeetModel) { _ in
            viewModel.save()
            refreshDownloadState()
        }
        .onAppear {
            refreshDownloadState()
        }
    }

    // MARK: - Parakeet download banner

    @ViewBuilder
    private var parakeetDownloadBanner: some View {
        if isDownloading {
            VStack(alignment: .leading, spacing: 4) {
                // L2: single phase-agnostic label so the CoreML compile pause (progress
                // sits at ~100%) doesn't read as a hang. ParakeetModelManager exposes no
                // phase signal, so we label the whole operation rather than guess.
                HStack {
                    Text("Downloading / preparing \(parakeetDisplayName)\u{2026} \(Int(downloadProgress * 100))%")
                        .font(.callout.weight(.medium))
                    Spacer()
                    // M1: cancel an in-flight download.
                    Button("Cancel") { cancelDownload() }
                        .buttonStyle(.bordered)
                }
                ProgressView(value: downloadProgress, total: 1.0)
                    .progressViewStyle(.linear)
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

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        refreshDownloadState()
    }

    private func startDownload() {
        let modelName = viewModel.parakeetModel
        downloadError = nil

        // H3: disk-space precheck before committing to a download. If we can read the
        // volume capacity and it's short, refuse early with a concrete number.
        if let free = availableFreeBytes(for: modelName), free < requiredFreeBytes {
            downloadError = "Need ~600 MB free, you have \(Self.formatBytes(free))."
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
            return "Ran out of disk space. Free up ~600 MB and try again."
        }
        return error.localizedDescription
    }
}
