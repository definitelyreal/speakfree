namespace OpenWispr.Windows.UI;

public partial class RecordingOverlay : Window
{
    public RecordingOverlay()
    {
        InitializeComponent();
        PositionBottomRight();
    }

    private void PositionBottomRight()
    {
        var screen = SystemParameters.WorkArea;
        Left = screen.Right - Width - 20;
        Top = screen.Bottom - Height - 20;
    }

    new public void Show()
    {
        PositionBottomRight();
        base.Show();
    }
}
