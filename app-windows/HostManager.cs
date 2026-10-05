using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using System.Text.RegularExpressions;

namespace TetherApp;

internal static class HostManager
{
    private sealed record Row(HostEntry Host) { public override string ToString() => Host.Label + " — " + Host.Target; }
    private sealed record IdentityRow(Guid? Id, string Name) { public override string ToString() => Name; }
    public static async Task ShowAsync(ElementTheme theme, Func<HostEntry, SessionModel?> connection, Func<HostEntry, Task> connect)
    {
        var panel = new StackPanel { Spacing = 12 };
        var query = new TextBox { PlaceholderText = "Find a host…" };
        var list = new ListView { Height = 350, SelectionMode = ListViewSelectionMode.Single };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var busy = false;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var moreMenu = new MenuFlyout();
        var contextMenu = new MenuFlyout();
        var selectionCommands = new List<MenuFlyoutItem>();
        var newHost = new Button
        {
            Content = new FontIcon { Glyph = "\uE710", FontSize = 16 },
            Width = 32, Height = 32, Padding = new Thickness(6),
            Style = (Style)Application.Current.Resources["AccentButtonStyle"]
        };
        var more = new Button
        {
            Content = new FontIcon { Glyph = "\uE712", FontSize = 16 },
            Width = 32, Height = 32, Padding = new Thickness(6), Flyout = moreMenu
        };
        ToolTipService.SetToolTip(newHost, "New host");
        ToolTipService.SetToolTip(more, "More actions");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(newHost, "New host");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, "More actions");
        buttons.Children.Add(newHost); buttons.Children.Add(more);
        void UpdateCommands()
        {
            foreach (var item in selectionCommands) item.IsEnabled = !busy && list.SelectedItem is Row;
            newHost.IsEnabled = more.IsEnabled = !busy;
        }
        void AddCommand(string glyph, string label, Func<Task> action, bool needsHost = false, bool contextual = false)
        {
            MenuFlyoutItem Item()
            {
                var item = new MenuFlyoutItem { Text = label, Icon = new FontIcon { Glyph = glyph } };
                item.Click += async (_, _) => await Run(action);
                if (needsHost) selectionCommands.Add(item);
                return item;
            }
            moreMenu.Items.Add(Item());
            if (contextual) contextMenu.Items.Add(Item());
        }
        void Reload(string? alias = null)
        {
            list.ItemsSource = SshConfig.Filter(SshConfig.Load(), query.Text).Select(h => new Row(h)).ToArray();
            list.SelectedItem = list.Items.Cast<Row>().FirstOrDefault(r => r.Host.Alias == alias) ?? list.Items.Cast<Row>().FirstOrDefault();
        }
        async Task Run(Func<Task> action)
        {
            if (busy) return; busy = true; UpdateCommands();
            try { error.Text = ""; await action(); } catch (Exception ex) { error.Text = ex.Message; }
            finally { busy = false; UpdateCommands(); }
        }
        newHost.Click += async (_, _) => await Run(async () => { if (await EditAsync(null) is { } alias) Reload(alias); });
        AddCommand("\uE8A7", "Connect", async () => { if (list.SelectedItem is Row row) await connect(row.Host); }, true, true);
        AddCommand("\uE70F", "Edit host", async () => { if (list.SelectedItem is Row row && await EditAsync(row.Host) is { } alias) Reload(alias); }, true, true);
        AddCommand("\uE74D", "Delete host", async () =>
        {
            if (list.SelectedItem is not Row row || await Alerts.ContentAsync("Delete Host?", row.Host.Label, "Delete", null, theme, _ => { }) != ContentDialogResult.Primary) return;
            var original = ReadConfig();
            SshConfigEditor.Save(original, SshConfigEditor.Update(original, row.Host.Alias, null)); IdentityStore.Current.Unbind(row.Host.Alias); Reload();
        }, true, true);
        moreMenu.Items.Add(new MenuFlyoutSeparator());
        AddCommand("\uE8B5", "Import SSH config…", async () =>
        {
            var picker = new FileOpenPicker(); picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, (Application.Current as App)?.MainWindowHandle ?? 0);
            if (await picker.PickSingleFileAsync() is not { } file) return;
            if (new FileInfo(file.Path).Length > 2 * 1024 * 1024) throw new IOException("SSH config is larger than 2 MiB.");
            var source = await File.ReadAllTextAsync(file.Path); var hosts = SshConfig.LoadText(source);
            if (hosts.Count == 0) throw new IOException("The file contains no literal hosts.");
            var choices = new ListView { SelectionMode = ListViewSelectionMode.Multiple, Height = 320, ItemsSource = hosts.Select(h => new Row(h)).ToArray() };
            var import = new StackPanel { Spacing = 12 }; import.Children.Add(new TextBlock { Text = "Choose hosts to import. Existing labels require editing individually; wildcard and Match rules remain in the source file.", TextWrapping = TextWrapping.Wrap }); import.Children.Add(choices);
            await EditorDialog.ShowAsync("Import Hosts", import, () =>
            {
                var selected = choices.SelectedItems.Cast<Row>().ToArray();
                if (selected.Length == 0) throw new IOException("Choose at least one host.");
                var original = ReadConfig(); var updated = original;
                updated = SshConfigEditor.Import(original, source, selected.Select(r => r.Host.Alias), Path.GetDirectoryName(file.Path)!);
                SshConfigEditor.Save(original, updated); Reload(); return Task.CompletedTask;
            }, "Import");
        });
        AddCommand("\uE77B", "Manage identities…", () => IdentityManager.ShowAsync(theme));
        AddCommand("\uE72E", "Remote authorization…", async () => { if (list.SelectedItem is Row row) await AuthorizationManager.ShowAsync(row.Host, theme, connection); }, true, true);
        query.TextChanged += (_, _) => { try { Reload(); } catch (Exception ex) { error.Text = ex.Message; } };
        list.DoubleTapped += async (_, _) => { if (list.SelectedItem is Row row) await Run(() => connect(row.Host)); };
        list.SelectionChanged += (_, _) => UpdateCommands();
        list.RightTapped += (_, e) =>
        {
            var element = e.OriginalSource as DependencyObject;
            while (element is not null && element is not ListViewItem) element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element);
            if (element is ListViewItem item) list.SelectedItem = list.ItemFromContainer(item);
            UpdateCommands(); contextMenu.ShowAt(list, e.GetPosition(list)); e.Handled = true;
        };
        list.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter && list.SelectedItem is Row row) { e.Handled = true; await Run(() => connect(row.Host)); }
        };
        list.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
              <StackPanel Spacing="3" Margin="0,6">
                <TextBlock Text="{Binding Host.Label}" FontWeight="SemiBold" />
                <TextBlock Text="{Binding Host.Target}" FontSize="12" Opacity="0.65" />
              </StackPanel>
            </DataTemplate>
            """);
        panel.Children.Add(buttons); panel.Children.Add(query); panel.Children.Add(list); panel.Children.Add(error);
        Reload(); UpdateCommands(); await EditorDialog.ShowAsync("Manage Hosts", panel, () => busy ? throw new IOException("Finish the current host operation first.") : Task.CompletedTask, "Done", () => busy);
    }
    private static string ReadConfig() => File.Exists(SshConfig.DefaultPath) ? File.ReadAllText(SshConfig.DefaultPath) : "";
    private static string? RawJump(string text, string alias)
    {
        var active = false;
        foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
        {
            var host = Regex.Match(line, @"^\s*Host\s+([^#]+)", RegexOptions.IgnoreCase);
            if (host.Success) { active = host.Groups[1].Value.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Contains(alias); continue; }
            if (Regex.IsMatch(line, @"^\s*Match(?:\s|=)", RegexOptions.IgnoreCase)) active = false;
            if (active && Regex.Match(line, @"^\s*ProxyJump(?:\s+|\s*=\s*)([^#]+)", RegexOptions.IgnoreCase) is { Success: true } jump)
                return jump.Groups[1].Value.Trim();
        }
        return null;
    }
    private static async Task<string?> EditAsync(HostEntry? host)
    {
        var original = ReadConfig(); var store = IdentityStore.Current;
        var fields = new StackPanel { Spacing = 12 };
        var address = new TextBox { Header = "Address", Text = host?.HostName ?? "" };
        var alias = new TextBox { Header = "Label (SSH alias)", Text = host?.Alias ?? "" };
        var user = new TextBox { Header = "Username", Text = host?.User ?? Environment.UserName };
        var port = new NumberBox { Header = "Port", Minimum = 1, Maximum = 65535, Value = host?.Port ?? 22 };
        var timeout = new NumberBox { Header = "Connect timeout (seconds)", Minimum = 1, Maximum = 3600, Value = host?.ConnectTimeoutSeconds ?? 15 };
        var jump = new TextBox { Header = "Jump hosts (comma-separated SSH aliases)", Text = host is null ? "" : RawJump(original, host.Alias) ?? string.Join(",", host.Route.Select(h => (h.User is null ? "" : h.User + "@") + (h.HostName.Contains(':') ? "[" + h.HostName + "]" : h.HostName) + ":" + h.Port)) };
        var key = new TextBox { Header = "SSH config key file (used without a managed identity)", Text = host?.IdentityFile ?? "" };
        var identities = new ComboBox { Header = "Identity", HorizontalAlignment = HorizontalAlignment.Stretch };
        void ReloadIdentities(Guid? id)
        {
            identities.ItemsSource = new[] { new IdentityRow(null, "SSH config / default keys") }.Concat(store.Identities.Select(i => new IdentityRow(i.Id, i.Name))).ToArray();
            identities.SelectedItem = identities.Items.Cast<IdentityRow>().FirstOrDefault(i => i.Id == id) ?? identities.Items[0];
        }
        ReloadIdentities(host is null ? null : store.AssignedIdentity(host.Alias));
        var identityProblem = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var identityBusy = false;
        var newIdentity = EditorDialog.Icon("\uE710", "New Identity", async () =>
        {
            if (identityBusy) return;
            identityBusy = true;
            try { if (await IdentityManager.EditAsync(null) is { } id) ReloadIdentities(id); }
            catch (Exception ex) { identityProblem.Text = ex.Message; }
            finally { identityBusy = false; }
        });
        foreach (var field in new UIElement[] { address, alias, port, user, identities, newIdentity, identityProblem, key, jump, timeout }) fields.Children.Add(field);
        ToolTipService.SetToolTip(fields, "Additional SSH directives are preserved.");
        var saved = await EditorDialog.ShowAsync(host is null ? "New Host" : "Edit Host", fields, () =>
        {
            if (identityBusy) throw new IOException("Finish editing the identity first.");
            if (!double.IsFinite(port.Value) || port.Value != Math.Truncate(port.Value) || port.Value is < 1 or > 65535 ||
                !double.IsFinite(timeout.Value) || timeout.Value != Math.Truncate(timeout.Value) || timeout.Value is < 1 or > 3600) throw new IOException("Enter a valid port and timeout.");
            var draft = new HostDraft(alias.Text.Trim(), address.Text.Trim(), user.Text.Trim(), (ushort)port.Value,
                string.IsNullOrWhiteSpace(key.Text) ? null : key.Text.Trim(), jump.Text.Trim(), (int)timeout.Value);
            var updated = SshConfigEditor.Update(original, host?.Alias, draft);
            // Write credentials' binding first: if config replacement fails the stale
            // digest refuses authentication instead of disclosing a saved credential.
            var parsed = SshConfig.LoadText(updated).Single(h => h.Alias == draft.Alias);
            SshConfigEditor.Save(original, updated, beforeReplace: () => store.Bind(parsed, (identities.SelectedItem as IdentityRow)?.Id, host?.Alias)); return Task.CompletedTask;
        }, busy: () => identityBusy);
        return saved ? alias.Text.Trim() : null;
    }
}
