using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TetherApp;

internal static class AuthorizationManager
{
    private sealed record Row(RemoteAuthorization Record) { public override string ToString() => Record.DeviceLabel + " — " + Record.State; }
    public static async Task ShowAsync(HostEntry host, ElementTheme theme, Func<HostEntry, SessionModel?> connection)
    {
        if (host.Unsupported.Count > 0) throw new IOException("Review the unsupported connection directives before authorizing this host.");
        var store = IdentityStore.Current; var identity = store.ForHost(host);
        var panel = new StackPanel { Spacing = 12 };
        var device = new TextBox { Header = "Device name", Text = Environment.MachineName };
        var key = new TextBox { Header = "SSH public key", Text = identity?.PublicKey ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
        var list = new ListView { Height = 240, SelectionMode = ListViewSelectionMode.Single };
        var detail = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; var busy = false;
        void Reload(Guid? id = null)
        {
            list.ItemsSource = store.Authorizations.Where(a => a.HostAlias == host.Alias).Select(a => new Row(a)).ToArray();
            list.SelectedItem = list.Items.Cast<Row>().FirstOrDefault(r => r.Record.Id == id) ?? list.Items.Cast<Row>().FirstOrDefault();
        }
        RemoteAuthorization Record()
        {
            if (string.IsNullOrWhiteSpace(device.Text) || device.Text.Any(char.IsControl)) throw new IOException("Enter a device name.");
            var material = AuthorizedKeysProvider.KeyMaterial(key.Text);
            return store.Authorizations.FirstOrDefault(a => a.HostAlias == host.Alias && a.EndpointDigest == IdentityStore.EndpointDigest(host) && a.PublicKey == material && a.State != "Revoked")
                ?? new(Guid.NewGuid(), host.Alias, IdentityStore.EndpointDigest(host), material, device.Text.Trim());
        }
        async Task Run(Func<Task> action)
        {
            if (busy) return; busy = true; foreach (var button in buttons.Children.OfType<Button>()) button.IsEnabled = false;
            try { detail.Text = ""; await action(); } catch (Exception ex) { detail.Text = ex.Message; }
            finally { busy = false; foreach (var button in buttons.Children.OfType<Button>()) button.IsEnabled = true; }
        }
        async Task Apply(RemoteAuthorization record, bool remove)
        {
            if (record.EndpointDigest != IdentityStore.EndpointDigest(host)) throw new IOException("Host configuration changed. Authorization belongs to its original endpoint.");
            var model = connection(host) ?? throw new IOException("Connect to this host before changing its authorization.");
            var generation = model.Generation;
            if (await Alerts.ContentAsync(remove ? "Remove Authorization?" : "Install Public Key?", host.Target + " — " + record.DeviceLabel, remove ? "Remove" : "Install", null, theme, _ => { }) != ContentDialogResult.Primary) return;
            record = record with { State = remove ? "Revocation pending" : "Installation pending", Detail = null };
            // Persist ownership before the write so a dropped connection remains retryable.
            store.SaveAuthorization(record); Reload(record.Id);
            try
            {
                if (!model.IsRemote || !model.IsLive || model.Generation != generation || model.RemoteHost is not { } current || IdentityStore.EndpointDigest(current) != record.EndpointDigest)
                    throw new IOException("The connection changed. Connect to the original host and retry.");
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                await model.ExecuteAsync(AuthorizedKeysProvider.Script(record, remove), timeout.Token);
                record = record with { State = remove ? "Revoked" : "Installed", Detail = remove ? null : "Verify by logging in with this key." };
            }
            catch (Exception ex) { record = record with { Detail = ex.Message }; throw; }
            finally { store.SaveAuthorization(record); Reload(record.Id); }
        }
        buttons.Children.Add(EditorDialog.Icon("\uE8A5", "Prepare Administrator Request", () => _ = Run(() =>
        {
            var record = Record(); store.SaveAuthorization(record); Reload(record.Id);
            var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(record.PublicKey + " tether:" + record.Id.ToString("D"));
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); return Task.CompletedTask;
        })));
        buttons.Children.Add(EditorDialog.Icon("\uE8FB", "Install Public Key", () => _ = Run(() => Apply(Record(), false))));
        buttons.Children.Add(EditorDialog.Icon("\uE74D", "Remove Authorization", () => _ = Run(async () => { if (list.SelectedItem is Row row && row.Record.State != "Revoked") await Apply(row.Record, true); })));
        list.SelectionChanged += (_, _) => detail.Text = (list.SelectedItem as Row)?.Record.Detail ?? "";
        foreach (var element in new UIElement[] { device, key, buttons, list, detail }) panel.Children.Add(element);
        Reload(); await EditorDialog.ShowAsync("Remote Authorization — " + host.Label, panel, () => busy ? throw new IOException("Wait for the authorization operation to finish.") : Task.CompletedTask, "Done", () => busy);
    }
}
