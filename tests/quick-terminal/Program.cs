using System.Runtime.InteropServices;
using TetherApp;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (!args.Contains("--interactive"))
        {
            Console.WriteLine("Manual native-window smoke test: pass --interactive in a Windows desktop session.");
            return 2;
        }
        ApplicationConfiguration.Initialize();
        using var window = new Form { Text = "Quick Terminal native test", StartPosition = FormStartPosition.Manual,
            Bounds = new Rectangle(160, 180, 700, 500) };
        using var other = new Form { Text = "Quick Terminal ownership fixture" };
        var ready = false;
        var run = new Button { Text = "Run native checks", AutoSize = true, Location = new Point(24, 24) };
        run.Click += (_, _) => ready = true;
        window.Controls.Add(run);
        window.Show();
        Console.WriteLine("Click Run native checks in the fixture window (it contains no shell).");
        var deadline = DateTime.UtcNow.AddMinutes(2);
        while (!ready && !window.IsDisposed && DateTime.UtcNow < deadline) { Application.DoEvents(); Thread.Sleep(30); }
        Check(ready, "native interactive smoke requires foreground input; no checks were run");
        window.Activate(); Pump();
        var original = window.Bounds;
        var focused = 0;
        var blocked = false;
        using var controller = new QuickTerminalController(window.Handle,
            action => window.BeginInvoke(action), () => focused++, () => blocked);
        var settings = new AppSettings { QuickTerminalTrayIcon = false };
        controller.Apply(settings);
        Check(controller.Problem is null, controller.Problem ?? "global registration");
        Check(!RegisterHotKey(other.Handle, 123, 0x4002, 192), "another HWND cannot claim the registered shortcut");
        controller.Toggle(); Pump();
        Check(controller.IsQuick && controller.IsVisible && focused > 0, "the existing HWND becomes a visible quick terminal");
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Check(window.Left == area.Left && window.Top == area.Top && window.Width == area.Width && window.Height <= area.Height,
            "quick geometry uses the pointer monitor work area");
        blocked = true;
        other.Show(); SetWindowLongPtr(other.Handle, -8, window.Handle); other.Activate(); Pump();
        Check(GetWindow(other.Handle, 4) == window.Handle, "fixture establishes a native owner for an overlapped window");
        blocked = false;
        PostMessage(window.Handle, 0x0006, 0, other.Handle); Pump();
        Check(controller.IsVisible, "owned settings/dialog windows stay above the quick terminal");
        other.Hide(); SetWindowLongPtr(other.Handle, -8, 0); window.Activate(); Pump();
        blocked = true;
        controller.Toggle(); Pump();
        Check(controller.IsVisible, "an active handshake/modal cannot be hidden by the global shortcut");
        blocked = false;
        PostMessage(window.Handle, 0x0312, 0x5140, 0); Pump();
        Check(controller.IsQuick && !controller.IsVisible && !window.IsDisposed, "WM_HOTKEY hides without destroying the existing window");
        PostMessage(window.Handle, 0x0312, 0x5140, 0); Pump();
        Check(controller.IsVisible, "WM_HOTKEY reopens the same window");
        for (var i = 0; i < 5; i++) { controller.Hide(); controller.Toggle(); Pump(); }
        controller.Restore(); Pump();
        Check(!controller.IsQuick && window.Bounds == original, "normal geometry restores after repeated toggling");
        window.WindowState = FormWindowState.Maximized; Pump();
        controller.Toggle(); Pump(); controller.Restore(); Pump();
        Check(window.WindowState == FormWindowState.Maximized, "maximized state restores");
        window.WindowState = FormWindowState.Normal; Pump();
        window.WindowState = FormWindowState.Minimized; Pump();
        controller.Toggle(); Pump();
        Check(controller.IsQuick && controller.IsVisible && window.WindowState != FormWindowState.Minimized, "a minimized window can be summoned");
        controller.Restore(); Pump();
        Check(window.Bounds == original, "minimized restore retains normal geometry");
        controller.Toggle(); Pump(); other.Show(); other.Activate(); Pump();
        Check(!controller.IsVisible && !window.IsDisposed, "a separate application window remains reachable without losing the quick window");
        controller.Apply(settings with { QuickTerminalEnabled = false }); Pump();
        Check(!controller.IsQuick && controller.IsVisible && window.Bounds == original, "disabling restores the window");
        Check(RegisterHotKey(other.Handle, 123, 0x4002, 192), "disabling releases the native shortcut");
        controller.Apply(settings);
        Check(controller.Problem is not null, "external registration conflicts are reported");
        UnregisterHotKey(other.Handle, 123);
        controller.Apply(settings);
        Check(controller.Problem is null, "a released shortcut can be registered again");
        uint FreeKey(uint modifiers)
        {
            for (uint key = 0x7c; key <= 0x87; key++)
                if (RegisterHotKey(other.Handle, 125, modifiers | 0x4000, key)) { UnregisterHotKey(other.Handle, 125); return key; }
            throw new InvalidOperationException("No unused fixture hotkey available.");
        }
        var primary = FreeKey(6);
        var secondary = FreeKey(5);
        settings = settings with { KeyBindings = new() { ["quickTerminal"] = "Ctrl+Shift+F" + (primary - 0x6f), ["quickTerminal.secondary"] = "Alt+Shift+F" + (secondary - 0x6f) } };
        controller.Apply(settings);
        Check(controller.Problem is null, controller.Problem ?? "primary and secondary registration");
        Check(RegisterHotKey(other.Handle, 123, 0x4002, 192), "rebinding releases the previous chord");
        UnregisterHotKey(other.Handle, 123);
        Check(!RegisterHotKey(other.Handle, 123, 0x4006, primary), "primary chord is registered");
        Check(!RegisterHotKey(other.Handle, 124, 0x4005, secondary), "secondary chord is registered");
        controller.Dispose();
        Check(QuickTerminalController.Current is null && RegisterHotKey(other.Handle, 123, 0x4006, primary) && RegisterHotKey(other.Handle, 124, 0x4005, secondary),
            "disposal releases both registrations");
        UnregisterHotKey(other.Handle, 123); UnregisterHotKey(other.Handle, 124);
        Console.WriteLine("PASS: real HWND geometry, WM_HOTKEY dispatch, hide/reopen, modal guard, restore, disable, registration conflicts, rebinding and cleanup.");
        return 0;
    }

    private static void Pump()
    {
        for (var i = 0; i < 6; i++) { Application.DoEvents(); Thread.Sleep(30); }
    }
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
    [DllImport("user32.dll")] private static extern nint GetWindow(nint hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLongPtr(nint hwnd, int index, nint value);
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint hwnd, uint message, nint wParam, nint lParam);
}
