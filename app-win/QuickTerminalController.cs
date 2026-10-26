using System.ComponentModel;
using System.Runtime.InteropServices;

namespace TetherApp;

/// <summary>Reuses the main HWND and its sessions; hiding never closes a terminal.</summary>
internal sealed class QuickTerminalController : IDisposable
{
    private const nuint SubclassId = 0x544551;
    private const int FirstHotkey = 0x5140;
    private readonly nint _hwnd;
    private readonly Action<Action> _dispatch;
    private readonly Action _focus;
    private readonly Func<bool> _blocked;
    private readonly SubclassProc _proc;
    private readonly Dictionary<int, Shortcut> _hotkeys = [];
    private AppSettings _settings = new();
    private WindowPlacement _normal;
    private nint _previousWindow;
    private bool _disposed, _trayAdded;
    public static QuickTerminalController? Current { get; private set; }
    public static event Action? Changed;
    public bool IsQuick { get; private set; }
    public string? Problem { get; private set; }
    public bool IsVisible => IsWindowVisible(_hwnd) && !IsIconic(_hwnd);

    public QuickTerminalController(nint hwnd, Action<Action> dispatch, Action focus, Func<bool> blocked)
    {
        _hwnd = hwnd; _dispatch = dispatch; _focus = focus; _blocked = blocked;
        _proc = WindowProc;
        if (!SetWindowSubclass(hwnd, _proc, SubclassId, 0)) throw new Win32Exception();
        Current = this;
    }

    public void Apply(AppSettings settings)
    {
        if (_disposed) return;
        var command = WorkspaceCommands.All.Single(c => c.Id == "quickTerminal");
        var before = WorkspaceCommands.Bindings(command, _settings).ToArray();
        var after = WorkspaceCommands.Bindings(command, settings).ToArray();
        var register = _settings.QuickTerminalEnabled != settings.QuickTerminalEnabled ||
            !before.SequenceEqual(after) || _hotkeys.Count == 0;
        _settings = settings;
        if (!settings.QuickTerminalEnabled && IsQuick) Restore();
        Topmost(IsQuick || settings.AlwaysOnTop);
        if (register)
        {
            foreach (var id in _hotkeys.Keys) UnregisterHotKey(_hwnd, id);
            _hotkeys.Clear();
            Problem = null;
            if (settings.QuickTerminalEnabled)
            {
                for (var index = 0; index < after.Length; index++)
                {
                    var chord = after[index];
                    if (!Shortcut.TryParse(chord, out var shortcut))
                    { Problem = $"Invalid global shortcut: {chord}. Change it in Key Bindings."; continue; }
                    var modifiers = (shortcut.Control ? 2u : 0u) | (shortcut.Alt ? 1u : 0u) | (shortcut.Shift ? 4u : 0u);
                    var id = FirstHotkey + index;
                    if (RegisterHotKey(_hwnd, id, modifiers | 0x4000, (uint)shortcut.Key)) _hotkeys[id] = shortcut;
                    else Problem = $"Could not register {chord}: {new Win32Exception(Marshal.GetLastWin32Error()).Message} Change it in Key Bindings.";
                }
            }
        }
        RefreshTray();
        Changed?.Invoke();
    }

    public bool OwnsShortcut(Shortcut shortcut) => _hotkeys.ContainsValue(shortcut);

    public void Toggle()
    {
        if (_disposed || !_settings.QuickTerminalEnabled || _blocked()) return;
        if (IsQuick && IsVisible && IsOurForeground()) Hide();
        else Show();
    }

    private void Show()
    {
        if (_disposed || !_settings.QuickTerminalEnabled || _blocked()) return;
        if (!IsQuick)
        {
            _normal = new() { Length = (uint)Marshal.SizeOf<WindowPlacement>() };
            if (!GetWindowPlacement(_hwnd, ref _normal)) return;
            if (_normal.ShowCommand == 2) _normal.ShowCommand = 1;
            IsQuick = true;
        }
        var foreground = GetForegroundWindow();
        if (foreground != 0 && !BelongsToThisProcess(foreground)) _previousWindow = foreground;
        ShowWindow(_hwnd, 9); // Restore a minimized or maximized window before positioning.
        GetCursorPos(out var point);
        Fit(MonitorFromPoint(point, 2));
        SetForegroundWindow(_hwnd);
        _focus();
        Changed?.Invoke();
    }

    public void Hide()
    {
        if (_disposed || !IsQuick) return;
        var returnFocus = IsOurForeground();
        ShowWindow(_hwnd, 0);
        if (returnFocus && IsWindow(_previousWindow)) SetForegroundWindow(_previousWindow);
        _previousWindow = 0;
        Changed?.Invoke();
    }

    public void Restore()
    {
        if (_disposed || !IsQuick) return;
        IsQuick = false;
        SetWindowPlacement(_hwnd, ref _normal);
        Topmost(_settings.AlwaysOnTop);
        ShowWindow(_hwnd, _normal.ShowCommand == 3 ? 3 : 9);
        SetForegroundWindow(_hwnd);
        _previousWindow = 0;
        _focus();
        Changed?.Invoke();
    }

    private void Fit(nint monitor)
    {
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info)) return;
        var area = info.WorkArea;
        var bounds = QuickTerminalGeometry.TopHalf(new(area.Left, area.Top, area.Right - area.Left, area.Bottom - area.Top),
            (int)(300 * Math.Max(96u, GetDpiForWindow(_hwnd)) / 96));
        SetWindowPos(_hwnd, -1, bounds.X, bounds.Y, bounds.Width, bounds.Height, 0x0040);
    }

    private void Topmost(bool value) => SetWindowPos(_hwnd, value ? -1 : -2, 0, 0, 0, 0, 0x0013);
    private bool IsOurForeground() => GetAncestor(GetForegroundWindow(), 2) == _hwnd;
    private static bool BelongsToThisProcess(nint hwnd)
    {
        GetWindowThreadProcessId(hwnd, out var process);
        return process == Environment.ProcessId;
    }

    private bool IsOwnedWindow(nint hwnd)
    {
        // GetAncestor(GA_ROOTOWNER) uses GetParent and can miss an owned
        // overlapped window. Follow GW_OWNER explicitly after finding its root.
        for (var current = GetAncestor(hwnd, 2); current != 0; current = GetWindow(current, 4))
            if (current == _hwnd) return true;
        return false;
    }

    private void Deactivated()
    {
        if (_disposed || !IsQuick || !IsVisible || _blocked() || IsOurForeground()) return;
        var foreground = GetForegroundWindow();
        if (foreground == 0 || IsOwnedWindow(foreground)) return; // Owned dialogs stay above the terminal.
        if (_settings.QuickTerminalAutoHide || BelongsToThisProcess(foreground)) Hide();
    }

    /// <summary>
    /// TrayHost owns the notification-area icon (close-to-tray + Quick Terminal).
    /// Keep any leftover Shell_NotifyIcon from an older build cleared.
    /// </summary>
    private void RefreshTray()
    {
        if (_disposed || !_trayAdded) return;
        var data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = _hwnd, Id = 1,
        };
        ShellNotifyIcon(2, ref data);
        _trayAdded = false;
    }

    private nint WindowProc(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data)
    {
        try { return DispatchMessage(hwnd, message, wParam, lParam, id, data); }
        catch (Exception error)
        {
            Problem = "Quick Terminal: " + error.Message;
            return DefSubclassProc(hwnd, message, wParam, lParam);
        }
    }

    private nint DispatchMessage(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data)
    {
        // Never run XAML work or let a managed exception escape through a native callback.
        if (message == 0x0312 && _hotkeys.ContainsKey((int)wParam)) { _dispatch(Toggle); return 0; }
        if (message == 0x0006 && ((long)wParam & 0xffff) == 0) _dispatch(Deactivated);
        if (message is 0x007e or 0x02e0 or 0x001a)
            _dispatch(() => { if (!_disposed && IsQuick && IsVisible) Fit(MonitorFromWindow(_hwnd, 2)); });
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    public void Dispose()
    {
        if (_disposed) return;
        foreach (var id in _hotkeys.Keys) UnregisterHotKey(_hwnd, id);
        _hotkeys.Clear();
        RefreshTray();
        RemoveWindowSubclass(_hwnd, _proc, SubclassId);
        _disposed = true;
        if (Current == this) Current = null;
        Changed?.Invoke();
    }

    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct WindowPlacement { public uint Length, Flags; public int ShowCommand; public Point Min, Max; public Rect Normal; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public uint Size; public Rect Monitor, WorkArea; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct NotifyIconData
    {
        public uint Size; public nint Window; public uint Id;
    }
    private delegate nint SubclassProc(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc proc, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc proc, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(nint hwnd, ref WindowPlacement placement);
    [DllImport("user32.dll")] private static extern bool SetWindowPlacement(nint hwnd, ref WindowPlacement placement);
    [DllImport("user32.dll")] private static extern bool ShowWindow(nint hwnd, int command);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint hwnd, uint flags);
    [DllImport("user32.dll")] private static extern nint GetWindow(nint hwnd, uint command);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint process);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint hwnd);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
}
