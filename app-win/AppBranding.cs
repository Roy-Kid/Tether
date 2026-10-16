using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace TetherApp;

internal static class AppBranding
{
    private static readonly Lazy<nint> Icon = new(LoadIcon);

    public static void Initialize() =>
        Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID("Roy-Kid.Tether"));

    public static void Apply(Window window) =>
        window.AppWindow.SetIcon(Microsoft.UI.Win32Interop.GetIconIdFromIcon(Icon.Value));

    private static nint LoadIcon()
    {
        // The EXE and windows share one embedded ICO, with no loose asset.
        using var stream = typeof(AppBranding).Assembly.GetManifestResourceStream("TetherApp.Icon")
            ?? throw new InvalidOperationException("Missing application icon.");
        using var reader = new BinaryReader(stream);
        if (reader.ReadUInt16() != 0 || reader.ReadUInt16() != 1)
            throw new InvalidDataException("Invalid application icon.");
        var count = reader.ReadUInt16();
        uint length = 0, offset = 0;
        var largest = 0;
        for (var index = 0; index < count; index++)
        {
            var width = reader.ReadByte();
            reader.ReadBytes(7);
            var entryLength = reader.ReadUInt32();
            var entryOffset = reader.ReadUInt32();
            var size = width == 0 ? 256 : width;
            if (size <= largest) continue;
            largest = size;
            length = entryLength;
            offset = entryOffset;
        }
        stream.Position = offset;
        var data = reader.ReadBytes(checked((int)length));
        var icon = CreateIconFromResourceEx(data, (uint)data.Length, true, 0x00030000, 0, 0, 0);
        if (icon == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        // One process-lifetime shared handle for all windows.
        return icon;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint CreateIconFromResourceEx(byte[] data, uint size,
        [MarshalAs(UnmanagedType.Bool)] bool icon, uint version, int width, int height, uint flags);
}
