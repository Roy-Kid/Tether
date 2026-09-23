using Microsoft.UI.Xaml.Controls;
using Tether;

namespace TetherApp;

public sealed partial class ConnectDialog : ContentDialog
{
    public ConnectDialog()
    {
        InitializeComponent();
        UserBox.Text = Environment.UserName;
        PortBox.Text = "22";
    }

    public string Host => HostBox.Text.Trim();
    public string User => UserBox.Text.Trim();
    public string Password => PasswordBox.Password;

    public ushort Port =>
        ushort.TryParse(PortBox.Text.Trim(), out var port) && port != 0 ? port : (ushort)22;

    public Destination Destination => new(Host, Port, User);

    /// <summary>
    /// Credentials to offer, in order. A typed password is offered first;
    /// keyboard-interactive is always last so a 2FA server still has a
    /// conversation to have (spec §10: keyboard-interactive is generic).
    /// </summary>
    public Secret[] Secrets(IAuthPrompter prompter)
    {
        var list = new List<Secret>();
        if (Password.Length > 0) list.Add(new Secret.Password(Password));
        list.Add(new Secret.Interactive(prompter));
        return list.ToArray();
    }
}
