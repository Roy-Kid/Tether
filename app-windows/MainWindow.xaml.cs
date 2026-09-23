// The macOS shape, in the same order and the same sizes
// (`WorkspaceChrome.swift`, `Chrome.swift`):
//
//   WorkspaceTabBar  36   top,    sidebar surface, bottom divider
//   canvas           *    middle, 12pt inset
//   HostStatusBar    24   bottom, sidebar surface, top divider
//
// Terminal tabs carry no symbol and no global + or close: the close box
// lives on the chip and appears under the pointer. New Terminal is Ctrl+N,
// Close Tab is Ctrl+W — the menu equivalents of Cmd+N / Cmd+W.

using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Tether;

namespace TetherApp;

public sealed partial class MainWindow : Window
{
    private const double TabHeight = 36;
    private const double TabTitleWidth = 180;
    private const double CloseWidth = 18;

    private readonly Workspace _workspace = new();

    public MainWindow()
    {
        InitializeComponent();
        AppSettings.Load();
        _workspace.Changed += OnWorkspaceChanged;
        Content.KeyDown += OnKeyDown;
        // Activation hands focus back to the XAML island; the terminal's
        // input window is where typing goes.
        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated)
            {
                _workspace.Active?.Surface.FocusTerminal();
            }
        };
        _ = OpenFirstTabAsync();
    }

    private async Task OpenFirstTabAsync()
    {
        await _workspace.AddAsync();
    }

    /// <summary>
    /// Rebuilds the tab strip and swaps the active surface in. The strip is
    /// a row of chips (WorkspaceTabBar.tabChip): title, and a close box that
    /// appears under the pointer or on the selected tab. The close space is
    /// held whether or not the cross is drawn, so a tab does not grow under
    /// the pointer and push the strip along.
    /// </summary>
    private void OnWorkspaceChanged()
    {
        TabStrip.Children.Clear();
        for (var i = 0; i < _workspace.Tabs.Count; i++)
        {
            TabStrip.Children.Add(BuildChip(_workspace.Tabs[i], i == _workspace.ActiveIndex, i));
        }

        if (_workspace.Active is { } current)
        {
            TerminalHostPlaceholder.Children.Clear();
            TerminalHostPlaceholder.Children.Add(current.Surface);
        }

        RefreshStatusBar();
    }

    private UIElement BuildChip(Tab tab, bool selected, int index)
    {
        var title = new TextBlock
        {
            Text = tab.Title,
            FontSize = 12,
            Foreground = BrushOf(selected ? "ChromeTextBrush" : "ChromeSubtleBrush"),
            MaxWidth = TabTitleWidth,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var close = new Button
        {
            Width = CloseWidth,
            Height = TabHeight,
            Padding = new Thickness(0),
            Margin = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Content = new FontIcon
            {
                Glyph = "",
                FontSize = 10,
                Foreground = BrushOf("ChromeSubtleBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            },
            Opacity = selected ? 1 : 0,
            IsHitTestVisible = selected,
        };
        ToolTipService.SetToolTip(close, "Close tab");
        AutomationProperties.SetName(close, "Close " + tab.Title);
        var captured = index;
        close.Click += async (_, _) =>
        {
            await _workspace.CloseAsync(captured);
            if (_workspace.Tabs.Count == 0) await _workspace.AddAsync();
        };

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(title);
        row.Children.Add(close);

        var chip = new Grid
        {
            Height = TabHeight,
            MinWidth = 0,
            Padding = new Thickness(10, 0, 4, 0),
            MaxWidth = TabTitleWidth + CloseWidth + 24,
            Background = selected
                ? BrushOf("ChromeRaisedBrush")
                : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        chip.Children.Add(row);

        // The 2pt accent rule along the chip's bottom edge is how the
        // selection reads without a second titlebar (WorkspaceTabBar).
        if (selected)
        {
            chip.Children.Add(new Rectangle
            {
                Height = 2,
                Fill = BrushOf("AccentBrush"),
                VerticalAlignment = VerticalAlignment.Bottom,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            });
        }

        ToolTipService.SetToolTip(chip, tab.Title);
        chip.PointerEntered += (_, _) =>
        {
            close.Opacity = 1;
            close.IsHitTestVisible = true;
        };
        chip.PointerExited += (_, _) =>
        {
            if (!selected)
            {
                close.Opacity = 0;
                close.IsHitTestVisible = false;
            }
        };
        var pick = index;
        chip.PointerPressed += (_, _) => _workspace.Select(pick);
        return chip;
    }

    /// <summary>
    /// The 24pt host switcher and connection status (HostStatusBar): the
    /// host control leads, the status mark follows, settings is on the
    /// trailing edge. Silence is the connected state.
    /// </summary>
    private void RefreshStatusBar()
    {
        var model = _workspace.Active?.Model;
        var title = _workspace.Active?.Title ?? "localhost";
        var hasHost = title.Length > 0 && title != "localhost";
        HostName.Text = hasHost ? title : "Choose host";
        ToolTipService.SetToolTip(
            HostButton,
            model?.LastError is { } err && err.Length > 0 ? err : HostName.Text);

        var live = model?.CurrentFrame is not null;
        StatusDot.Fill = BrushOf(live ? "AccentBrush" : "ChromeSubtleBrush");

        StatusMark.Children.Clear();
    }

    /// <summary>
    /// A theme brush. `Resources[key]` does not walk `ThemeDictionaries`, so
    /// a lookup that way returns null and every colour falls back to
    /// transparent — which is how a dark terminal becomes a white window.
    /// </summary>
    private static SolidColorBrush BrushOf(string key)
    {
        var themed = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries["Default"];
        return themed[key] as SolidColorBrush
            ?? new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }

    /// <summary>
    /// The host control is the picker (HostStatusBar → HostPicker). The
    /// list is `~/.ssh/config` and nothing else (Decisions/0009).
    /// </summary>
    private void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (HostPickerPanel.Visibility == Visibility.Visible)
        {
            HostPickerPanel.Visibility = Visibility.Collapsed;
            return;
        }
        HostPickerPanel.Visibility = Visibility.Visible;
        ReloadHostPicker();
        HostQuery.Focus(FocusState.Programmatic);
    }

    private void HostQuery_Changed(object sender, TextChangedEventArgs e) => ReloadHostPicker();

    private void ReloadHostPicker()
    {
        var all = SshConfig.Load();
        var matches = SshConfig.Filter(all, HostQuery.Text);
        HostList.ItemsSource = matches;
        HostProblem.Visibility = matches.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        HostProblem.Text = all.Count == 0
            ? "No hosts in ~/.ssh/config."
            : "No matching hosts.";
    }

    private async void Host_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not HostEntry host) return;
        HostPickerPanel.Visibility = Visibility.Collapsed;
        await OpenHostAsync(host);
    }

    private async Task OpenHostAsync(HostEntry host)
    {
        if (_workspace.Active is not { } tab) return;

        tab.Title = host.Alias;
        OnWorkspaceChanged();

        var prompter = new SessionModel.PromptDialog(Content.XamlRoot);
        var destination = new Destination(
            host.HostName,
            host.Port ?? 22,
            host.User ?? Environment.UserName);
        // An `IdentityFile` in the ssh config is already a credential, so a
        // password is not required to start the handshake — the same thing
        // `ssh host` does (HostStore.swift).
        var secrets = host.IdentityFile is { Length: > 0 } key
            ? new Secret[] { new Secret.PrivateKey(File.ReadAllText(key)), new Secret.Interactive(prompter) }
            : new Secret[] { new Secret.Interactive(prompter) };

        var ok = await tab.Model.ConnectAsync(Content.XamlRoot, destination, secrets);
        if (!ok) tab.Title = "localhost";
        OnWorkspaceChanged();
    }

    private void AddHost_Click(object sender, RoutedEventArgs e)
    {
        // `HostStore` on the Mac edits `~/.ssh/config` in place. The editor
        // is the next step; the button is the same control and the same
        // place it is on that picker.
    }

    private void ManageHosts_Click(object sender, RoutedEventArgs e)
    {
        HostPickerPanel.Visibility = Visibility.Collapsed;
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        // The same control as on macOS: it opens preferences. A window with
        // a sidebar is the Windows shape of `NavigationSplitView`.
        _ = new SettingsWindow();
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = InputKeyboardSource
            .GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

        if (control && e.Key == Windows.System.VirtualKey.N)
        {
            _ = _workspace.AddAsync();
            e.Handled = true;
            return;
        }
        if (control && e.Key == Windows.System.VirtualKey.W)
        {
            _ = CloseSelectedAsync();
            e.Handled = true;
        }
    }

    private async Task CloseSelectedAsync()
    {
        await _workspace.CloseAsync(_workspace.ActiveIndex);
        if (_workspace.Tabs.Count == 0) await _workspace.AddAsync();
    }
}
