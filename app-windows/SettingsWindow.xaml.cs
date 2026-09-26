using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TetherApp.Plugins;

namespace TetherApp;

public sealed partial class SettingsWindow : Window
{
    private bool _loading = true;
    private readonly PluginRegistry? _plugins;

    public SettingsWindow() : this(null) { }

    public SettingsWindow(PluginRegistry? plugins)
    {
        _plugins = plugins;
        InitializeComponent();
        BuildExtensions();
        foreach (var profile in AppSettings.KnownShells)
            ShellPicker.Items.Add(new ComboBoxItem { Content = profile.Name, Tag = profile.Program });
        // Preserve existing custom program preferences instead of silently replacing them.
        if (!AppSettings.KnownShells.Any(profile => profile.Program == AppSettings.Current.Shell))
            ShellPicker.Items.Add(new ComboBoxItem { Content = AppSettings.Current.Shell, Tag = AppSettings.Current.Shell });
        ShellPicker.SelectedItem = ShellPicker.Items.Cast<ComboBoxItem>()
            .First(item => (string)item.Tag == AppSettings.Current.Shell);
        _loading = false;
        AppSettings.Changed += ApplyAppearance;
        SettingsRoot.ActualThemeChanged += (_, _) => UpdateTitleBar();
        SettingsRoot.Loaded += (_, _) => UpdateTitleBar();
        Closed += (_, _) => AppSettings.Changed -= ApplyAppearance;
        ApplyAppearance();
        Activate();
    }

    private void ApplyAppearance()
    {
        _loading = true;
        SettingsRoot.RequestedTheme = Appearance.RequestedTheme;
        ThemePicker.SelectedItem = ThemePicker.Items.Cast<ComboBoxItem>()
            .FirstOrDefault(item => (string)item.Tag == AppSettings.Current.Appearance) ?? ThemePicker.Items[0];
        _loading = false;
        UpdateTitleBar();
    }

    private void UpdateTitleBar()
    {
        var background = ((SolidColorBrush)SettingsRoot.Background).Color;
        var foreground = ((SolidColorBrush)PageHeading.Foreground).Color;
        var titleBar = AppWindow.TitleBar;
        titleBar.BackgroundColor = titleBar.InactiveBackgroundColor = background;
        titleBar.ButtonBackgroundColor = titleBar.ButtonInactiveBackgroundColor = background;
        titleBar.ForegroundColor = titleBar.ButtonForegroundColor = foreground;
        titleBar.InactiveForegroundColor = titleBar.ButtonInactiveForegroundColor =
            ((SolidColorBrush)SaveProblem.Foreground).Color;
    }

    private void Section_Changed(NavigationView sender, NavigationViewSelectionChangedEventArgs e)
    {
        if (StartupPane is null || AppearancePane is null || ExtensionsPane is null) return;
        var tag = (e.SelectedItem as NavigationViewItem)?.Tag as string;
        PageHeading.Text = tag switch { "appearance" => "Appearance", "extensions" => "Extensions", _ => "Startup" };
        StartupPane.Visibility = tag is null or "startup" ? Visibility.Visible : Visibility.Collapsed;
        AppearancePane.Visibility = tag == "appearance" ? Visibility.Visible : Visibility.Collapsed;
        ExtensionsPane.Visibility = tag == "extensions" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BuildExtensions()
    {
        ExtensionsPane.Children.Clear();
        if (_plugins is null || _plugins.Plugins.Count == 0)
        {
            ExtensionsPane.Children.Add(new TextBlock
            {
                Text = "No extensions are installed.",
                Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"],
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        foreach (var plugin in _plugins.Plugins)
        {
            var toggle = new ToggleSwitch
            {
                Header = plugin.Metadata.Name,
                IsOn = _plugins.IsEnabled(plugin.Metadata.Id),
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            AutomationProperties.SetName(toggle, plugin.Metadata.Name);
            var id = plugin.Metadata.Id;
            toggle.Toggled += (_, _) =>
            {
                if (_loading) return;
                _plugins.SetEnabled(id, toggle.IsOn);
            };
            var card = new StackPanel { Spacing = (double)Application.Current.Resources["SpaceGroup"] };
            card.Children.Add(toggle);
            card.Children.Add(new TextBlock
            {
                Text = plugin.Metadata.Summary,
                Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"],
                TextWrapping = TextWrapping.Wrap,
            });
            ExtensionsPane.Children.Add(new Border
            {
                Background = (Brush)Application.Current.Resources["ChromeRaisedBrush"],
                CornerRadius = (CornerRadius)Application.Current.Resources["RowRadius"],
                Padding = (Thickness)Application.Current.Resources["SettingsCardInset"],
                BorderThickness = new Thickness(1),
                BorderBrush = (Brush)Application.Current.Resources["ChromeStrokeBrush"],
                Child = card,
            });
        }
    }

    private void Theme_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ThemePicker.SelectedItem is not ComboBoxItem { Tag: string theme }) return;
        ShowSaveResult((AppSettings.Current with { Appearance = theme }).Save());
    }

    private void Shell_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ShellPicker.SelectedItem is not ComboBoxItem { Tag: string program }) return;
        ShowSaveResult((AppSettings.Current with { Shell = program }).Save());
    }

    private void ShowSaveResult(bool saved)
    {
        SaveProblem.Text = "Couldn't save settings. This selection applies until Tether closes.";
        SaveProblem.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
    }
}
