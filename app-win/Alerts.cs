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
        var window = NewDialog(title, 480, 340);
        var panel = new StackPanel
        {
            Spacing = 16, Padding = new Thickness(24), RequestedTheme = theme,
            Background = (Brush)Application.Current.Resources["ChromeWindowBrush"],
        };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 20, TextWrapping = TextWrapping.Wrap });
        var body = content as UIElement ?? new TextBlock { Text = content.ToString(), TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(new ScrollViewer
        {
            Content = body, MaxHeight = 240,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        Button Add(string label, ContentDialogResult result)
        {
            var button = new Button { Content = label, MinWidth = 80 };
            button.Click += (_, _) => { done.TrySetResult(result); window.Close(); };
            buttons.Children.Add(button);
            return button;
        }
        var cancel = Add("Cancel", ContentDialogResult.None);
        if (secondary is not null) Add(secondary, ContentDialogResult.Secondary);
        Add(primary, ContentDialogResult.Primary);
        panel.Children.Add(buttons);
        panel.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; window.Close(); }
        };
        panel.Loaded += (_, _) =>
        {
            var scale = panel.XamlRoot.RasterizationScale;
            panel.Measure(new Windows.Foundation.Size(480, double.PositiveInfinity));
            window.AppWindow.ResizeClient(new SizeInt32((int)(480 * scale), (int)(Math.Max(180, panel.DesiredSize.Height) * scale)));
            WindowPlacement.Center(window, window.AppWindow.Size.Width, window.AppWindow.Size.Height);
            if (body is not TextBox) cancel.Focus(FocusState.Programmatic);
        };
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
        var window = NewDialog(title, 420, 200);
        var panel = new StackPanel { Spacing = 12, Padding = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 16, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock
        {
            Text = body,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        if (primary is not null)
        {
            var yes = new Button { Content = primary };
            yes.Click += (_, _) => { done.TrySetResult(true); window.Close(); };
            buttons.Children.Add(yes);
        }
        var no = new Button { Content = close };
        no.Loaded += (_, _) => no.Focus(FocusState.Programmatic);
        no.Click += (_, _) => { done.TrySetResult(false); window.Close(); };
        buttons.Children.Add(no);
        panel.Children.Add(buttons);
        window.Content = panel;
        window.Closed += (_, _) => done.TrySetResult(false);
        CloseWhen(window, cancellationToken);
        window.Activate();
        return await done.Task;
    }

    private static async Task<IReadOnlyList<string>> AskPrompts(
        string instruction, IReadOnlyList<AuthPrompt> prompts, CancellationToken cancellationToken = default)
    {
        var title = TitleFor(prompts[0]);
        var done = new TaskCompletionSource<IReadOnlyList<string>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = NewDialog(title, 440, 320);
        var layout = new Grid
        {
            Padding = new Thickness(24),
            RowSpacing = 20,
            RequestedTheme = Appearance.RequestedTheme,
            Background = (Brush)Application.Current.Resources["ChromeWindowBrush"],
        };
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var heading = new TextBlock
        {
            Text = title, FontSize = 20,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        };
        layout.Children.Add(heading);
        var panel = new StackPanel { Spacing = 16 };
        if (instruction.Length > 0 && instruction != title)
            panel.Children.Add(new TextBlock { Text = instruction, TextWrapping = TextWrapping.Wrap });

        var boxes = new PasswordBox[prompts.Count];
        var plains = new TextBox[prompts.Count];
        for (var i = 0; i < prompts.Count; i++)
        {
            var field = new StackPanel { Spacing = 6 };
            field.Children.Add(new TextBlock { Text = prompts[i].Text.Trim(), TextWrapping = TextWrapping.Wrap });
            if (prompts[i].Echo)
            {
                plains[i] = new TextBox { MinHeight = 36 };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(plains[i], prompts[i].Text);
                field.Children.Add(plains[i]);
            }
            else
            {
                boxes[i] = new PasswordBox { MinHeight = 36 };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(boxes[i], prompts[i].Text);
                field.Children.Add(boxes[i]);
            }
            panel.Children.Add(field);
        }

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var ok = new Button
        {
            Content = "Continue", MinWidth = 100,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        ok.Click += (_, _) =>
        {
            var answers = new string[prompts.Count];
            for (var i = 0; i < prompts.Count; i++)
                answers[i] = prompts[i].Echo ? plains[i].Text : boxes[i].Password;
            done.TrySetResult(answers);
            window.Close();
        };
        var cancel = new Button { Content = "Cancel", MinWidth = 100 };
        cancel.Click += (_, _) => { done.TrySetResult(Array.Empty<string>()); window.Close(); };
        row.Children.Add(cancel);
        row.Children.Add(ok);
        var scroll = new ScrollViewer
        {
            Content = panel,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        Grid.SetRow(scroll, 1);
        Grid.SetRow(row, 2);
        layout.Children.Add(scroll);
        layout.Children.Add(row);
        layout.Loaded += (_, _) =>
        {
            var scale = layout.XamlRoot.RasterizationScale;
            var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            var width = Math.Min(440, Math.Max(1, area.Width / scale - 32));
            var contentWidth = Math.Max(1, width - 48);
            heading.Measure(new Windows.Foundation.Size(contentWidth, double.PositiveInfinity));
            panel.Measure(new Windows.Foundation.Size(contentWidth, double.PositiveInfinity));
            row.Measure(new Windows.Foundation.Size(contentWidth, double.PositiveInfinity));
            var desired = 48 + 40 + heading.DesiredSize.Height + panel.DesiredSize.Height + row.DesiredSize.Height;
            var height = Math.Min(Math.Max(260, desired), Math.Max(1, area.Height / scale - 64));
            window.AppWindow.ResizeClient(new SizeInt32((int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale)));
            WindowPlacement.Center(window, window.AppWindow.Size.Width, window.AppWindow.Size.Height);
            Control first = prompts[0].Echo ? plains[0] : boxes[0];
            first.Focus(FocusState.Programmatic);
        };
        window.Content = layout;
        window.Closed += (_, _) => done.TrySetResult(Array.Empty<string>());
        CloseWhen(window, cancellationToken);
        window.Activate();
        return await done.Task;
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
        var presenter = OverlappedPresenter.CreateForDialog();
        presenter.SetBorderAndTitleBar(true, false);
        presenter.IsResizable = false;
        presenter.IsMinimizable = false;
        presenter.IsMaximizable = false;
        window.AppWindow.SetPresenter(presenter);
        window.AppWindow.Resize(new SizeInt32(width, height));
        WindowPlacement.Center(window, width, height);
        WindowPlacement.Own(window);
        return window;
    }

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

static class WindowPlacement
{
    public static void Own(Window popup)
    {
        var owner = (Application.Current as App)?.MainWindowHandle ?? 0;
        if (owner == 0) return;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(popup);
        SetWindowLongPtr(hwnd, -8 /* GWLP_HWNDPARENT */, owner);
        // Above the terminal's child window, which otherwise takes the click
        // the person aimed at this list.
        SetWindowPos(hwnd, -1 /* HWND_TOPMOST */, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0010);
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
