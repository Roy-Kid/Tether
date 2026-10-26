using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;
using System.Runtime.InteropServices;

namespace TetherApp;

/// <summary>Native window material and the terminal's matching background tint.</summary>
internal static class WindowEffects
{
    private static readonly UISettings Ui = new();
    private static readonly AccessibilitySettings Accessibility = new();
    private static bool _advancedEffects = Ui.AdvancedEffectsEnabled;
    private static bool _highContrast = Accessibility.HighContrast;

    // Fixed for the process so a live surface never changes its HWND contract.
    // Explicit diagnostic backend overrides retain the opaque compatibility path.
    public static bool CompositionSurface { get; } =
        (Environment.GetEnvironmentVariable("WGPU_BACKEND")?.Trim().ToLowerInvariant() is null or "" or "dx12") &&
        (Environment.GetEnvironmentVariable("WGPU_DX12_PRESENTATION_SYSTEM")?.Trim().ToLowerInvariant() is null or "" or "visual" or "dxgifromvisual");

    private static string Material => AppSettings.Current.WindowMaterial is "mica" or "solid"
        ? AppSettings.Current.WindowMaterial : "acrylic";

    public static double Opacity => WorkspaceAppearance.Opacity(
        Material != "solid" && CompositionSurface, AppSettings.Current.BackgroundOpacity,
        !_advancedEffects, _highContrast);

    public static void Apply(Window window)
    {
        switch (Material)
        {
            case "acrylic" when window.SystemBackdrop is not DesktopAcrylicBackdrop:
                window.SystemBackdrop = new DesktopAcrylicBackdrop();
                break;
            case "mica" when window.SystemBackdrop is not MicaBackdrop:
                window.SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
                break;
            case "solid":
                window.SystemBackdrop = null;
                break;
        }
    }

    public static void Observe(Window window, FrameworkElement root, Action refresh)
    {
        var closed = false;
        var queued = false;
        void Dispatch()
        {
            if (closed || queued) return;
            queued = true;
            if (!window.DispatcherQueue.TryEnqueue(() =>
            {
                queued = false;
                if (closed) return;
                _advancedEffects = Ui.AdvancedEffectsEnabled;
                _highContrast = Accessibility.HighContrast;
                refresh();
            })) queued = false;
        }
        nint hwnd = 0;
        const nuint observerId = 0x5745;
        // WinRT contrast/color events depend on CoreWindow. Desktop windows
        // receive native broadcasts for contrast, transparency and theme changes.
        SubclassProc? procedure = null;
        procedure = (handle, message, wParam, lParam, id, data) =>
        {
            if (message is 0x0015 or 0x001A or 0x031A) Dispatch(); // system colors, settings, theme
            if (message == 0x0082) // WM_NCDESTROY
            {
                closed = true;
                RemoveWindowSubclass(handle, procedure!, id);
            }
            return DefSubclassProc(handle, message, wParam, lParam);
        };
        void Attach(object? sender, RoutedEventArgs args)
        {
            if (closed || hwnd != 0) return;
            // WinUI installs its titlebar/window procedures during initial
            // layout. Attach after that work so our observer stays in the chain.
            hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            if (!SetWindowSubclass(hwnd, procedure, observerId, 0))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not observe window appearance changes");
        }
        if (root.IsLoaded) Attach(null, new RoutedEventArgs());
        else root.Loaded += Attach;
        window.Closed += (_, _) =>
        {
            closed = true;
            root.Loaded -= Attach;
            if (hwnd != 0) RemoveWindowSubclass(hwnd, procedure, observerId);
        };
    }

    private delegate nint SubclassProc(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data);
    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(nint hwnd, SubclassProc procedure, nuint id, nuint data);
    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc procedure, nuint id);
    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint hwnd, uint message, nint wParam, nint lParam);
}
