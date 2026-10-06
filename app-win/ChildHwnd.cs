// A child `HWND` that covers the terminal's rectangle, and nothing else.
//
// wgpu draws to a window handle. The host window's handle is the whole
// window — chrome included — so the surface has to be a child that sits in
// the terminal's place. A `SwapChainPanel` would be the other way in, and is
// the next refinement; this is the one that works with the Vulkan/GLES
// backends Decisions/0017 ships while `dx12` is out.
//
// The child paints and receives keys and the pointer. XAML's
// `CharacterReceived` never fires for a control sitting under an HWND, and
// neither do its pointer events: WinUI turns the mouse into pointer
// messages, which are delivered to the window that hit-tests as the client.
// Returning HTTRANSPARENT dropped the wheel and the drag on the floor —
// the island underneath never saw them. The child handles both and hands
// them to the session.

using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.System;

namespace TetherApp;

/// <summary>What the pointer did, in the child window's client pixels.</summary>
public enum ChildPointerKind { LeftDown, Move, LeftUp, RightDown, RightUp, MiddleDown, MiddleUp, Wheel }

/// <summary>One pointer message from the render window. <see cref="X"/> and <see cref="Y"/> are client pixels; <see cref="Delta"/> is the wheel notch in the units Windows reports (usually ±120).</summary>
public readonly record struct ChildPointer(ChildPointerKind Kind, int X, int Y, int Delta);

/// <summary>A Win32 child window sized to a XAML element.</summary>
public sealed class ChildHwnd : IDisposable
{
    private const int WS_CHILD = 0x4000_0000;
    private const int WS_VISIBLE = 0x1000_0000;
    private const int WS_CLIPSIBLINGS = 0x0400_0000;
    private const int WS_CLIPCHILDREN = 0x0200_0000;
    private const int WM_MOUSEMOVE = 0x0200;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MBUTTONUP = 0x0208;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_CHAR = 0x0102;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSCHAR = 0x0106;
    private const int WM_POINTERUPDATE = 0x0245;
    private const int WM_POINTERDOWN = 0x0246;
    private const int WM_POINTERUP = 0x0247;
    private const int WM_POINTERWHEEL = 0x024E;
    private const int POINTER_FLAG_SECONDBUTTON = 0x0020;
    private const int SW_HIDE = 0;
    private static readonly nint IDC_IBEAM = 32513;
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
    private int _x = int.MinValue, _y, _w, _h;
    private readonly Action<string> _onText;
    private readonly Func<VirtualKey, bool> _onKey;
    private Action<ChildPointer>? _onPointer;
    /// <summary>WinUI delivers the mouse as pointer messages and suppresses the mouse ones. Once a pointer message has arrived, the mouse copies are ignored so a click is not counted twice.</summary>
    private bool _pointerInput;
    private char _highSurrogate;
    private bool _keyTaken;

    private ChildHwnd(Action<string> onText, Func<VirtualKey, bool> onKey, Action<ChildPointer>? onPointer)
    {
        _onText = onText;
        _onKey = onKey;
        _onPointer = onPointer;
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
        Func<VirtualKey, bool> onKey,
        Action<ChildPointer>? onPointer = null)
    {
        RegisterClass();
        var child = new ChildHwnd(onText, onKey, onPointer);
        child._hwnd = CreateWindowEx(
            // Not WS_EX_NOREDIRECTIONBITMAP. This host draws with Vulkan or
            // GL, and that style makes those presents go nowhere — a live
            // shell with a blank window.
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
        if (scale <= 0) scale = 1;
        var origin = host.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
        // Snap the edges, not the width. Rounding width and origin separately
        // at 150% or 175% makes the rectangle flip by a pixel every layout,
        // which reads as the terminal shaking inside the frame.
        int Snap(double dip) => (int)Math.Round(dip * scale, MidpointRounding.AwayFromZero);
        var x = Snap(origin.X);
        var y = Snap(origin.Y);
        var w = Math.Max(1, Snap(origin.X + host.ActualWidth) - x);
        var h = Math.Max(1, Snap(origin.Y + host.ActualHeight) - y);
        // A one-pixel flip at 150% or 200% is the terminal shaking inside the
        // frame. A real drag moves by more than that between messages.
        if (_x != int.MinValue
            && Math.Abs(x - _x) <= 1 && Math.Abs(y - _y) <= 1
            && Math.Abs(w - _w) <= 1 && Math.Abs(h - _h) <= 1)
            return;
        if (x == _x && y == _y && w == _w && h == _h) return;
        _x = x;
        _y = y;
        _w = w;
        _h = h;
        SetWindowPos(_hwnd, 0, x, y, w, h,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW | SWP_NOCOPYBITS);
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
            // Not CS_HREDRAW | CS_VREDRAW: those invalidate the whole window
            // on every pixel of a drag, which is the flicker under the swap chain.
            style = 0,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate<WndProc>(_proc),
            hInstance = _module,
            hCursor = LoadCursor(0, IDC_IBEAM),
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
            case WM_POINTERWHEEL:
                child._pointerInput = true;
                child.DispatchPointer(hWnd, ChildPointerKind.Wheel, lParam, screenPoint: true, (short)(wParam >> 16));
                return 0;
            case WM_POINTERDOWN:
                child._pointerInput = true;
                // The right button opens the menu on release, the same moment
                // XAML's RightTapped fires. A down must not also start a drag.
                if (PointerButton(wParam) == PointerButtonKind.Right)
                { child.DispatchPointer(hWnd, ChildPointerKind.RightDown, lParam, screenPoint: true); return 0; }
                if (PointerButton(wParam) == PointerButtonKind.Middle)
                { child.DispatchPointer(hWnd, ChildPointerKind.MiddleDown, lParam, screenPoint: true); return 0; }
                SetCapture(hWnd);
                child.DispatchPointer(hWnd, ChildPointerKind.LeftDown, lParam, screenPoint: true);
                return 0;
            case WM_POINTERUP:
                child._pointerInput = true;
                var up = PointerButton(wParam) == PointerButtonKind.Right
                    ? ChildPointerKind.RightUp
                    : PointerButton(wParam) == PointerButtonKind.Middle ? ChildPointerKind.MiddleUp : ChildPointerKind.LeftUp;
                if (up == ChildPointerKind.LeftUp) ReleaseCapture();
                child.DispatchPointer(hWnd, up, lParam, screenPoint: true);
                return 0;
            case WM_POINTERUPDATE:
                child._pointerInput = true;
                child.DispatchPointer(hWnd, ChildPointerKind.Move, lParam, screenPoint: true);
                return 0;
            case WM_MOUSEWHEEL when !child._pointerInput:
                child.DispatchPointer(hWnd, ChildPointerKind.Wheel, lParam, screenPoint: true, (short)(wParam >> 16));
                return 0;
            case WM_LBUTTONDOWN when !child._pointerInput:
                SetCapture(hWnd);
                child.DispatchPointer(hWnd, ChildPointerKind.LeftDown, lParam, screenPoint: false);
                return 0;
            case WM_LBUTTONUP when !child._pointerInput:
                ReleaseCapture();
                child.DispatchPointer(hWnd, ChildPointerKind.LeftUp, lParam, screenPoint: false);
                return 0;
            case WM_MOUSEMOVE when !child._pointerInput:
                child.DispatchPointer(hWnd, ChildPointerKind.Move, lParam, screenPoint: false);
                return 0;
            case WM_RBUTTONDOWN when !child._pointerInput:
                child.DispatchPointer(hWnd, ChildPointerKind.RightDown, lParam, screenPoint: false); return 0;
            case WM_MBUTTONDOWN when !child._pointerInput:
                child.DispatchPointer(hWnd, ChildPointerKind.MiddleDown, lParam, screenPoint: false); return 0;
            case WM_MBUTTONUP when !child._pointerInput:
                child.DispatchPointer(hWnd, ChildPointerKind.MiddleUp, lParam, screenPoint: false); return 0;
            case WM_RBUTTONUP when !child._pointerInput:
                child.DispatchPointer(hWnd, ChildPointerKind.RightUp, lParam, screenPoint: false);
                return 0;
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

    private void DispatchPointer(nint hwnd, ChildPointerKind kind, nint lParam, bool screenPoint, int delta = 0)
    {
        var point = new Point
        {
            X = (short)(lParam & 0xffff),
            Y = (short)((lParam >> 16) & 0xffff),
        };
        if (screenPoint) ScreenToClient(hwnd, ref point);
        _onPointer?.Invoke(new ChildPointer(kind, point.X, point.Y, delta));
    }

    /// <summary>Which button a pointer message names. The wheel's high word is a delta, not these flags.</summary>
    private static PointerButtonKind PointerButton(nint wParam)
    {
        var flags = (int)((wParam >> 16) & 0xffff);
        return (flags & POINTER_FLAG_SECONDBUTTON) != 0 ? PointerButtonKind.Right : (flags & 0x0040) != 0 ? PointerButtonKind.Middle : PointerButtonKind.Left;
    }

    private enum PointerButtonKind { Left, Right, Middle }

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
        if (_keyTaken) return;
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

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }
    [DllImport("user32.dll")]
    private static extern bool ScreenToClient(nint hwnd, ref Point point);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClass(ref WndClass lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(
        int dwExStyle, string lpClassName, string lpWindowName, int dwStyle,
        int x, int y, int nWidth, int nHeight,
        nint hWndParent, nint hMenu, nint hInstance, nint lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(nint hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(nint hWnd, out Rect lpRect);

    [DllImport("user32.dll")]
    private static extern nint DefWindowProc(nint hWnd, uint msg, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    private static extern nint SetFocus(nint hWnd);

    [DllImport("user32.dll")]
    private static extern nint LoadCursor(nint hInstance, nint lpCursorName);

    [DllImport("user32.dll")]
    private static extern nint SetCapture(nint hWnd);

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint hWnd, int nCmdShow);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandle(string? lpModuleName);

    private static readonly nint HWND_TOP = 0;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOREDRAW = 0x0008;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_NOCOPYBITS = 0x0100;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    [DllImport("gdi32.dll")]
    private static extern nint CreateSolidBrush(int color);
}
