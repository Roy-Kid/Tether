using System.ComponentModel;
using System.Runtime.InteropServices;

namespace TetherApp;

/// <summary>
/// Notification-area icon on its own message-only HWND. Closing the window
/// hides Tether; this is how it comes back. Quit is the path that ends sessions.
/// When Quick Terminal is enabled, left-click toggles it the way the macOS
/// menu-bar button does.
/// </summary>
sealed class TrayHost : IDisposable
{
    private const uint TrayMessage = 0x8000 + 74;
    private readonly Thread _thread;
    private readonly ManualResetEvent _ready = new(false);
    private readonly object _gate = new();
    private readonly nint _icon;
    private nint _hwnd;
    private bool _added, _disposed;
    private readonly uint _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private readonly WndProc _proc;
    private Action _show;
    private Action _quit;
    private Action? _toggleQuick;
    private Action? _restoreWindow;
    private Action? _toggleTopmost;
    private Func<bool>? _quickVisible;
    private Func<bool>? _isQuick;
    private Func<bool>? _alwaysOnTop;
    private Func<bool>? _quickEnabled;

    public TrayHost(nint icon, Action show, Action quit)
    {
        _icon = icon;
        _show = show;
        _quit = quit;
        _proc = WindowProc;
        Exception? start = null;
        _thread = new Thread(() =>
        {
            try
            {
                var className = "TetherTrayHost." + Guid.NewGuid().ToString("N");
                var windowClass = new WindowClass
                {
                    Size = (uint)Marshal.SizeOf<WindowClass>(),
                    WindowProc = Marshal.GetFunctionPointerForDelegate(_proc),
                    Instance = GetModuleHandle(null),
                    ClassName = className,
                };
                if (RegisterClassEx(ref windowClass) == 0) throw new Win32Exception();
                _hwnd = CreateWindowEx(0, className, "Tether tray", 0, 0, 0, 0, 0, -3, 0, windowClass.Instance, 0);
                if (_hwnd == 0) throw new Win32Exception();
                AddIcon();
            }
            catch (Exception error) { start = error; }
            finally { _ready.Set(); }
            if (start is not null) return;
            while (GetMessage(out var message, 0, 0, 0) > 0)
            {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
        });
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.IsBackground = true;
        _thread.Start();
        _ready.WaitOne();
        if (start is not null) throw start;
    }

    /// <summary>Keep the same icon; refresh what the menu and left-click do.</summary>
    public void BindQuickTerminal(Action show, Action quit, Action toggleQuick, Action restoreWindow,
        Action toggleTopmost, Func<bool> quickVisible, Func<bool> isQuick, Func<bool> alwaysOnTop, Func<bool> quickEnabled)
    {
        lock (_gate)
        {
            _show = show;
            _quit = quit;
            _toggleQuick = toggleQuick;
            _restoreWindow = restoreWindow;
            _toggleTopmost = toggleTopmost;
            _quickVisible = quickVisible;
            _isQuick = isQuick;
            _alwaysOnTop = alwaysOnTop;
            _quickEnabled = quickEnabled;
        }
    }

    private void AddIcon()
    {
        var data = IconData();
        _added = ShellNotifyIcon(0, ref data);
        if (_added) { data.Version = 4; ShellNotifyIcon(4, ref data); }
    }

    private void RemoveIcon()
    {
        if (!_added) return;
        var data = IconData();
        ShellNotifyIcon(2, ref data);
        _added = false;
    }

    private NotifyIconData IconData() => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = _hwnd,
        Id = 1,
        Flags = 1 | 2 | 4,
        CallbackMessage = TrayMessage,
        Icon = _icon,
        Tip = "Tether",
        Info = "",
        InfoTitle = "",
    };

    private nint WindowProc(nint hwnd, uint message, nint wParam, nint lParam)
    {
        if (message == TrayMessage)
        {
            var notification = (uint)(long)lParam & 0xffff;
            if (notification is 0x400 or 0x401) LeftClick();
            else if (notification == 0x007b) ShowMenu();
            return 0;
        }
        if (message == _taskbarCreated) { _added = false; AddIcon(); return 0; }
        if (message == 0x0010) // WM_CLOSE
        {
            RemoveIcon();
            DestroyWindow(hwnd);
            return 0;
        }
        if (message == 0x0002) // WM_DESTROY
        {
            PostQuitMessage(0);
            return 0;
        }
        return DefWindowProc(hwnd, message, wParam, lParam);
    }

    private void LeftClick()
    {
        Action? click;
        lock (_gate)
        {
            click = _quickEnabled?.Invoke() == true ? _toggleQuick : _show;
        }
        click?.Invoke();
    }

    private void ShowMenu()
    {
        Action show, quit;
        Action? toggleQuick, restoreWindow, toggleTopmost;
        Func<bool>? quickVisible, isQuick, alwaysOnTop, quickEnabled;
        lock (_gate)
        {
            show = _show;
            quit = _quit;
            toggleQuick = _toggleQuick;
            restoreWindow = _restoreWindow;
            toggleTopmost = _toggleTopmost;
            quickVisible = _quickVisible;
            isQuick = _isQuick;
            alwaysOnTop = _alwaysOnTop;
            quickEnabled = _quickEnabled;
        }
        var items = new List<NativeMenuItem>();
        if (quickEnabled?.Invoke() == true && toggleQuick is not null)
        {
            var hide = quickVisible?.Invoke() == true && isQuick?.Invoke() == true;
            items.Add(new(hide ? "Hide Quick Terminal" : "Show Quick Terminal", toggleQuick));
            items.Add(new("Restore Window", restoreWindow, isQuick?.Invoke() == true));
            items.Add(new("Keep Window on Top", toggleTopmost, Checked: alwaysOnTop?.Invoke() == true));
            items.Add(new(""));
        }
        else items.Add(new("Show Tether", show));
        items.Add(new("Quit Tether", quit));
        GetCursorPos(out var point);
        NativeContextMenu.ShowScreen(_hwnd, point.X, point.Y, items);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        var hwnd = _hwnd;
        _hwnd = 0;
        if (hwnd != 0) PostMessage(hwnd, 0x0010, 0, 0);
        _thread.Join(2000);
    }

    private delegate nint WndProc(nint hwnd, uint message, nint wParam, nint lParam);
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct WindowClass
    {
        public uint Size;
        public uint Style;
        public nint WindowProc;
        public int ClsExtra;
        public int WndExtra;
        public nint Instance;
        public nint Icon;
        public nint Cursor;
        public nint Background;
        public string? MenuName;
        public string? ClassName;
        public nint SmallIcon;
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativeMessage
    {
        public nint Hwnd; public uint Msg; public nint WParam, LParam; public uint Time; public Point Point;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct NotifyIconData
    {
        public uint Size; public nint Window; public uint Id, Flags, CallbackMessage; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    [DllImport("user32.dll", EntryPoint = "RegisterClassExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassEx(ref WindowClass windowClass);
    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll")] private static extern nint DefWindowProc(nint hwnd, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern int GetMessage(out NativeMessage message, nint hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref NativeMessage message);
    [DllImport("user32.dll")] private static extern nint DispatchMessage(ref NativeMessage message);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint hwnd, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern nint GetModuleHandle(string? module);
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
}
