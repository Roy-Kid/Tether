using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TetherApp;

public sealed partial class MainWindow
{
    private void UpdateWorkspaceMenu() =>
        ToolTipService.SetToolTip(WorkspaceMenuButton, _zen ? "Workspace Menu · Exit Zen Mode" : "Workspace Menu");

    private void WorkspaceMenu_Click(object sender, RoutedEventArgs e)
    {
        var groups = new (string Name, string[] Commands)[]
        {
            ("File", ["newTab", "newTerminal", "restoreTab", "closeTab", "closeWorkspace", "closeWindow"]),
            ("Terminal", ["previousTerminal", "nextTerminal", "renameTerminal", "renameTab", "reconnect",
                "splitRight", "splitDown", "joinGroups", "maximizePane", "focusLeft", "focusRight", "focusUp", "focusDown"]),
            ("View", ["commandMenu", "quickSwitch", "inspector", "toggleTabBar", "zen", "previousTab", "nextTab"]),
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
        ShowMenu(WorkspaceMenuButton, items);
    }

    private NativeMenuItem MenuCommand(string id)
    {
        var command = WorkspaceCommands.All.Single(c => c.Id == id);
        var chord = string.Join(" / ", WorkspaceCommands.Bindings(command, AppSettings.Current));
        return new(CommandTitle(command) + (chord.Length == 0 ? "" : "\t" + chord), () => _ = RunCommandAsync(id),
            WorkspaceCommands.IsEnabled(id, CommandState), id == "zen" && _zen);
    }

    private void ShowMenu(FrameworkElement anchor, IReadOnlyList<NativeMenuItem> items)
    {
        var point = anchor.TransformToVisual(WorkspaceRoot).TransformPoint(new(0, anchor.ActualHeight));
        var scale = WorkspaceRoot.XamlRoot?.RasterizationScale ?? 1;
        NativeContextMenu.Show(WinRT.Interop.WindowNative.GetWindowHandle(this),
            (int)(point.X * scale), (int)(point.Y * scale), items);
    }

    private void ShowTabMenu(FrameworkElement anchor, Tab group)
    {
        var items = group.Panes.Select(pane => new NativeMenuItem(pane.Title, () =>
        {
            _workspace.Activate(group);
            _workspace.Focus(pane);
            pane.Surface.FocusTerminal();
        }, Checked: pane.Id == group.FocusedPane)).ToList();
        items.Add(new(""));
        foreach (var id in new[] { "newTerminal", "renameTab", "closeWorkspace" })
        {
            var command = WorkspaceCommands.All.Single(c => c.Id == id);
            items.Add(new(command.Title, () => { _workspace.Activate(group); _ = RunCommandAsync(id); }));
        }
        ShowMenu(anchor, items);
    }

    private sealed class WorkspaceTabHeader : Grid
    {
        public TextBlock TitleLabel { get; } = new() { TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180, FontSize = 12 };
        private readonly TextBlock _detail = new() { FontSize = 10, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180 };
        public Button More { get; } = new()
        {
            Content = new FontIcon { Glyph = "\uE70D", FontSize = 9 },
            Style = (Style)Application.Current.Resources["ChromeIconButtonStyle"],
            MinWidth = 20, Padding = new Thickness(2),
        };

        public WorkspaceTabHeader(string name)
        {
            ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            TitleLabel.Text = name; labels.Children.Add(TitleLabel); labels.Children.Add(_detail);
            _detail.Visibility = Visibility.Collapsed;
            Children.Add(labels); Grid.SetColumn(More, 1); Children.Add(More);
            ToolTipService.SetToolTip(More, "Terminals"); AutomationProperties.SetName(More, "Terminals");
        }

        public void Update(Tab group)
        {
            TitleLabel.Text = group.Title;
            _detail.Text = group.Focused.Title;
            _detail.Visibility = group.Panes.Count > 1 && group.Focused.Title != group.Title ? Visibility.Visible : Visibility.Collapsed;
            More.Visibility = Visibility.Visible;
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
