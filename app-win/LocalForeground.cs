using System.Diagnostics;
using System.Runtime.InteropServices;

namespace TetherApp;

/// <summary>The program in front of a local shell, for the terminal's chip.</summary>
public static class LocalForeground
{
    /// <summary>Waiting shells are the prompt, not work. The same set the close check uses.</summary>
    public static readonly HashSet<string> Shells = new(StringComparer.OrdinalIgnoreCase)
    {
        "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "ksh93", "mksh", "csh", "tcsh",
        "nu", "elvish", "xonsh", "cmd", "powershell", "pwsh", "powershell_ise",
    };

    /// <summary>Nil when <paramref name="shellPid"/> is the foreground, or when this machine cannot say.</summary>
    public static string? Command(uint? shellPid)
    {
        if (shellPid is not { } pid || pid == 0) return null;
        try
        {
            foreach (var child in Children(pid))
            {
                var bare = Path.GetFileNameWithoutExtension(child);
                if (bare.StartsWith('-')) bare = bare[1..];
                if (bare.Length == 0 || Shells.Contains(bare)) continue;
                return bare;
            }
        }
        catch { /* process table can race */ }
        return null;
    }

    /// <summary><paramref name="foreground"/> matches the shell's group while the prompt is waiting.</summary>
    public static string? Picked(uint shellPgid, uint foreground, string? leader)
    {
        if (foreground == 0 || foreground == shellPgid) return null;
        if (leader is null) return null;
        var bare = Path.GetFileName(leader.Replace('\\', '/'));
        if (bare.StartsWith('-')) bare = bare[1..];
        if (bare.Length == 0 || Shells.Contains(bare)) return null;
        return bare;
    }

    private static IEnumerable<string> Children(uint parent)
    {
        var snap = CreateToolhelp32Snapshot(2, 0);
        if (snap == nint.Zero || snap == (nint)(-1)) yield break;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            if (!Process32First(snap, ref entry)) yield break;
            do
            {
                if (entry.ParentProcessId != parent) continue;
                string name;
                try { name = Process.GetProcessById((int)entry.ProcessId).ProcessName; }
                catch { name = entry.ExeFile; }
                yield return name;
            } while (Process32Next(snap, ref entry));
        }
        finally { CloseHandle(snap); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public nuint DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriClassBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Process32First(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Process32Next(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
}
