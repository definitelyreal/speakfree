using OpenWispr.Windows.Settings;
using OpenWispr.Windows.Transcription;

namespace OpenWispr.Windows.UI;

public partial class ModelDownloadWindow : Window
{
    private readonly App _app;
    private CancellationTokenSource? _cts;

    public ModelDownloadWindow(App app)
    {
        InitializeComponent();
        _app = app;
        ModelPicker.ItemsSource = ModelDownloader.KnownModels;
        ModelPicker.SelectedIndex = 1; // base.en
        UpdateSizeLabel();
    }

    private void ModelPicker_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
        => UpdateSizeLabel();

    private void UpdateSizeLabel()
    {
        var size = ModelPicker.SelectedItem as string;
        if (size != null && ModelDownloader.ModelSizes.TryGetValue(size, out var bytes))
            SizeLabel.Text = $"~{bytes / 1_000_000} MB";
    }

    private async void DownloadBtn_Click(object sender, RoutedEventArgs e)
    {
        var size = ModelPicker.SelectedItem as string;
        if (size == null) return;

        var destPath = Path.Combine(AppSettings.DefaultModelsPath, ModelDownloader.ModelFileName(size));
        DownloadBtn.IsEnabled = false;
        Progress.Visibility = Visibility.Visible;
        StatusLabel.Text = "Downloading...";
        _cts = new CancellationTokenSource();

        try
        {
            var downloader = new ModelDownloader();
            await downloader.DownloadAsync(size, destPath,
                new Progress<double>(p =>
                {
                    Dispatcher.Invoke(() =>
                    {
                        Progress.Value = p;
                        StatusLabel.Text = $"{p:P0}";
                    });
                }),
                _cts.Token);

            var updated = _app.Settings with { ModelPath = destPath, ModelSize = size };
            _app.SaveSettings(updated);
            await _app.StartMainLoop();
            Close();
        }
        catch (OperationCanceledException)
        {
            StatusLabel.Text = "Cancelled";
            DownloadBtn.IsEnabled = true;
        }
        catch (Exception ex)
        {
            StatusLabel.Text = $"Error: {ex.Message}";
            DownloadBtn.IsEnabled = true;
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        _cts?.Cancel();
        base.OnClosed(e);
    }
}
