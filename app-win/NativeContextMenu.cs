using System.Runtime.InteropServices;

namespace TetherApp;

/// <summary>A native popup stays above the terminal HWND without hiding its surface.</summary>
internal static class NativeContextMenu
{
    public static void Show(nint owner, int x, int y, IReadOnlyList<(string Title, Action Run)> commands)
    {
        var point = new POINT { X = x, Y = y };
        if (!ClientToScreen(owner, ref point)) return;
        var menu = CreatePopupMenu();
        if (menu == 0) return;
        uint selected;
        try
        {
            for (var i = 0; i < commands.Count; i++)
                AppendMenu(menu, 0, (nuint)(i + 1), commands[i].Title.Replace("&", "&&"));
            selected = TrackPopupMenuEx(menu, 0x0100 | 0x0002, point.X, point.Y, owner, 0);
        }
        finally { DestroyMenu(menu); }
        if (selected > 0 && selected <= commands.Count) commands[(int)selected - 1].Run();
    }

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern bool ClientToScreen(nint hwnd, ref POINT point);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenuEx(nint menu, uint flags, int x, int y, nint owner, nint parameters);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(nint menu);
}
