using Microsoft.UI.Xaml;

namespace TetherApp;

public partial class App : Application
{
    private Window? _window;

    /// <summary>Every extension this process loaded. The window draws the list; this is the line that names one.</summary>
    public static Plugins.PluginRegistry Plugins { get; private set; } = new();

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
        AppSettings.Load();
        Plugins = new Plugins.PluginRegistry(
            AppSettings.Current.DisabledPlugins,
            disabled => (AppSettings.Current with { DisabledPlugins = disabled.ToArray() }).Save());
        Plugins.Register(new Plugins.FilesPlugin());
        Plugins.Register(new Plugins.TmuxPlugin());
        TetherApp.Plugins.WebPluginServices.Register("app.nerve.hub", "app.nerve.tether.web", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Nerve", "nerve-hub.exe"), new Uri("http://127.0.0.1:17890/v1/health"));
        string? installProblem = null;
        if (CommandLineValue("--install-plugin") is { } source)
        {
            try { TetherApp.Plugins.WebPluginPackage.Install(source, TetherApp.Plugins.WebPluginCatalog.Root); }
            catch (Exception ex) { installProblem = ex.Message; }
        }
        TetherApp.Plugins.WebPluginCatalog.Discover(Plugins);
        _window = new MainWindow();
        _window.Activate();
        if (installProblem is not null)
        {
            var problem = installProblem;
            ((FrameworkElement)_window.Content).Loaded += async (_, _) => await Alerts.ContentAsync("Install Plugin", problem, "Close", null,
                Appearance.RequestedTheme, _ => { });
        }
    }

    internal static string? CommandLineValue(string option)
    {
        var arguments = Environment.GetCommandLineArgs(); var index = Array.IndexOf(arguments, option);
        return index >= 0 && index + 1 < arguments.Length ? arguments[index + 1] : null;
    }
}
