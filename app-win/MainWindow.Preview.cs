#if DEBUG
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tether;

namespace TetherApp;

public sealed partial class MainWindow
{
    private bool _preview;
    private static readonly HostEntry[] PreviewHosts =
    [
        new("Research workstation", "workstation.example", "researcher", 22, null),
        new("Build server", "build.example", "builder", 22, null),
        new("A host with a deliberately long name", "archive.example", "reader", 22, null),
    ];
    // Same offline state as InterfacePreviews.swift: twenty tabs, last selected,
    // empty canvas. No settings, shell, SSH config, credentials or native engine.
    private bool TryShowPreview()
    {
        var args = Environment.GetCommandLineArgs();
        if (!args.Contains("--ui-preview")) return false;
        _preview = true;
        var light = args.Contains("--light");
        WorkspaceRoot.RequestedTheme = light ? ElementTheme.Light : ElementTheme.Dark;
        Appearance.SetCanvas(light ? Palette.Light : Palette.Dark);
        TabStrip.Loaded += (_, _) =>
        {
            var scale = WorkspaceRoot.XamlRoot.RasterizationScale;
            AppWindow.ResizeClient(new Windows.Graphics.SizeInt32((int)(860 * scale), (int)(520 * scale)));
            DispatcherQueue.TryEnqueue(() => TabStrip.SelectedItem = TabStrip.TabItems[19]);
        };
        for (var index = 1; index <= 20; index++)
            TabStrip.TabItems.Add(CreateTab(index == 20
                ? "A terminal with a deliberately long name" : $"Terminal {index}"));
        TerminalHostPlaceholder.Children.Add(new TextBlock
        {
            Text = "No Open Terminals",
            Style = (Style)Application.Current.Resources["EmptyStateTextStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        });
        HostName.Text = "Research workstation";
        StatusText.Text = "Not connected";
        return true;
    }
}
#endif
