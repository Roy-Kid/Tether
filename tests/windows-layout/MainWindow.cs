using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using System.Text.Json;
using System.Runtime.InteropServices;

namespace TetherApp;

/// <summary>Loads the production XAML and resources with inert fixture actions.</summary>
public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "Workspace layout fixture (no shell)";
        var args = Environment.GetCommandLineArgs();
        var light = args.Contains("--light");
        var vertical = args.Contains("--vertical");
        var empty = args.Contains("--empty");
        WorkspaceRoot.RequestedTheme = light ? ElementTheme.Light : ElementTheme.Dark;
        WorkspaceRoot.Background = new SolidColorBrush(light
            ? Microsoft.UI.ColorHelper.FromArgb(153, 247, 248, 250)
            : Microsoft.UI.ColorHelper.FromArgb(153, 23, 27, 34));
        ((SolidColorBrush)Application.Current.Resources["TerminalCanvasBrush"]).Color = Microsoft.UI.Colors.Transparent;
        WindowEffects.Apply(this);
        var notifications = 0;
        var burstCallbacks = -1;
        WindowEffects.Observe(this, WorkspaceRoot, () => notifications++);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(vertical ? HiddenTitleBarDragArea : TitleBarDragArea);
        if (vertical)
        {
            TabStrip.Visibility = Visibility.Collapsed;
            VerticalTabs.Visibility = Visibility.Visible;
            HiddenTitleBarDragArea.Visibility = Visibility.Visible;
        }
        var tabCount = args.Contains("--overflow") ? 20 : empty ? 0 : 3;
        for (var index = 1; index <= tabCount; index++)
        {
            var name = index == 1 ? "Terminal" : index == 2 ? "Build server" : $"Terminal {index}";
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            row.Children.Add(new FontIcon { Glyph = "\uE756", FontSize = 11 });
            row.Children.Add(new TextBlock { Text = name, FontSize = 12, MaxWidth = 144, VerticalAlignment = VerticalAlignment.Center });
            TabStrip.TabItems.Add(new TabViewItem { Header = row, Style = (Style)Application.Current.Resources["WorkspaceTabItemStyle"] });
            VerticalTabList.Items.Add(new PreviewTab(name, index == 2 ? "PowerShell" : ""));
        }
        if (tabCount > 0)
        {
            TabStrip.SelectedIndex = tabCount - 1;
            VerticalTabList.SelectedIndex = tabCount - 1;
        }
        EmptyWorkspace.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        HostName.Text = "Research workstation";
        StatusDot.Fill = new SolidColorBrush(Microsoft.UI.Colors.MediumSeaGreen);
        if (!empty)
        {
            TerminalHostPlaceholder.Children.Add(new TextBlock
            {
                Text = "researcher@workstation ~\n\n$ cargo test --workspace\n    Finished test profile\n\n    Running terminal layout checks\n\ntest workspace_background ... ok\ntest unicode_cell_alignment ... ok\ntest native_surface_lifecycle ... ok\n\ntest result: ok. 36 passed; 0 failed\n\n$ █",
                FontFamily = new FontFamily("Consolas"), FontSize = 14, Margin = new Thickness(16),
                Foreground = new SolidColorBrush(light ? Microsoft.UI.Colors.Black : Microsoft.UI.ColorHelper.FromArgb(255, 216, 222, 233)),
            });
        }
        foreach (var glyph in new[] { "\uE8B7", "\uE968", "\uF0E2" })
            PluginButtons.Children.Add(new ToggleButton
            {
                Style = (Style)Application.Current.Resources["StatusIconToggleStyle"],
                Content = new FontIcon { Glyph = glyph, FontSize = 11 },
            });
        WorkspaceRoot.Loaded += (_, _) =>
        {
            var scale = WorkspaceRoot.XamlRoot.RasterizationScale;
            AppWindow.ResizeClient(new Windows.Graphics.SizeInt32((int)((args.Contains("--narrow") ? 760 : 1100) * scale), (int)(700 * scale)));
            CaptionLeftInset.Width = new GridLength(AppWindow.TitleBar.LeftInset / scale);
            CaptionRightInset.Width = new GridLength(AppWindow.TitleBar.RightInset / scale);
            WindowHeader.MinHeight = Math.Max(32, Math.Ceiling(AppWindow.TitleBar.Height / scale));
            AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
            AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
            AppWindow.TitleBar.ButtonForegroundColor = light ? Microsoft.UI.Colors.Black : Microsoft.UI.Colors.White;
            DispatcherQueue.TryEnqueue(() =>
            {
                var before = notifications;
                var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
                for (var index = 0; index < 100; index++) SendMessage(handle, 0x001A, 0, 0);
                DispatcherQueue.TryEnqueue(() => burstCallbacks = notifications - before);
            });
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        var ticks = 0;
        timer.Tick += (_, _) =>
        {
            var failures = new List<string>();
            if (Math.Abs(StatusBar.ActualHeight - 24) > .1) failures.Add("Host bar must be 24 DIPs");
            if (WindowHeader.ActualHeight > 32.1) failures.Add("Unexpected extra titlebar height");
            if (TerminalHostPlaceholder.Padding != new Thickness(0)) failures.Add("Duplicate terminal inset");
            if (WorkspaceMenuButton.ActualWidth > 0) failures.Add("Unexpected second titlebar toolbar");
            if (notifications == 0) failures.Add("Native appearance broadcast was not observed");
            if (burstCallbacks != 1) failures.Add("Appearance broadcasts did not coalesce into one refresh");
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "layout-check.json"), JsonSerializer.Serialize(new
            {
                failures, scale = WorkspaceRoot.XamlRoot.RasterizationScale,
                header = WindowHeader.ActualHeight, status = StatusBar.ActualHeight,
                terminal = new { width = TerminalHostPlaceholder.ActualWidth, height = TerminalHostPlaceholder.ActualHeight },
                vertical, empty, tabCount, selected = TabStrip.SelectedIndex, notifications, burstCallbacks,
            }, new JsonSerializerOptions { WriteIndented = true }));
            if (args.Contains("--check"))
            {
                Environment.ExitCode = failures.Count == 0 ? 0 : 1;
                Close();
            }
            else if (++ticks == 30) Close();
        };
        timer.Start();
        Closed += (_, _) => timer.Stop();
    }

    private void WorkspaceMenu_Click(object sender, RoutedEventArgs e) { }
    private void WorkspaceMenu_RightTapped(object sender, RightTappedRoutedEventArgs e) { }
    private void TabBarToggle_Click(object sender, RoutedEventArgs e) { }
    private void Tab_AddRequested(TabView sender, object args) { }
    private void Tab_CloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args) => TabStrip.TabItems.Remove(args.Tab);
    private void Tab_SelectionChanged(object sender, SelectionChangedEventArgs e) { }
    private void VerticalTabs_SelectionChanged(object sender, SelectionChangedEventArgs e) { }
    private void VerticalAdd_Click(object sender, RoutedEventArgs e) { }
    private void InspectorResize_DragDelta(object sender, DragDeltaEventArgs e) { }
    private void VerticalTabsResize_DragDelta(object sender, DragDeltaEventArgs e) { }
    private void Connect_Click(object sender, RoutedEventArgs e) { }
    private void CancelConnect_Click(object sender, RoutedEventArgs e) { }
    private void Reconnect_Click(object sender, RoutedEventArgs e) { }
    private void SplitLeft_Click(object sender, RoutedEventArgs e) { }
    private void SplitRight_Click(object sender, RoutedEventArgs e) { }
    private void SplitUp_Click(object sender, RoutedEventArgs e) { }
    private void SplitDown_Click(object sender, RoutedEventArgs e) { }
    private void MaximizePane_Click(object sender, RoutedEventArgs e) { }
    private void Settings_Click(object sender, RoutedEventArgs e) { }
    private sealed record PreviewTab(string Title, string Subtitle);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint SendMessage(nint hwnd, uint message, nint wParam, nint lParam);
}
