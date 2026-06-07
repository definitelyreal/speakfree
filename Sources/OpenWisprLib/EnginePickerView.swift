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

    private let labelWidth: CGFloat = 110

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
                        Picker("", selection: $viewModel.parakeetModel) {
                            ForEach(EngineCatalog.parakeetModels, id: \.id) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 220, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.engine == "parakeet" {
                parakeetDownloadBanner
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
                Text("Downloading \(parakeetDisplayName)\u{2026} \(Int(downloadProgress * 100))%")
                    .font(.callout.weight(.medium))
                ProgressView(value: downloadProgress, total: 1.0)
                    .progressViewStyle(.linear)
            }
        } else if !isModelDownloaded {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(parakeetDisplayName) needs to be downloaded.")
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
            Text("\(parakeetDisplayName) is downloaded and ready.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private var parakeetDisplayName: String {
        EngineCatalog.parakeetModels.first(where: { $0.id == viewModel.parakeetModel })?.displayName
            ?? viewModel.parakeetModel
    }

    /// Refresh the downloaded-state flag for the currently selected Parakeet model.
    private func refreshDownloadState() {
        guard viewModel.engine == "parakeet" else { return }
        downloadError = nil
        isModelDownloaded = ParakeetModelManager.shared.isModelDownloaded(viewModel.parakeetModel)
    }

    private func startDownload() {
        let modelName = viewModel.parakeetModel
        downloadError = nil
        downloadProgress = 0
        isDownloading = true
        Task {
            do {
                try await ParakeetModelManager.shared.ensureDownloaded(modelName) { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress
                    }
                }
                await MainActor.run {
                    self.isDownloading = false
                    self.refreshDownloadState()
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadError = error.localizedDescription
                    self.refreshDownloadState()
                }
            }
        }
    }
}
