using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TetherApp.Plugins;

namespace TetherApp;

public sealed partial class SettingsWindow : Window
{
    private static SettingsWindow? _current;
    public static void ShowFor(PluginRegistry plugins, string? section = null)
    {
        if (_current is null)
        {
            _current = new SettingsWindow(plugins);
            _current.Closed += (_, _) => _current = null;
        }
        if (section is not null)
            _current.SettingsRoot.SelectedItem = _current.SettingsRoot.MenuItems.OfType<NavigationViewItem>()
                .FirstOrDefault(item => item.Tag as string == section);
        _current.Activate();
    }
    private bool _loading = true;
    private readonly PluginRegistry? _plugins;

    public SettingsWindow() : this(null) { }

    public SettingsWindow(PluginRegistry? plugins)
    {
        _plugins = plugins;
        InitializeComponent();
        AppBranding.Apply(this);
        SystemBackdrop = new MicaBackdrop();
        BuildExtensions();
        BuildTerminal();
        BuildWorkspaceSettings();
        BuildSecurity();
        IdentitiesPane.Children.Add(new TextBlock { Text = "Manage account identities, SSH keys, passwords, TOTP and authentication confirmation policies.", TextWrapping = TextWrapping.Wrap });
        var identities = new Button { Content = "Manage Identities" };
        identities.Click += async (_, _) => { try { await IdentityManager.ShowAsync(SettingsRoot.ActualTheme); } catch (Exception ex) { SaveProblem.Text = ex.Message; } };
        IdentitiesPane.Children.Add(identities);
        foreach (var profile in AppSettings.KnownShells)
            ShellPicker.Items.Add(new ComboBoxItem { Content = profile.Name, Tag = profile.Program });
        BuildSshPicker();
        BuildWslPicker();
        // Preserve existing custom program preferences instead of silently replacing them.
        if (!AppSettings.KnownShells.Any(profile => profile.Program == AppSettings.Current.Shell))
            ShellPicker.Items.Add(new ComboBoxItem { Content = AppSettings.Current.Shell, Tag = AppSettings.Current.Shell });
        ShellPicker.SelectedItem = ShellPicker.Items.Cast<ComboBoxItem>()
            .First(item => (string)item.Tag == AppSettings.Current.Shell);
        LastTabPicker.SelectedItem = LastTabPicker.Items.Cast<ComboBoxItem>()
            .FirstOrDefault(item => (string)item.Tag == AppSettings.Current.CloseLastTab) ?? LastTabPicker.Items[0];
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
        var background = ((SolidColorBrush)Application.Current.Resources["ChromeWindowBrush"]).Color;
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
        if (StartupPane is null || AppearancePane is null || ExtensionsPane is null || TerminalPane is null) return;
        var tag = (e.SelectedItem as NavigationViewItem)?.Tag as string;
        PageHeading.Text = tag switch
        {
            "terminal" => "Terminal", "appearance" => "Appearance", "extensions" => "Extensions",
            "keys" => "Key Bindings", "history" => "History", "security" => "Security",
            "files" => "Files", "identities" => "Identities", _ => "Startup",
        };
        StartupPane.Visibility = tag is null or "startup" ? Visibility.Visible : Visibility.Collapsed;
        SshPane.Visibility = StartupPane.Visibility;
        AppearancePane.Visibility = tag == "appearance" ? Visibility.Visible : Visibility.Collapsed;
        TerminalPane.Visibility = tag == "terminal" ? Visibility.Visible : Visibility.Collapsed;
        ExtensionsPane.Visibility = tag == "extensions" ? Visibility.Visible : Visibility.Collapsed;
        KeysPane.Visibility = tag == "keys" ? Visibility.Visible : Visibility.Collapsed;
        HistoryPane.Visibility = tag == "history" ? Visibility.Visible : Visibility.Collapsed;
        SecurityPane.Visibility = tag == "security" ? Visibility.Visible : Visibility.Collapsed;
        FilesPane.Visibility = tag == "files" ? Visibility.Visible : Visibility.Collapsed;
        IdentitiesPane.Visibility = tag == "identities" ? Visibility.Visible : Visibility.Collapsed;
        if (tag == "security") BuildSecurity();
    }

    private void LastTab_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || LastTabPicker.SelectedItem is not ComboBoxItem { Tag: string value }) return;
        ShowSaveResult((AppSettings.Current with { CloseLastTab = value }).Save());
    }

    private void BuildSecurity()
    {
        SecurityPane.Children.Clear();
        var known = new Tether.KnownHosts();
        SecurityPane.Children.Add(new TextBlock { Text = "Trusted host keys", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        SecurityPane.Children.Add(new TextBlock
        {
            Text = "Keys accepted when connecting. Forgetting one asks again on the next connection.",
            Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"],
            TextWrapping = TextWrapping.Wrap,
        });
        var trusted = known.Trusted();
        if (trusted.Count == 0)
            SecurityPane.Children.Add(new TextBlock { Text = "None", Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"] });
        foreach (var entry in trusted)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var labels = new StackPanel { Spacing = 2 };
            labels.Children.Add(new TextBlock { Text = entry.Endpoint, TextWrapping = TextWrapping.Wrap });
            labels.Children.Add(new TextBlock
            {
                Text = entry.Algorithm + " " + entry.Fingerprint,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 12,
                Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"],
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
            row.Children.Add(labels);
            var forget = new Button { Content = "Forget", Tag = entry.Endpoint };
            forget.Click += async (_, _) =>
            {
                if (await Alerts.ContentAsync("Forget " + entry.Endpoint + "?",
                    "You’ll be asked to trust this host again when connecting.", "Forget", null,
                    SettingsRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
                known.ForgetEndpoint(entry.Endpoint);
                BuildSecurity();
            };
            Grid.SetColumn(forget, 1);
            row.Children.Add(forget);
            SecurityPane.Children.Add(row);
        }

        SecurityPane.Children.Add(new TextBlock
        {
            Text = "Saved passwords",
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            Margin = new Thickness(0, 12, 0, 0),
        });
        SecurityPane.Children.Add(new TextBlock
        {
            Text = "Password identities stored for this Windows account. Delete removes the identity and its encrypted secret.",
            Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"],
            TextWrapping = TextWrapping.Wrap,
        });
        try
        {
            var passwords = IdentityStore.Current.Identities.Where(i => i.Method == AuthenticationMethod.Password).ToArray();
            if (passwords.Length == 0)
                SecurityPane.Children.Add(new TextBlock { Text = "None", Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"] });
            foreach (var identity in passwords)
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new TextBlock { Text = identity.Name, VerticalAlignment = VerticalAlignment.Center });
                var delete = new Button { Content = "Delete" };
                delete.Click += async (_, _) =>
                {
                    try
                    {
                        if (await Alerts.ContentAsync("Delete " + identity.Name + "?",
                            "This removes the saved password identity.", "Delete", null,
                            SettingsRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
                        IdentityStore.Current.Delete(identity.Id);
                        BuildSecurity();
                    }
                    catch (Exception ex) { SaveProblem.Text = ex.Message; SaveProblem.Visibility = Visibility.Visible; }
                };
                Grid.SetColumn(delete, 1);
                row.Children.Add(delete);
                SecurityPane.Children.Add(row);
            }
        }
        catch (Exception ex)
        {
            SecurityPane.Children.Add(new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"] });
        }
    }

    private async void BuildTerminal()
    {
        TerminalPane.Children.Clear();
        var preferences = AppSettings.Current.Terminal;
        var scheme = new ComboBox { Header = "Color scheme", HorizontalAlignment = HorizontalAlignment.Stretch };
        scheme.Items.Add(new ComboBoxItem { Content = "Soft", Tag = "soft" });
        scheme.Items.Add(new ComboBoxItem { Content = "Classic", Tag = "classic" });
        scheme.SelectedIndex = preferences.ColorScheme == "classic" ? 1 : 0;
        TerminalPane.Children.Add(scheme);
        var family = new ComboBox { Header = "Terminal font", HorizontalAlignment = HorizontalAlignment.Stretch };
        var wideFamily = new ComboBox { Header = "CJK / wide-character font", HorizontalAlignment = HorizontalAlignment.Stretch };
        family.Items.Add(preferences.FontFamily);
        wideFamily.Items.Add(preferences.WideFontFamily);
        family.SelectedItem = preferences.FontFamily;
        wideFamily.SelectedItem = preferences.WideFontFamily;
        TerminalPane.Children.Add(family);
        TerminalPane.Children.Add(wideFamily);
        var preview = new TextBlock { Text = "AaBb 0123  → ┌─┐  中文测试 日本語 한글", FontSize = preferences.FontSize, TextWrapping = TextWrapping.Wrap };
        void Preview()
        {
            preview.FontFamily = new FontFamily($"{family.SelectedItem}, {wideFamily.SelectedItem}");
        }
        Preview();
        TerminalPane.Children.Add(preview);
        family.SelectionChanged += (_, _) => Preview();
        wideFamily.SelectionChanged += (_, _) => Preview();
        var size = new NumberBox { Header = "Font size", Minimum = 10, Maximum = 32, Value = preferences.FontSize, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        size.ValueChanged += (_, _) =>
        {
            if (double.IsFinite(size.Value) && size.Value is >= 10 and <= 32) preview.FontSize = size.Value;
        };
        var threshold = new NumberBox { Header = "Confirm paste at character count", Minimum = 1, Maximum = 1000000, Value = preferences.PasteThreshold };
        TerminalPane.Children.Add(size);
        var inset = new NumberBox { Header = "Terminal padding", Minimum = 0, Maximum = 40, Value = preferences.Inset, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        TerminalPane.Children.Add(inset);
        TerminalPane.Children.Add(threshold);
        TerminalPane.Children.Add(new TextBlock { Text = "Multi-line pastes always ask. Shortcuts use Ctrl or Alt, optional Shift, and a letter, digit, Equals or Minus.", TextWrapping = TextWrapping.Wrap });
        var fields = new List<TextBox>();
        foreach (var (name, chord) in preferences.Bindings)
        {
            var field = new TextBox { Header = name, Text = chord };
            fields.Add(field);
            TerminalPane.Children.Add(field);
        }
        var problem = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var apply = new Button { Content = "Apply" };
        apply.Click += (_, _) =>
        {
            var updated = new TerminalPreferences
            {
                FontFamily = (string)family.SelectedItem, WideFontFamily = (string)wideFamily.SelectedItem,
                FontSize = size.Value,
                Inset = inset.Value, ColorScheme = (string)((ComboBoxItem)scheme.SelectedItem).Tag,
                PasteThreshold = double.IsFinite(threshold.Value) ? (int)threshold.Value : 0,
                Copy = fields[0].Text, Paste = fields[1].Text, ZoomIn = fields[2].Text,
                ZoomOut = fields[3].Text, ZoomReset = fields[4].Text,
            };
            problem.Text = updated.Validate() ?? WorkspaceCommands.Validate(AppSettings.Current.KeyBindings, updated) ?? "";
            if (problem.Text.Length == 0) ShowSaveResult((AppSettings.Current with { Terminal = updated }).Save());
        };
        var reset = new Button { Content = "Restore terminal defaults" };
        reset.Click += (_, _) =>
        {
            ShowSaveResult((AppSettings.Current with { Terminal = new() }).Save());
            BuildTerminal();
        };
        TerminalPane.Children.Add(problem);
        TerminalPane.Children.Add(apply);
        TerminalPane.Children.Add(reset);
        void SaveFonts()
        {
            if (family.SelectedItem is not string primary || wideFamily.SelectedItem is not string wide) return;
            ShowSaveResult((AppSettings.Current with { Terminal = AppSettings.Current.Terminal with
                { FontFamily = primary, WideFontFamily = wide } }).Save());
        }
        try
        {
            var fonts = await Task.Run(Tether.TerminalSurface.FontFamilies);
            foreach (var name in fonts)
            {
                if (!family.Items.Contains(name)) family.Items.Add(name);
                if (!wideFamily.Items.Contains(name)) wideFamily.Items.Add(name);
            }
            family.SelectionChanged += (_, _) => SaveFonts();
            wideFamily.SelectionChanged += (_, _) => SaveFonts();
        }
        catch (Exception ex) { problem.Text = "Couldn't list installed fonts: " + ex.Message; }

    }

    private void BuildExtensions()
    {
        ExtensionsPane.Children.Clear();
        if (_plugins is not null)
        {
            var install = EditorDialog.Icon("\uE8B5", "Install web plugin", async () =>
            {
                try
                {
                    if (await PickPluginFolderAsync() is not { } folder) return;
                    var package = WebPluginPackage.Read(folder);
                    var access = string.Join("\n", package.Manifest.NetworkOrigins ?? []);
                    if (await Alerts.ContentAsync("Install " + package.Manifest.Name + "?", access, "Install", null,
                        SettingsRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
                    WebPluginCatalog.Install(folder, _plugins); BuildExtensions();
                }
                catch (Exception ex) { SaveProblem.Text = ex.Message; SaveProblem.Visibility = Visibility.Visible; }
            });
            ExtensionsPane.Children.Add(install);
            foreach (var problem in WebPluginCatalog.Problems)
                ExtensionsPane.Children.Add(new TextBlock { Text = problem, TextWrapping = TextWrapping.Wrap });
        }
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
            var web = plugin as WebPlugin;
            var installed = web is not null ? WebPluginCatalog.Installed(plugin.Metadata.Id) : null;
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
            if (installed is not null)
            {
                card.Children.Add(new TextBlock
                {
                    Text = installed.Manifest.Publisher + " · " + installed.Manifest.Version,
                    Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"],
                    TextWrapping = TextWrapping.Wrap,
                });
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                var update = new Button { Content = "Update…" };
                update.Click += async (_, _) =>
                {
                    try
                    {
                        if (await PickPluginFolderAsync() is not { } folder) return;
                        var package = WebPluginPackage.Read(folder);
                        if (package.Manifest.Id != id)
                        {
                            SaveProblem.Text = "That package’s id does not match " + id + ".";
                            SaveProblem.Visibility = Visibility.Visible;
                            return;
                        }
                        var detail = installed.Manifest.Version + " → " + package.Manifest.Version;
                        if (await Alerts.ContentAsync("Update " + package.Manifest.Name + "?", detail, "Update", null,
                            SettingsRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
                        WebPluginCatalog.Update(folder, _plugins); BuildExtensions();
                    }
                    catch (Exception ex) { SaveProblem.Text = ex.Message; SaveProblem.Visibility = Visibility.Visible; }
                };
                var uninstall = new Button { Content = "Uninstall" };
                uninstall.Click += async (_, _) =>
                {
                    try
                    {
                        if (await Alerts.ContentAsync("Uninstall " + plugin.Metadata.Name + "?",
                            "Removes the package from this device and closes its tabs.", "Uninstall", null,
                            SettingsRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
                        WebPluginCatalog.Uninstall(id, _plugins); BuildExtensions();
                    }
                    catch (Exception ex) { SaveProblem.Text = ex.Message; SaveProblem.Visibility = Visibility.Visible; }
                };
                actions.Children.Add(update);
                actions.Children.Add(uninstall);
                card.Children.Add(actions);
            }
            ExtensionsPane.Children.Add(new Border
            {
                Style = (Style)Application.Current.Resources["SettingsCardStyle"],
                Child = card,
            });
        }
    }

    private async Task<string?> PickPluginFolderAsync()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (await picker.PickSingleFolderAsync())?.Path;
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

    private void BuildSshPicker()
    {
        SshPicker.Items.Clear();
        foreach (var client in AppSettings.KnownSshPrograms())
            SshPicker.Items.Add(new ComboBoxItem { Content = client.Name, Tag = client.Path });
        var current = AppSettings.ResolveSshProgram();
        SshPathBox.Text = current;
        var match = SshPicker.Items.Cast<ComboBoxItem>().FirstOrDefault(item =>
            string.Equals((string)item.Tag, current, StringComparison.OrdinalIgnoreCase));
        if (match is null)
        {
            match = new ComboBoxItem { Content = "Custom", Tag = current };
            SshPicker.Items.Add(match);
        }
        SshPicker.SelectedItem = match;
        ShowSshPathProblem(current);
    }

    private void Ssh_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || SshPicker.SelectedItem is not ComboBoxItem { Tag: string path }) return;
        if (string.Equals(SshPathBox.Text.Trim(), path, StringComparison.OrdinalIgnoreCase)) return;
        SshPathBox.Text = path;
        SaveSshProgram(path);
    }

    private void SshPath_LostFocus(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var path = SshPathBox.Text.Trim();
        if (string.Equals(path, AppSettings.ResolveSshProgram(), StringComparison.OrdinalIgnoreCase)) return;
        SaveSshProgram(path);
        BuildSshPicker();
    }

    private async void SshBrowse_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".exe");
        picker.SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.ComputerFolder;
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        SshPathBox.Text = file.Path;
        SaveSshProgram(file.Path);
        BuildSshPicker();
    }

    private void SaveSshProgram(string path)
    {
        // An explicit system path and a blank setting resolve to the same file.
        // Store what the person pointed at.
        ShowSaveResult((AppSettings.Current with { SshProgram = path }).Save());
        ShowSshPathProblem(path);
    }

    private void ShowSshPathProblem(string path)
    {
        var missing = path is not "ssh" && !File.Exists(path);
        SshPathProblem.Text = missing ? "That file was not found." : "";
        SshPathProblem.Visibility = missing ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowSaveResult(bool saved)
    {
        SaveProblem.Text = "Couldn't save settings. This selection applies until Tether closes.";
        SaveProblem.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
    }
}
