using Microsoft.UI.Xaml;

namespace TetherApp;

public partial class App : Application
{
    private Window? _window;

    public App() => InitializeComponent();

    /// <summary>
    /// The host window's <c>HWND</c>, as a pointer-sized integer. The one
    /// place a toolkit handle exists; the SDK is told only the number
    /// (spec §8).
    /// </summary>
    public nint MainWindowHandle =>
        _window is null ? 0 : WinRT.Interop.WindowNative.GetWindowHandle(_window);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
