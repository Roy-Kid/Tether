using System.Runtime.InteropServices;

namespace TetherApp;

internal sealed record NativeMenuItem(string Title, Action? Run = null, bool Enabled = true,
    bool Checked = false, IReadOnlyList<NativeMenuItem>? Children = null);

/// <summary>A native popup stays above the terminal HWND without hiding its surface.</summary>
internal static class NativeContextMenu
{
    public static void Show(nint owner, int x, int y, IReadOnlyList<(string Title, Action Run)> commands)
        => Show(owner, x, y, commands.Select(c => new NativeMenuItem(c.Title, c.Run)).ToArray());

    public static void Show(nint owner, int x, int y, IReadOnlyList<NativeMenuItem> commands)
    {
        var point = new POINT { X = x, Y = y };
        if (!ClientToScreen(owner, ref point)) return;
        ShowScreen(owner, point.X, point.Y, commands);
    }

    public static void ShowScreen(nint owner, int x, int y, IReadOnlyList<NativeMenuItem> commands)
    {
        var menu = CreatePopupMenu();
        if (menu == 0) return;
        uint selected;
        var actions = new Dictionary<uint, Action>();
        void Populate(nint target, IReadOnlyList<NativeMenuItem> items)
        {
            foreach (var item in items)
            {
                if (item.Title.Length == 0) { AppendMenu(target, 0x800, 0, ""); continue; }
                var flags = (item.Enabled ? 0u : 1u) | (item.Checked ? 8u : 0u);
                var title = item.Title.Replace("&", "&&");
                if (item.Children is { } children)
                {
                    var submenu = CreatePopupMenu();
                    Populate(submenu, children);
                    AppendMenu(target, flags | 0x10, (nuint)submenu, title);
                }
                else
                {
                    var id = (uint)actions.Count + 1;
                    actions[id] = item.Run ?? (() => { });
                    AppendMenu(target, flags, id, title);
                }
            }
        }
        try
        {
            Populate(menu, commands);
            SetForegroundWindow(owner);
            selected = TrackPopupMenuEx(menu, 0x0100 | 0x0002, x, y, owner, 0);
            PostMessage(owner, 0, 0, 0);
        }
        finally { DestroyMenu(menu); }
        if (actions.TryGetValue(selected, out var run)) run();
    }

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint hwnd, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(nint hwnd, ref POINT point);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenuEx(nint menu, uint flags, int x, int y, nint owner, nint parameters);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(nint menu);
}
