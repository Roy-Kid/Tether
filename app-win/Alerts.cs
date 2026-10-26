// Questions the handshake has to ask a person: host trust, and whatever
// keyboard-interactive prompt the server sends.
//
// These run on a separate window, not a ContentDialog in the main one. The
// terminal is a child HWND above the XAML island, so a dialog drawn there is
// either hidden behind it or — if that child is hidden to reveal the dialog —
// takes the shell with it. A real window sits above the shell and leaves it
// where it is.
//
// The callback arrives on a thread-pool thread (UniFFI). WinUI throws if a
// window is created there, and that exception's message is empty, which is
// the "unexpected callback error" with a blank reason.

using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tether;
using Windows.Graphics;

namespace TetherApp;

public static class Alerts
{
    public static async Task<ContentDialogResult> ContentAsync(
        string title, object content, string primary, string? secondary,
        ElementTheme theme, Action<Window?> active)
    {
        var done = new TaskCompletionSource<ContentDialogResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = NewDialog(title, 360, 200);
        var (panel, _) = ChromeShell(theme);
        panel.Children.Add(ChromeTitle(title));
        var body = content as UIElement ?? new TextBlock
        {
            Text = content.ToString(),
            TextWrapping = TextWrapping.Wrap,
            FontSize = (double)Application.Current.Resources["TitleSize"],
            Foreground = (Brush)Application.Current.Resources["ChromeTextBrush"],
        };
        panel.Children.Add(new ScrollViewer
        {
            Content = body,
            MaxHeight = 220,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        });
        var buttons = ChromeActions();
        Button Add(string label, ContentDialogResult result, bool primaryButton)
        {
            var button = ChromeAction(label, primaryButton);
            button.Click += (_, _) => { done.TrySetResult(result); window.Close(); };
            buttons.Children.Add(button);
            return button;
        }
        var cancel = Add("Cancel", ContentDialogResult.None, false);
        if (secondary is not null) Add(secondary, ContentDialogResult.Secondary, false);
        Add(primary, ContentDialogResult.Primary, true);
        panel.Children.Add(buttons);
        panel.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; window.Close(); }
        };
        FitOnLoad(window, panel, preferredWidth: 360, minHeight: 140);
        panel.Loaded += (_, _) => { if (body is not TextBox) cancel.Focus(FocusState.Programmatic); };
        window.Content = panel;
        window.Closed += (_, _) => done.TrySetResult(ContentDialogResult.None);
        active(window);
        try { window.Activate(); return await done.Task; }
        finally { active(null); }
    }

    public static Task<bool> ConfirmPasteAsync(DispatcherQueue queue, int length) =>
        OnUi(queue, () => Ask("Paste into terminal?", $"{length:N0} characters; line breaks may execute commands.", "Paste", "Cancel"));

    public static Task<bool> ClipboardErrorAsync(DispatcherQueue queue, string detail) =>
        OnUi(queue, () => Ask("Clipboard unavailable", detail, null, "Close"));

    public static Task<bool> ConnectionErrorAsync(DispatcherQueue queue, string host, string detail) =>
        OnUi(queue, () => Ask("Could not connect to " + host, detail, null, "Close"));

    public static Task<bool> TrustAsync(
        DispatcherQueue queue, HostIdentity host, TrustQuestion question, CancellationToken cancellationToken = default)
    {
        if (question is TrustQuestion.Revoked)
            return OnUi(queue, () => Ask("This host's key is revoked", host.Fingerprint, null, "Close", cancellationToken));

        var title = question is TrustQuestion.Changed
            ? "This host's key has changed"
            : "Unrecognised host";
        return OnUi(queue, () => Ask(title, host.Fingerprint, "Trust", "Reject", cancellationToken));
    }

    public static Task<IReadOnlyList<string>> PromptsAsync(
        DispatcherQueue queue, string instruction, IReadOnlyList<AuthPrompt> prompts,
        CancellationToken cancellationToken = default)
    {
        if (prompts.Count == 0) return Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
        return OnUi(queue, () => AskPrompts(instruction, prompts, cancellationToken));
    }

    private static async Task<bool> Ask(
        string title, string body, string? primary, string close, CancellationToken cancellationToken = default)
    {
        var done = new TaskCompletionSource<bool>();
        var window = NewDialog(title, 360, 180);
        var (panel, _) = ChromeShell(Appearance.RequestedTheme);
        panel.Children.Add(ChromeTitle(title));
        panel.Children.Add(new TextBlock
        {
            Text = body,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = (double)Application.Current.Resources["TitleSize"],
            Foreground = (Brush)Application.Current.Resources["ChromeTextBrush"],
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        var buttons = ChromeActions();
        if (primary is not null)
        {
            var yes = ChromeAction(primary, true);
            yes.Click += (_, _) => { done.TrySetResult(true); window.Close(); };
            buttons.Children.Add(yes);
        }
        var no = ChromeAction(close, primary is null);
        no.Loaded += (_, _) => no.Focus(FocusState.Programmatic);
        no.Click += (_, _) => { done.TrySetResult(false); window.Close(); };
        buttons.Children.Add(no);
        panel.Children.Add(buttons);
        FitOnLoad(window, panel, preferredWidth: 360, minHeight: 140);
        window.Content = panel;
        window.Closed += (_, _) => done.TrySetResult(false);
        CloseWhen(window, cancellationToken);
        window.Activate();
        return await done.Task;
    }

    private static async Task<IReadOnlyList<string>> AskPrompts(
        string instruction, IReadOnlyList<AuthPrompt> prompts, CancellationToken cancellationToken = default)
    {
        var resources = Application.Current.Resources;
        var title = TitleFor(prompts[0]);
        var done = new TaskCompletionSource<IReadOnlyList<string>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = NewDialog(title, 320, 180);
        var (layout, spaceGroup) = ChromeShell(Appearance.RequestedTheme);
        layout.Children.Add(ChromeTitle(title));

        var fields = new StackPanel { Spacing = spaceGroup };
        var words = instruction.Trim();
        var firstLabel = PromptLabel(prompts[0]);
        if (words.Length > 0
            && !string.Equals(words, title, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(words, firstLabel, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(words, prompts[0].Text.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            fields.Children.Add(new TextBlock
            {
                Text = words,
                FontSize = (double)resources["TitleSize"],
                Foreground = (Brush)resources["ChromeSubtleBrush"],
                TextWrapping = TextWrapping.Wrap,
            });
        }

        // Values are read through these holders so verification codes can use
        // a plain TextBox (macOS .code) while passwords stay in PasswordBox.
        var readers = new Func<string>[prompts.Count];
        Control? firstField = null;
        for (var i = 0; i < prompts.Count; i++)
        {
            var prompt = prompts[i];
            var label = PromptLabel(prompt);
            var group = new StackPanel { Spacing = (double)resources["SpaceInline"] };
            if (!string.Equals(label, title, StringComparison.OrdinalIgnoreCase) && label.Length > 0)
            {
                group.Children.Add(new TextBlock
                {
                    Text = label,
                    FontSize = (double)resources["TitleSize"],
                    Foreground = (Brush)resources["ChromeSubtleBrush"],
                    TextWrapping = TextWrapping.Wrap,
                });
            }

            Control field;
            if (prompt.Echo)
            {
                var box = new TextBox
                {
                    Style = (Style)resources["ChromeFieldStyle"],
                    PlaceholderText = PromptLabel(prompt),
                };
                readers[i] = () => box.Text;
                field = box;
            }
            else
            {
                // macOS Dialog.Field.Kind.code/password are both secure; keep
                // codes hidden the same way so the box still looks like an input.
                var box = new PasswordBox
                {
                    Style = (Style)resources["ChromeSecretFieldStyle"],
                    PlaceholderText = IsVerificationCode(prompt) ? "Code" : PromptLabel(prompt),
                };
                readers[i] = () => box.Password;
                field = box;
            }
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(field, prompt.Text);
            group.Children.Add(field);
            fields.Children.Add(group);
            firstField ??= field;
        }

        var actions = ChromeActions();
        var ok = ChromeAction("Continue", true);
        var cancel = ChromeAction("Cancel", false);
        actions.Children.Add(cancel);
        actions.Children.Add(ok);
        layout.Children.Add(fields);
        layout.Children.Add(actions);
        var finished = false;
        void Finish(IReadOnlyList<string> answers)
        {
            if (finished) return;
            finished = true;
            done.TrySetResult(answers);
            window.Close();
        }
        void Submit() => Finish(readers.Select(read => read()).ToArray());
        ok.Click += (_, _) => Submit();
        cancel.Click += (_, _) => Finish([]);
        foreach (var child in fields.Children.OfType<StackPanel>())
        {
            if (child.Children.OfType<Control>().LastOrDefault() is not { } field) continue;
            field.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, e) =>
            {
                if (e.Key != Windows.System.VirtualKey.Enter) return;
                e.Handled = true;
                Submit();
            }), true);
        }
        layout.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Escape) return;
            e.Handled = true;
            Finish([]);
        }), true);
        FitOnLoad(window, layout, preferredWidth: 320, minHeight: 150, clampToOwner: true);
        layout.Loaded += (_, _) => firstField?.Focus(FocusState.Programmatic);
        window.Content = layout;
        window.Closed += (_, _) => Finish([]);
        CloseWhen(window, cancellationToken);
        window.Activate();
        return await done.Task;
    }

    private static (StackPanel Panel, double SpaceGroup) ChromeShell(ElementTheme theme)
    {
        var resources = Application.Current.Resources;
        var spaceGroup = (double)resources["SpaceGroup"];
        var panel = new StackPanel
        {
            Spacing = spaceGroup,
            Padding = new Thickness(12),
            RequestedTheme = theme,
            Background = (Brush)resources["ChromeRaisedBrush"],
        };
        return (panel, spaceGroup);
    }

    private static TextBlock ChromeTitle(string title) => new()
    {
        Text = title,
        FontSize = (double)Application.Current.Resources["TitleSize"],
        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        Foreground = (Brush)Application.Current.Resources["ChromeTextBrush"],
        TextWrapping = TextWrapping.Wrap,
    };

    private static StackPanel ChromeActions() => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = (double)Application.Current.Resources["SpaceGroup"],
        HorizontalAlignment = HorizontalAlignment.Right,
    };

    private static Button ChromeAction(string label, bool primary) => new()
    {
        Content = label,
        Style = (Style)Application.Current.Resources[primary ? "ChromePrimaryButtonStyle" : "ChromeSecondaryButtonStyle"],
    };

    private static void FitOnLoad(Window window, FrameworkElement root, double preferredWidth, double minHeight, bool clampToOwner = false)
    {
        root.Loaded += (_, _) =>
        {
            var scale = root.XamlRoot.RasterizationScale;
            var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            var maxWidth = area.Width / scale - 32;
            var maxHeight = area.Height / scale - 64;
            if (clampToOwner)
            {
                var owner = (Application.Current as App)?.MainWindowHandle ?? 0;
                if (owner != 0 && GetOwnerSize(owner, out var ownerWidth, out var ownerHeight))
                {
                    maxWidth = Math.Min(maxWidth, ownerWidth / scale - 24);
                    maxHeight = Math.Min(maxHeight, ownerHeight / scale - 48);
                }
            }
            var width = Math.Min(preferredWidth, Math.Max(280, maxWidth));
            root.Measure(new Windows.Foundation.Size(Math.Max(1, width - 24), double.PositiveInfinity));
            var height = Math.Min(Math.Max(minHeight, root.DesiredSize.Height + 8), Math.Max(1, maxHeight));
            window.AppWindow.ResizeClient(new SizeInt32((int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale)));
            WindowPlacement.Center(window, window.AppWindow.Size.Width, window.AppWindow.Size.Height);
        };
    }

    /// <summary>Cancel or the connect deadline closes the question. The handshake is parked until the window goes.</summary>
    private static void CloseWhen(Window window, CancellationToken cancellationToken)
    {
        if (!cancellationToken.CanBeCanceled) return;
        var registration = cancellationToken.Register(() =>
        {
            if (window.DispatcherQueue.HasThreadAccess) window.Close();
            else window.DispatcherQueue.TryEnqueue(window.Close);
        });
        window.Closed += (_, _) => registration.Dispose();
    }

    private static Window NewDialog(string title, int width, int height)
    {
        var window = new Window { Title = title };
        AppBranding.Apply(window);
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(true, false);
        presenter.IsResizable = false;
        presenter.IsMinimizable = false;
        presenter.IsMaximizable = false;
        // Stay above the terminal's child HWND for the whole answer; without
        // this, Continue clicks land on the shell underneath and the dial
        // never receives the code.
        presenter.IsAlwaysOnTop = true;
        window.AppWindow.SetPresenter(presenter);
        window.AppWindow.Resize(new SizeInt32(width, height));
        WindowPlacement.Center(window, width, height);
        WindowPlacement.Own(window, topmost: true);
        return window;
    }

    private static bool GetOwnerSize(nint owner, out int width, out int height)
    {
        width = height = 0;
        if (!GetWindowRect(owner, out var rect)) return false;
        width = Math.Max(0, rect.Right - rect.Left);
        height = Math.Max(0, rect.Bottom - rect.Top);
        return width > 0 && height > 0;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(nint hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    private static async Task<T> OnUi<T>(DispatcherQueue queue, Func<Task<T>> work)
    {
        // The caller captures this queue on the UI thread. Even reading
        // XamlRoot.Content here would access XAML from the UniFFI worker.
        if (queue.HasThreadAccess) return await work();

        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(async () =>
            {
                try { done.TrySetResult(await work()); }
                catch (Exception ex) { done.TrySetException(ex); }
            }))
        {
            throw new InvalidOperationException("Could not reach the window to ask.");
        }
        return await done.Task;
    }

    private static string TitleFor(AuthPrompt prompt)
    {
        var text = PromptLabel(prompt);
        if (text.Length == 0) return "Continue";
        if (IsVerificationCode(prompt)) return "Verification code";
        if (IsAccountPassword(prompt)) return "Password";
        return text.Length > 28 ? text[..28] : text;
    }

    /// <summary>Server prompt text without a trailing colon, for titles and labels.</summary>
    private static string PromptLabel(AuthPrompt prompt)
    {
        var text = prompt.Text.Trim();
        while (text.EndsWith(':') || text.EndsWith('：')) text = text[..^1].TrimEnd();
        return text;
    }

    /// <summary>Matches macOS Dialog.Field.Kind.code — a one-time code, not an account password.</summary>
    private static bool IsVerificationCode(AuthPrompt prompt)
    {
        if (prompt.Echo) return false;
        var folded = prompt.Text.ToLowerInvariant();
        return folded.Contains("verification", StringComparison.Ordinal)
            || folded.Contains("one-time", StringComparison.Ordinal)
            || folded.Contains("otp", StringComparison.Ordinal)
            || folded.Contains("token", StringComparison.Ordinal)
            || folded.Contains("passcode", StringComparison.Ordinal)
            || folded.Contains("authenticator", StringComparison.Ordinal)
            || folded.Contains("challenge", StringComparison.Ordinal);
    }

    private static bool IsAccountPassword(AuthPrompt prompt)
    {
        if (prompt.Echo || IsVerificationCode(prompt)) return false;
        var text = PromptLabel(prompt);
        return text.Equals("password", StringComparison.OrdinalIgnoreCase)
            || text.StartsWith("password ", StringComparison.OrdinalIgnoreCase)
            || text.EndsWith(" password", StringComparison.OrdinalIgnoreCase);
    }
}

static class WindowPlacement
{
    public static void Own(Window popup, bool topmost = true)
    {
        var owner = (Application.Current as App)?.MainWindowHandle ?? 0;
        if (owner == 0) return;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(popup);
        SetWindowLongPtr(hwnd, -8 /* GWLP_HWNDPARENT */, owner);
        // Above the terminal's child window, which otherwise takes the click
        // the person aimed at this list.
        if (topmost) SetWindowPos(hwnd, -1 /* HWND_TOPMOST */, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0010);
    }

    public static void Center(Window popup, int width, int height)
    {
        var owner = (Application.Current as App)?.MainWindowHandle ?? 0;
        if (owner == 0 || !GetWindowRect(owner, out var rect)) return;
        var x = rect.Left + Math.Max(0, (rect.Right - rect.Left - width) / 2);
        var y = rect.Top + Math.Max(0, (rect.Bottom - rect.Top - height) / 2);
        popup.AppWindow.Move(new PointInt32(x, y));
    }

    /// <summary>Puts <paramref name="popup"/> just above <paramref name="anchor"/>, in screen pixels.</summary>
    public static void Above(Window owner, FrameworkElement anchor, Window popup, int width, int height)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(owner);
        var scale = anchor.XamlRoot?.RasterizationScale ?? 1;
        var origin = anchor.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
        var pt = new POINT
        {
            X = (int)Math.Round(origin.X * scale),
            Y = (int)Math.Round(origin.Y * scale),
        };
        ClientToScreen(hwnd, ref pt);
        var y = pt.Y - height;
        if (y < 0) y = pt.Y + (int)Math.Round(anchor.ActualHeight * scale);
        popup.AppWindow.MoveAndResize(new RectInt32(pt.X, y, width, height));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(nint hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(nint hWnd, out RECT lpRect);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern nint SetWindowLongPtr(nint hWnd, int nIndex, nint dwNewLong);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int x, int y, int cx, int cy, uint flags);
}
