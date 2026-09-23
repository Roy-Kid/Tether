// System dialogs for host-key trust and keyboard-interactive prompts.
//
// The shape `HandshakeAlert.swift` uses on Apple, and the silence law in
// `.claude/notes/law.md`: a title and a verb. One extra line only when the
// consequence is not the button — which is why the fingerprint is the body
// of the trust dialog and nothing else is.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tether;

namespace TetherApp;

public static class Alerts
{
    /// <summary>
    /// Asks whether this host may be talked to. Called during the handshake,
    /// before any credential exists on the wire (spec §18).
    ///
    /// A revoked key is not a question: one button, and the answer is always
    /// no (see <see cref="TrustAsync(XamlRoot, HostIdentity, TrustQuestion)"/>).
    /// </summary>
    public static async Task<bool> TrustAsync(XamlRoot root, HostIdentity host, TrustQuestion question)
    {
        // A revoked key gets a notice, not a choice. "Trust" would be a
        // button that means "ignore the revoke", which is not a thing.
        if (question is TrustQuestion.Revoked)
        {
            var notice = new ContentDialog
            {
                XamlRoot = root,
                Title = "This host's key is revoked",
                Content = host.Fingerprint,
                CloseButtonText = "Close",
                DefaultButton = ContentDialogButton.Close,
            };
            await notice.ShowAsync();
            return false;
        }

        var changed = question is TrustQuestion.Changed;
        var title = changed ? "This host's key has changed" : "Unrecognised host";
        // The fingerprint is the body: the consequence is not the button, so
        // it is the one thing that must be on screen.
        var message = host.Fingerprint;

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = message,
            CloseButtonText = "Reject",
            PrimaryButtonText = "Trust",
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary;
    }

    /// <summary>
    /// Asks the questions a server asked. <see cref="AuthPrompt.Echo"/> false
    /// means a password or one-time code — honour it.
    /// </summary>
    /// <returns>One answer per prompt, or empty for declined.</returns>
    public static async Task<IReadOnlyList<string>> PromptsAsync(
        XamlRoot root, string instruction, IReadOnlyList<AuthPrompt> prompts)
    {
        if (prompts.Count == 0) return Array.Empty<string>();

        var title = TitleFor(prompts[0]);
        var message = instruction.Length == 0 || instruction == title ? null : instruction;

        var panel = new StackPanel { Spacing = 8 };
        if (message is not null)
        {
            panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        }

        var boxes = new List<PasswordBox>();
        var plains = new List<TextBox>();
        foreach (var prompt in prompts)
        {
            panel.Children.Add(new TextBlock { Text = prompt.Text, TextWrapping = TextWrapping.Wrap });
            if (prompt.Echo)
            {
                var plain = new TextBox { PlaceholderText = "" };
                plains.Add(plain);
                boxes.Add(null!);
                panel.Children.Add(plain);
            }
            else
            {
                var secure = new PasswordBox();
                boxes.Add(secure);
                plains.Add(null!);
                panel.Children.Add(secure);
            }
        }

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = panel,
            CloseButtonText = "Cancel",
            PrimaryButtonText = "Continue",
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return Array.Empty<string>();

        var answers = new string[prompts.Count];
        for (var i = 0; i < prompts.Count; i++)
        {
            answers[i] = prompts[i].Echo ? plains[i].Text : boxes[i].Password;
        }
        return answers;
    }

    private static string TitleFor(AuthPrompt prompt)
    {
        var text = prompt.Text.Trim();
        return text.Length switch
        {
            0 => "Continue",
            _ when text.Contains("password", StringComparison.OrdinalIgnoreCase) => "Password",
            _ when text.Contains("verification", StringComparison.OrdinalIgnoreCase) => "Verification code",
            _ => text.Length > 24 ? text[..24] : text,
        };
    }
}
