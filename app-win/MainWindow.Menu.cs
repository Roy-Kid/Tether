using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Input;

namespace TetherApp;

public sealed partial class MainWindow
{
    private void UpdateWorkspaceMenu() =>
        ToolTipService.SetToolTip(WorkspaceMenuButton, _zen ? "Workspace Menu · Exit Zen Mode" : "Workspace Menu");

    private void WorkspaceMenu_Click(object sender, RoutedEventArgs e) => ShowWorkspaceMenu((FrameworkElement)sender);

    private void WorkspaceMenu_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        e.Handled = true;
        ShowWorkspaceMenu((FrameworkElement)sender);
    }

    private void ShowWorkspaceMenu(FrameworkElement anchor)
    {
        var groups = new (string Name, string[] Commands)[]
        {
            ("File", ["newTab", "newTerminal", "restoreTab", "closeTab", "closeWorkspace", "closeWindow"]),
            ("Terminal", ["previousTerminal", "nextTerminal", "renameTerminal", "renameTab", "reconnect",
                "splitLeft", "splitRight", "splitUp", "splitDown", "joinGroups", "maximizePane",
                "focusLeft", "focusRight", "focusUp", "focusDown"]),
            ("View", ["commandMenu", "quickSwitch", "inspector", "toggleTabBar", "zen", "previousTab", "nextTab"]),
            ("Window", ["quickTerminal", "restoreWindow", "alwaysOnTop"]),
            ("Host", ["changeHost", "manageHosts", "manageIdentities"]),
        };
        var items = groups.Select(group => new NativeMenuItem(group.Name, Children: group.Commands.Select(MenuCommand).ToArray())).ToList();
        if (_workspace.Active is { } pane)
        {
            var plugins = App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().Where(p => App.Plugins.IsEnabled(p.Metadata.Id));
            foreach (var plugin in plugins)
            {
                var commands = new List<NativeMenuItem>
                {
                    new("Open " + plugin.Metadata.Name + " Tab", () => OpenExtensionTab(plugin.Metadata.Id),
                        Checked: _workspace.ActiveExtension?.PluginId == plugin.Metadata.Id),
                    new("Inspect " + plugin.Metadata.Name, () => ToggleInspector(plugin.Metadata.Id),
                        Checked: pane.OpenInspector == plugin.Metadata.Id),
                };
                commands.AddRange(plugin.CommandDescriptors.Select(descriptor => new NativeMenuItem(descriptor.Title, () =>
                {
                    var attachment = pane.Attach(plugin, Context(pane, plugin));
                    if (attachment.Commands.FirstOrDefault(c => c.Id == descriptor.Id) is { } command)
                        _ = RunPluginCommandAsync(command.Run);
                })));
                items.Add(new(plugin.Metadata.Name, Children: commands));
            }
        }
        items.Add(MenuCommand("settings"));
        ShowMenu(anchor, items);
    }

    private NativeMenuItem MenuCommand(string id)
    {
        var command = WorkspaceCommands.All.Single(c => c.Id == id);
        var chord = string.Join(" / ", WorkspaceCommands.Bindings(command, AppSettings.Current));
        return new(CommandTitle(command) + (chord.Length == 0 ? "" : "\t" + chord), () => _ = RunCommandAsync(id),
            CommandEnabled(id), id == "zen" && _zen || id == "alwaysOnTop" && AppSettings.Current.AlwaysOnTop);
    }

    private void ShowMenu(FrameworkElement anchor, IReadOnlyList<NativeMenuItem> items)
    {
        var point = anchor.TransformToVisual(WorkspaceRoot).TransformPoint(new(0, anchor.ActualHeight));
        var scale = WorkspaceRoot.XamlRoot?.RasterizationScale ?? 1;
        NativeContextMenu.Show(WinRT.Interop.WindowNative.GetWindowHandle(this),
            (int)(point.X * scale), (int)(point.Y * scale), items);
    }

    private void ShowTerminalMenu(FrameworkElement anchor, TerminalPane pane)
    {
        var group = _workspace.Tabs.FirstOrDefault(tab => tab.Panes.Contains(pane));
        if (group is null) return;
        _workspace.Focus(pane);
        var items = new List<NativeMenuItem>
        {
            new("New Terminal", () => _ = RunCommandAsync("newTerminal")),
            new(""),
        };
        items.AddRange(group.Panes.Select(other => new NativeMenuItem(_workspace.DisplayTitle(other), () =>
        {
            _workspace.Focus(other);
            other.Surface.FocusTerminal();
        }, Checked: other.Id == group.FocusedPane)));
        items.Add(new(""));
        foreach (var id in new[] { "splitLeft", "splitRight", "splitUp", "splitDown", "joinGroups" })
        {
            var command = WorkspaceCommands.All.Single(c => c.Id == id);
            items.Add(new(CommandTitle(command), () => _ = RunCommandAsync(id), CommandEnabled(id)));
        }
        items.Add(new(""));
        items.Add(new("Rename Terminal", () => _ = RunCommandAsync("renameTerminal")));
        items.Add(new("Close Terminal", () => _ = CloseChipAsync(pane)));
        ShowMenu(anchor, items);
    }

    private sealed class WorkspaceTabHeader : Grid
    {
        public TextBlock TitleLabel { get; } = new() { TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 144, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium };
        private readonly TextBlock _detail = new() { FontSize = 10, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 100 };
        private readonly Border _drop = new() { IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        public Button More { get; } = new()
        {
            Content = new FontIcon { Glyph = "\uE70D", FontSize = 9 },
            Style = (Style)Application.Current.Resources["ChromeIconButtonStyle"],
            MinWidth = 20, Padding = new Thickness(2),
        };

        public WorkspaceTabHeader(string name)
        {
            ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var mark = new FontIcon { Glyph = "\uE756", FontSize = 11, Margin = new Thickness(0, 0, 6, 0) };
            Children.Add(mark);
            var labels = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            TitleLabel.Text = name; labels.Children.Add(TitleLabel); labels.Children.Add(_detail);
            _detail.Visibility = Visibility.Collapsed;
            Children.Add(labels); Grid.SetColumn(labels, 1); Grid.SetColumn(More, 2); Children.Add(More);
            Children.Add(_drop); Grid.SetColumnSpan(_drop, 3);
            More.Visibility = Visibility.Collapsed;
            ToolTipService.SetToolTip(More, "Terminals"); AutomationProperties.SetName(More, "Terminals");
        }

        public void ShowDrop(SplitEdge? edge)
        {
            if (edge is null) { _drop.Visibility = Visibility.Collapsed; return; }
            _drop.Background = (Brush)Application.Current.Resources["AccentBrush"];
            _drop.Visibility = Visibility.Visible;
            var across = edge is SplitEdge.Left or SplitEdge.Right;
            _drop.Width = across ? 3 : double.NaN;
            _drop.Height = across ? double.NaN : 3;
            _drop.HorizontalAlignment = edge switch
            {
                SplitEdge.Left => HorizontalAlignment.Left,
                SplitEdge.Right => HorizontalAlignment.Right,
                _ => HorizontalAlignment.Stretch,
            };
            _drop.VerticalAlignment = edge switch
            {
                SplitEdge.Up => VerticalAlignment.Top,
                SplitEdge.Down => VerticalAlignment.Bottom,
                _ => VerticalAlignment.Stretch,
            };
        }

        public void Update(string title, string focused, bool split)
        {
            TitleLabel.Text = title;
            _detail.Text = focused;
            _detail.Visibility = split && focused != title ? Visibility.Visible : Visibility.Collapsed;
            More.Visibility = Visibility.Collapsed;
        }

        public void UpdateExtension(ExtensionTab extension)
        {
            TitleLabel.Text = extension.Title;
            _detail.Text = extension.Subtitle;
            _detail.Visibility = string.IsNullOrWhiteSpace(extension.Subtitle) ? Visibility.Collapsed : Visibility.Visible;
            More.Visibility = Visibility.Collapsed;
        }
    }
}
