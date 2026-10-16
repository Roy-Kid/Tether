using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace TetherApp;

internal static class IdentityManager
{
    private sealed record Row(AccountIdentity Identity) { public override string ToString() => Identity.Name + " — " + Identity.Method; }
    public static async Task ShowAsync(ElementTheme theme)
    {
        var store = IdentityStore.Current;
        var panel = new StackPanel { Spacing = 12 };
        var list = new ListView { Height = 320, SelectionMode = ListViewSelectionMode.Single };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        void Reload(Guid? id = null) { list.ItemsSource = store.Identities.Select(i => new Row(i)).ToArray(); list.SelectedItem = list.Items.Cast<Row>().FirstOrDefault(r => r.Identity.Id == id) ?? list.Items.Cast<Row>().FirstOrDefault(); }
        var busy = false;
        async Task Run(Func<Task> action)
        {
            if (busy) return; busy = true;
            foreach (var button in buttons.Children.OfType<Button>()) button.IsEnabled = false;
            try { error.Text = ""; await action(); } catch (Exception ex) { error.Text = ex.Message; }
            finally { busy = false; foreach (var button in buttons.Children.OfType<Button>()) button.IsEnabled = true; }
        }
        buttons.Children.Add(EditorDialog.Icon("\uE710", "New Identity", () => _ = Run(async () => { if (await EditAsync(null) is { } id) Reload(id); })));
        buttons.Children.Add(EditorDialog.Icon("\uE70F", "Edit Identity", () => _ = Run(async () => { if (list.SelectedItem is Row row && await EditAsync(row.Identity) is { } id) Reload(id); })));
        buttons.Children.Add(EditorDialog.Icon("\uE74D", "Delete Identity", () => _ = Run(async () =>
        {
            if (list.SelectedItem is not Row row) return;
            if (await Alerts.ContentAsync("Delete Identity?", row.Identity.Name, "Delete", null, theme, _ => { }) != ContentDialogResult.Primary) return;
            store.Delete(row.Identity.Id); Reload();
        })));
        panel.Children.Add(buttons); panel.Children.Add(list); panel.Children.Add(error);
        panel.Children.Add(new TextBlock { Text = "Credentials are encrypted for your Windows account. Assign identities in Manage Hosts. Public keys must be authorized on the server before they can connect.", TextWrapping = TextWrapping.Wrap });
        Reload(); await EditorDialog.ShowAsync("Identities", panel, () => busy ? throw new IOException("Finish the current identity operation first.") : Task.CompletedTask, "Done", () => busy);
    }
    public static async Task<Guid?> EditAsync(AccountIdentity? initial)
    {
        var store = IdentityStore.Current;
        var identity = initial ?? new AccountIdentity(Guid.NewGuid(), "", AuthenticationMethod.DefaultKeys);
        var panel = new StackPanel { Spacing = 12 };
        var name = new TextBox { Header = "Account identity", Text = identity.Name };
        var method = new ComboBox { Header = "Authentication", HorizontalAlignment = HorizontalAlignment.Stretch };
        method.Items.Add("Default SSH keys"); method.Items.Add("SSH private key"); method.Items.Add("Password"); method.SelectedIndex = (int)identity.Method;
        var password = new PasswordBox { Header = initial?.Secret is not null ? "New password (leave blank to keep)" : "Password" };
        var path = new TextBox { Header = "Key file on this device", Text = identity.KeyPath ?? "", PlaceholderText = "~/.ssh/id_ed25519" };
        var publicKey = new TextBox { Header = "Public key", Text = identity.PublicKey ?? "", IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true };
        var keyStatus = new TextBlock { Text = identity.Secret is not null && identity.Method == AuthenticationMethod.Key ? "Private key stored on this device" : "", TextWrapping = TextWrapping.Wrap };
        var keyButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        string? imported = null; var busy = false;
        var problem = new TextBlock { TextWrapping = TextWrapping.Wrap };
        async Task KeyOperation(Func<Task> action)
        {
            if (busy) return; busy = true; foreach (var button in keyButtons.Children.OfType<Button>()) button.IsEnabled = false; problem.Text = "";
            try { await action(); } catch (Exception ex) { problem.Text = ex.Message; }
            finally { busy = false; foreach (var button in keyButtons.Children.OfType<Button>()) button.IsEnabled = true; }
        }
        keyButtons.Children.Add(EditorDialog.Icon("\uE8E5", "Generate Ed25519 Key", () => _ = KeyOperation(async () =>
        {
            var generated = await IdentityStore.GenerateKeyAsync(); imported = generated.Private; publicKey.Text = generated.Public;
            path.Text = ""; keyStatus.Text = "New private key will be stored when you save";
        })));
        keyButtons.Children.Add(EditorDialog.Icon("\uE8B5", "Import Private Key", () => _ = KeyOperation(async () =>
        {
            var picker = new FileOpenPicker(); picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, (Application.Current as App)?.MainWindowHandle ?? 0);
            if (await picker.PickSingleFileAsync() is not { } file) return;
            if (new FileInfo(file.Path).Length > 128 * 1024) throw new IOException("Private keys must be smaller than 128 KiB.");
            var text = await File.ReadAllTextAsync(file.Path);
            if (!text.Contains("PRIVATE KEY-----", StringComparison.Ordinal)) throw new IOException("Choose an OpenSSH or PEM private key.");
            imported = text; path.Text = ""; publicKey.Text = File.Exists(file.Path + ".pub") ? (await File.ReadAllTextAsync(file.Path + ".pub")).Trim() : "";
            keyStatus.Text = "Private key will be stored when you save; encrypted keys ask for their passphrase during login";
        })));
        keyButtons.Children.Add(EditorDialog.Icon("\uE8A5", "Copy Public Key", () =>
        {
            if (publicKey.Text.Length == 0) return;
            var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(publicKey.Text);
            try { Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); } catch (Exception ex) { problem.Text = ex.Message; }
        }));
        var confirmation = new ComboBox { Header = "Confirmation", HorizontalAlignment = HorizontalAlignment.Stretch };
        confirmation.Items.Add("Automatic"); confirmation.Items.Add("Before authentication"); confirmation.Items.Add("Every connection"); confirmation.SelectedIndex = (int)identity.Confirmation;
        var otp = new PasswordBox { Header = identity.Otp is not null ? "Replace TOTP secret or otpauth URI" : "TOTP secret or otpauth URI" };
        var clearOtp = new CheckBox { Content = "Remove saved TOTP credential" };
        var prompt = new TextBox { Header = "Exact OTP challenge label", Text = identity.OtpPrompt };
        foreach (var item in new UIElement[] { name, method, password, path, keyButtons, keyStatus, publicKey, confirmation, otp, clearOtp, prompt, problem }) panel.Children.Add(item);
        void Visibility()
        {
            var key = method.SelectedIndex == (int)AuthenticationMethod.Key;
            path.Visibility = keyButtons.Visibility = keyStatus.Visibility = publicKey.Visibility = key ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
            password.Visibility = method.SelectedIndex == (int)AuthenticationMethod.Password ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        }
        method.SelectionChanged += (_, _) => Visibility(); Visibility();
        var saved = await EditorDialog.ShowAsync(initial is null ? "New Identity" : "Edit Identity", panel, () =>
        {
            if (busy) throw new IOException("Wait for the key operation to finish.");
            var selected = (AuthenticationMethod)method.SelectedIndex;
            var changedMethod = selected != identity.Method;
            var updated = identity with { Name = name.Text.Trim(), Method = selected, KeyPath = string.IsNullOrWhiteSpace(path.Text) ? null : path.Text.Trim(), PublicKey = string.IsNullOrWhiteSpace(publicKey.Text) ? null : publicKey.Text.Trim(),
                Confirmation = (ConfirmationPolicy)confirmation.SelectedIndex, OtpPrompt = prompt.Text, Secret = changedMethod || path.Text.Trim().Length > 0 ? null : identity.Secret };
            string? secret = selected == AuthenticationMethod.Key ? imported : selected == AuthenticationMethod.Password && password.Password.Length > 0 ? password.Password : null;
            if (selected == AuthenticationMethod.Password && secret is null && updated.Secret is null) throw new IOException("Enter a password for this identity.");
            store.Save(updated, secret, otp.Password.Length > 0 ? otp.Password : null, clearOtp.IsChecked == true);
            password.Password = otp.Password = ""; imported = null; return Task.CompletedTask;
        }, busy: () => busy);
        password.Password = otp.Password = ""; imported = null;
        return saved ? identity.Id : null;
    }
}
