// A child `HWND` that covers the terminal's rectangle, and nothing else.
//
// wgpu draws to a window handle. The host window's handle is the whole
// window — chrome included — so the surface has to be a child that sits in
// the terminal's place. A `SwapChainPanel` would be the other way in, and is
// the next refinement; this is the one that works with the Vulkan/GLES
// backends Decisions/0017 ships while `dx12` is out.
//
// The child paints *and* receives keys: a real terminal's render window is
// its input window. XAML's `CharacterReceived` never fires for a control
// sitting under an HWND, so the keys come through here and are handed to
// the session. The mouse is the other way round: the child is transparent
// to it, so the XAML control underneath keeps selection, the wheel, links
// and the context menu.

using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.System;

namespace TetherApp;

/// <summary>A Win32 child window sized to a XAML element.</summary>
public sealed class ChildHwnd : IDisposable
{
    private const int WS_CHILD = 0x4000_0000;
    private const int WS_VISIBLE = 0x1000_0000;
    private const int WS_CLIPSIBLINGS = 0x0400_0000;
    private const int WS_CLIPCHILDREN = 0x0200_0000;
    private const int CS_HREDRAW = 0x0002;
    private const int CS_VREDRAW = 0x0001;
    private const int WM_NCHITTEST = 0x0084;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_CHAR = 0x0102;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSCHAR = 0x0106;
    private const int HTTRANSPARENT = -1;
    private const int SW_HIDE = 0;
    private const int SW_SHOWNA = 8;

    // Filled with the palette background so an unpainted frame is a
    // terminal and not a missing control. COLORREF is 0x00BBGGRR: the
    // palette's dark is #12141A, so B=0x1A G=0x14 R=0x12.
    private static readonly nint TerminalBrush = CreateSolidBrush(0x001A1412);

    private static bool _classRegistered;
    private static nint _module;
    private static WndProc? _proc;

    // One window class, one procedure, a child per tab: the procedure finds
    // the tab by handle. A single static callback sends every tab's keys to
    // whichever tab was opened last.
    private static readonly Dictionary<nint, ChildHwnd> Live = [];

    private nint _hwnd;
    private readonly Action<string> _onText;
    private readonly Func<VirtualKey, bool> _onKey;
    private char _highSurrogate;
    private bool _keyTaken;

    private ChildHwnd(Action<string> onText, Func<VirtualKey, bool> onKey)
    {
        _onText = onText;
        _onKey = onKey;
    }

    /// <summary>The handle to hand to the renderer. Zero until the child exists.</summary>
    public nint Handle => _hwnd;

    public bool IsAlive => _hwnd != 0;

    /// <summary>
    /// Creates the child inside <paramref name="parent"/>, filling
    /// <paramref name="host"/>. Text typed here is handed to
    /// <paramref name="onText"/>; every key press is offered to
    /// <paramref name="onKey"/> first, and one it takes produces no text.
    /// </summary>
    public static ChildHwnd Create(
        nint parent,
        FrameworkElement host,
        Action<string> onText,
        Func<VirtualKey, bool> onKey)
    {
        RegisterClass();
        var child = new ChildHwnd(onText, onKey);
        child._hwnd = CreateWindowEx(
            0,
            "TetherTerminal",
            "",
            WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
            0, 0, 1, 1,
            parent,
            0,
            _module,
            0);
        if (child._hwnd == 0)
        {
            throw new InvalidOperationException(
                $"CreateWindowEx failed: {Marshal.GetLastWin32Error()}");
        }
        Live[child._hwnd] = child;
        child.Fit(host);
        child.Show();
        return child;
    }

    /// <summary>Moves the child to cover <paramref name="host"/> in device pixels.</summary>
    public void Fit(FrameworkElement host)
    {
        if (_hwnd == 0) return;
        var scale = GetScale(host);
        var transform = host.TransformToVisual(null);
        var origin = transform.TransformPoint(new Windows.Foundation.Point(0, 0));
        var x = (int)Math.Round(origin.X * scale);
        var y = (int)Math.Round(origin.Y * scale);
        var w = Math.Max(1, (int)Math.Round(host.ActualWidth * scale));
        var h = Math.Max(1, (int)Math.Round(host.ActualHeight * scale));
        MoveWindow(_hwnd, x, y, w, h, true);
    }

    /// <summary>
    /// Shows the child above its siblings. A tab that is not selected keeps
    /// its child, hidden — otherwise the last tab opened paints over the one
    /// being looked at.
    /// </summary>
    public void Show()
    {
        if (_hwnd == 0) return;
        SetWindowPos(_hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        ShowWindow(_hwnd, SW_SHOWNA);
    }

    public void Hide()
    {
        if (_hwnd != 0) ShowWindow(_hwnd, SW_HIDE);
    }

    /// <summary>
    /// Gives the child keyboard focus. `WM_CHAR` only arrives at the window
    /// that has it — a terminal that cannot be typed at is a terminal that
    /// is not running.
    /// </summary>
    public void Focus()
    {
        if (_hwnd != 0) SetFocus(_hwnd);
    }

    /// <summary>The child's size in device pixels.</summary>
    public (int Width, int Height) Size
    {
        get
        {
            if (!GetClientRect(_hwnd, out var rect)) return (1, 1);
            return (Math.Max(1, rect.Right - rect.Left), Math.Max(1, rect.Bottom - rect.Top));
        }
    }

    private static double GetScale(FrameworkElement host) =>
        host.XamlRoot?.RasterizationScale ?? 1.0;

    public void Dispose()
    {
        if (_hwnd != 0)
        {
            Live.Remove(_hwnd);
            DestroyWindow(_hwnd);
            _hwnd = 0;
        }
    }

    private static void RegisterClass()
    {
        if (_classRegistered) return;
        _module = GetModuleHandle(null);
        _proc = WindowProc;
        var wc = new WndClass
        {
            style = CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate<WndProc>(_proc),
            hInstance = _module,
            hbrBackground = TerminalBrush,
            lpszClassName = "TetherTerminal",
        };
        var atom = RegisterClass(ref wc);
        if (atom == 0 && Marshal.GetLastWin32Error() != 1410 /* already registered */)
        {
            throw new InvalidOperationException(
                $"RegisterClass failed: {Marshal.GetLastWin32Error()}");
        }
        _classRegistered = true;
    }

    /// <summary>
    /// The render window is the input window. `WM_KEYDOWN` is offered to the
    /// terminal first — named keys and chords are decided there, from the
    /// virtual key; `WM_CHAR` carries the text of everything else.
    /// </summary>
    private static nint WindowProc(nint hWnd, uint msg, nint wParam, nint lParam)
    {
        if (!Live.TryGetValue(hWnd, out var child))
        {
            return DefWindowProc(hWnd, msg, wParam, lParam);
        }

        switch (msg)
        {
            case WM_NCHITTEST:
                // The pointer belongs to the XAML control underneath.
                return HTTRANSPARENT;
            case WM_KEYDOWN:
            case WM_SYSKEYDOWN:
                child._keyTaken = child._onKey((VirtualKey)(int)(wParam & 0xFFFF));
                if (child._keyTaken) return 0;
                break;
            case WM_CHAR:
                child.Text((char)(wParam & 0xFFFF));
                return 0;
            case WM_SYSCHAR:
                // Alt+letter was sent from WM_SYSKEYDOWN. Letting this through
                // rings the bell; Alt+Space still opens the window menu.
                if ((char)(wParam & 0xFFFF) != ' ') return 0;
                break;
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    /// <summary>
    /// One UTF-16 unit of typed text. A control character whose key press
    /// was taken was already sent as that key; one that was not — Ctrl+[,
    /// say — goes through as it is. Surrogate halves are joined so the
    /// session is handed a whole scalar (spec §12).
    /// </summary>
    private void Text(char ch)
    {
        if (char.IsHighSurrogate(ch))
        {
            _highSurrogate = ch;
            return;
        }
        if (char.IsLowSurrogate(ch))
        {
            if (_highSurrogate != '\0') _onText(new string([_highSurrogate, ch]));
            _highSurrogate = '\0';
            return;
        }
        _highSurrogate = '\0';
        if ((ch < ' ' || ch == '\x7F') && _keyTaken) return;
        _onText(ch.ToString());
    }

    private delegate nint WndProc(nint hWnd, uint msg, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClass
    {
        public int style;
        public nint lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public nint hInstance;
        public nint hIcon;
        public nint hCursor;
        public nint hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClass(ref WndClass lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(
        int dwExStyle, string lpClassName, string lpWindowName, int dwStyle,
        int x, int y, int nWidth, int nHeight,
        nint hWndParent, nint hMenu, nint hInstance, nint lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool MoveWindow(nint hWnd, int x, int y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(nint hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(nint hWnd, out Rect lpRect);

    [DllImport("user32.dll")]
    private static extern nint DefWindowProc(nint hWnd, uint msg, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    private static extern nint SetFocus(nint hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint hWnd, int nCmdShow);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandle(string? lpModuleName);

    private static readonly nint HWND_TOP = 0;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOACTIVATE = 0x0010;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    [DllImport("gdi32.dll")]
    private static extern nint CreateSolidBrush(int color);
}
