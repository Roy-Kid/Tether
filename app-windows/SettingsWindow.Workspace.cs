using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TetherApp;

public sealed partial class SettingsWindow
{
    private void BuildWorkspaceSettings()
    {
        KeysPane.Children.Clear(); HistoryPane.Children.Clear(); FilesPane.Children.Clear();
        if (AppearancePane.Child is StackPanel appearance && !appearance.Children.OfType<ComboBox>().Any(c => c.Tag as string == "tab-layout"))
        {
            var layout = new ComboBox { Header = "Tab layout", Tag = "tab-layout", HorizontalAlignment = HorizontalAlignment.Stretch };
            layout.Items.Add("Horizontal"); layout.Items.Add("Vertical");
            layout.SelectedIndex = AppSettings.Current.TabLayout == "vertical" ? 1 : 0;
            layout.SelectionChanged += (_, _) => ShowSaveResult((AppSettings.Current with { TabLayout = layout.SelectedIndex == 1 ? "vertical" : "horizontal" }).Save());
            appearance.Children.Add(layout);
        }
        var search = new TextBox { PlaceholderText = "Find a command or shortcut…" };
        KeysPane.Children.Add(search);
        var fields = new Dictionary<string, TextBox>();
        var catalog = WorkspaceCommands.All.ToList();
        foreach (var plugin in _plugins?.Plugins ?? [])
        {
            catalog.Add(new("plugin." + plugin.Metadata.Id + ".launch", "Open " + plugin.Metadata.Name, ""));
            catalog.AddRange(plugin.CommandDescriptors.Select(c => new WorkspaceCommand("plugin." + plugin.Metadata.Id + ".command." + c.Id, c.Title, "")));
        }
        foreach (var command in catalog)
        {
            var field = new TextBox { Header = command.Title, Text = WorkspaceCommands.Binding(command, AppSettings.Current) };
            fields[command.Id] = field;
            KeysPane.Children.Add(field);
        }
        search.TextChanged += (_, _) =>
        {
            foreach (var field in fields.Values)
                field.Visibility = (field.Header + " " + field.Text).Contains(search.Text, StringComparison.OrdinalIgnoreCase) ? Visibility.Visible : Visibility.Collapsed;
        };
        var problem = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var apply = new Button { Content = "Apply" };
        apply.Click += (_, _) =>
        {
            var bindings = fields.ToDictionary(p => p.Key, p => p.Value.Text.Trim());
            problem.Text = WorkspaceCommands.Validate(bindings, AppSettings.Current.Terminal) ?? "";
            if (problem.Text.Length == 0) ShowSaveResult((AppSettings.Current with { KeyBindings = bindings }).Save());
        };
        var reset = new Button { Content = "Restore defaults" };
        reset.Click += (_, _) => { ShowSaveResult((AppSettings.Current with { KeyBindings = new() }).Save()); BuildWorkspaceSettings(); };
        KeysPane.Children.Add(problem); KeysPane.Children.Add(apply); KeysPane.Children.Add(reset);

        var lines = new NumberBox { Header = "History lines per session", Minimum = 1, Maximum = 10_000_000, Value = AppSettings.Current.HistoryLines };
        var unlimited = new ToggleSwitch { Header = "Unlimited history", IsOn = AppSettings.Current.UnlimitedHistory };
        var saveHistory = new Button { Content = "Apply to new sessions" };
        saveHistory.Click += (_, _) =>
        {
            if (!double.IsFinite(lines.Value) || lines.Value < 1) return;
            ShowSaveResult((AppSettings.Current with { HistoryLines = (ulong)lines.Value, UnlimitedHistory = unlimited.IsOn }).Save());
        };
        HistoryPane.Children.Add(lines); HistoryPane.Children.Add(unlimited); HistoryPane.Children.Add(saveHistory);

        var megabytes = new NumberBox { Header = "Ask before opening remote files above (MB)", Minimum = 0, Maximum = 1_000_000, Value = AppSettings.Current.FilesPromptMegabytes };
        var directory = new TextBox { Header = "Download folder (empty means ask each time)", Text = AppSettings.Current.DownloadDirectory };
        var saveFiles = new Button { Content = "Apply" };
        saveFiles.Click += (_, _) =>
        {
            if (!double.IsFinite(megabytes.Value) || megabytes.Value < 0) return;
            if (!string.IsNullOrWhiteSpace(directory.Text) && !Directory.Exists(directory.Text))
            { SaveProblem.Text = "Choose an existing folder."; SaveProblem.Visibility = Visibility.Visible; return; }
            ShowSaveResult((AppSettings.Current with { FilesPromptMegabytes = (ulong)megabytes.Value, DownloadDirectory = directory.Text.Trim() }).Save());
        };
        FilesPane.Children.Add(megabytes); FilesPane.Children.Add(directory); FilesPane.Children.Add(saveFiles);
    }
}
