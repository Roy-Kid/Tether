using Microsoft.UI.Xaml;

namespace LayoutPreview;

/// <summary>Standalone native layout fixture. No terminal engine, shell, SSH or user settings are opened.</summary>
public partial class App : Application
{
    private Window? _window;
    public App()
    {
        UnhandledException += (_, e) => File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "layout-error.log"), e.Exception.ToString());
        InitializeComponent();
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new TetherApp.MainWindow();
        if (Environment.GetCommandLineArgs().Contains("--check")) _window.AppWindow.Show(false);
        else _window.Activate();
    }
}
