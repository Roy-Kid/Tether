using System.Runtime.InteropServices;

namespace TetherApp;

public static class ShellActivity
{
    public static async Task<string?> CloseNoteAsync(SessionModel model)
    {
        if (!model.IsLive) return null;
        try
        {
            if (!model.IsRemote && !model.IsWsl && model.LocalProcessId is { } pid)
            {
                var names = await Task.Run(() => LocalChildren(pid));
                return names.Length == 0 ? null : "Running: " + string.Join(", ", names);
            }
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var text = await model.ExecuteAsync(
                "printf '%s\\n' TETHER-PROCESSES; LC_ALL=C ps -ax -o pid= -o ppid= -o tty= -o stat= -o comm= && printf '%s\\n' TETHER-PROCESSES-END",
                timeout.Token).WaitAsync(timeout.Token);
            return RemoteNote(text, await ShellTTY.FindAsync(model, timeout.Token));
        }
        catch { return "Unable to check running processes."; }
    }

    public static string? RemoteNote(string text, string? terminal) => ProcessTable.CloseNote(text, terminal);

    private static string[] LocalChildren(uint shell)
    {
        var snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == -1) throw new IOException("Process list unavailable.");
        try
        {
            var row = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>(), Name = "" };
            var rows = new List<ProcessEntry>();
            if (!Process32First(snapshot, ref row)) throw new IOException("Process list unavailable.");
            do { rows.Add(row); row.Size = (uint)Marshal.SizeOf<ProcessEntry>(); } while (Process32Next(snapshot, ref row));
            if (!rows.Any(r => r.Id == shell)) throw new IOException("Shell process unavailable.");
            var owned = new HashSet<uint> { shell };
            bool changed;
            do { changed = false; foreach (var item in rows) if (owned.Contains(item.Parent)) changed |= owned.Add(item.Id); } while (changed);
            return rows.Where(r => r.Id != shell && owned.Contains(r.Id) &&
                !r.Name.Equals("conhost.exe", StringComparison.OrdinalIgnoreCase) &&
                !r.Name.Equals("OpenConsole.exe", StringComparison.OrdinalIgnoreCase))
                .Select(r => r.Name).Distinct().Order().ToArray();
        }
        finally { CloseHandle(snapshot); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size, Usage, Id;
        public nuint Heap;
        public uint Module, Threads, Parent;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
    }
    [DllImport("kernel32.dll")] private static extern nint CreateToolhelp32Snapshot(uint flags, uint id);
    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32First(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32Next(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(nint handle);
}
