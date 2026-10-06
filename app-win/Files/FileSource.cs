using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Tether;

namespace TetherApp.Files;

// Only the boundary differs: SSH uses the existing SFTP lease; Windows and
// WSL's Windows file provider do not require an installed OpenSSH server.
internal interface IFileSource : IAsyncDisposable
{
    string Combine(string directory, string name);
    string Parent(string path);
    string ShellPath(string path);
    Task<string> HomeAsync();
    Task<IReadOnlyList<FileEntry>> ListAsync(string path, CancellationToken token);
    Task<FileEntry> StatAsync(string path, bool followLinks = true);
    Task MakeDirectoryAsync(string path);
    Task RenameAsync(string from, string to);
    Task RemoveTreeAsync(string path, CancellationToken token);
    Task UploadAsync(string source, string path, bool replace, IProgress<ulong> progress, CancellationToken token);
    Task DownloadAsync(string path, string destination, IProgress<ulong> progress, CancellationToken token);
}

internal sealed class SftpSource(RemoteFiles files) : IFileSource
{
    public string Combine(string directory, string name) => directory.TrimEnd('/') + "/" + name;
    public string Parent(string path) { var i = path.TrimEnd('/').LastIndexOf('/'); return i <= 0 ? "/" : path[..i]; }
    public string ShellPath(string path) => path;
    public Task<string> HomeAsync() => files.HomeAsync();
    public Task<IReadOnlyList<FileEntry>> ListAsync(string path, CancellationToken token) => files.ListAsync(path, token);
    public Task<FileEntry> StatAsync(string path, bool followLinks = true) => files.StatAsync(path, followLinks);
    public Task MakeDirectoryAsync(string path) => files.MakeDirectoryAsync(path);
    public Task RenameAsync(string from, string to) => files.RenameAsync(from, to);
    public Task RemoveTreeAsync(string path, CancellationToken token) => files.RemoveTreeAsync(path, token);
    public Task UploadAsync(string source, string path, bool replace, IProgress<ulong> progress, CancellationToken token) => files.UploadAsync(source, path, replace, progress, token);
    public Task DownloadAsync(string path, string destination, IProgress<ulong> progress, CancellationToken token) => files.DownloadAsync(path, destination, progress, token);
    public ValueTask DisposeAsync() => files.DisposeAsync();
}

internal sealed class LocalFileSource(string home, string? wslRoot = null) : IFileSource
{
    public static async Task<LocalFileSource> CreateAsync(bool wsl, CancellationToken token, string? distribution = null)
    {
        if (!wsl) return new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        // ArgumentList avoids shell parsing. These fixed queries use the same
        // default distribution as the supported `wsl` terminal profile.
        var distro = await WslAsync("printenv", "WSL_DISTRO_NAME", token, distribution);
        var linuxHome = await WslAsync("printenv", "HOME", token, distro);
        if (string.IsNullOrWhiteSpace(distro) || distro.IndexOfAny(['/', '\\', '\r', '\n']) >= 0 || !linuxHome.StartsWith('/'))
            throw new IOException("Could not find the default WSL distribution.");
        var root = @"\\wsl.localhost\" + distro;
        return new(root + linuxHome.Replace('/', '\\'), root);
    }
    private static async Task<string> WslAsync(string program, string argument, CancellationToken token, string? distribution)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "wsl.exe"))
        { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        if (distribution is not null) { start.ArgumentList.Add("--distribution"); start.ArgumentList.Add(distribution); }
        start.ArgumentList.Add("--exec"); start.ArgumentList.Add(program); start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("WSL could not start.");
        using var registration = token.Register(() => { try { process.Kill(true); } catch (InvalidOperationException) { } });
        var output = process.StandardOutput.ReadToEndAsync(token);
        var error = process.StandardError.ReadToEndAsync(token);
        await process.WaitForExitAsync(token);
        if (process.ExitCode != 0) throw new IOException(await error);
        return (await output).Trim();
    }
    public string Combine(string directory, string name) => Path.Combine(directory, name);
    public string Parent(string path)
    {
        var root = Path.GetPathRoot(path);
        if (root is not null && string.Equals(path.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            return root.TrimEnd('\\') + "\\";
        return Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(path)) ?? root ?? path;
    }
    public string ShellPath(string path)
    {
        if (wslRoot is null) return path;
        // \\wsl.localhost\Distro and \\WSL.LOCALHOST\Distro\ are the same share, and both are `/`.
        var root = wslRoot.TrimEnd('\\');
        if (path.TrimEnd('\\').Equals(root, StringComparison.OrdinalIgnoreCase)) return "/";
        var prefix = root + "\\";
        return path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? path[root.Length..].Replace('\\', '/') : path;
    }
    public string NativePath(string path) => wslRoot is not null && path.StartsWith('/') ? wslRoot.TrimEnd('\\') + path.Replace('/', '\\') : path;
    public Task<string> HomeAsync() => Task.FromResult(home);
    public Task<IReadOnlyList<FileEntry>> ListAsync(string path, CancellationToken token) => Task.Run<IReadOnlyList<FileEntry>>(() =>
    {
        var entries = new List<FileEntry>();
        foreach (var item in new DirectoryInfo(path).EnumerateFileSystemInfos())
        { token.ThrowIfCancellationRequested(); entries.Add(Entry(item, false)); }
        return entries;
    }, token);
    public Task<FileEntry> StatAsync(string path, bool followLinks = true) => Task.Run(() => Entry(new FileInfo(path), followLinks));
    private static FileEntry Entry(FileSystemInfo info, bool follow)
    {
        var attributes = info.Attributes; // Also reports directories through FileInfo.
        if ((int)attributes == -1) throw new FileNotFoundException("File no longer exists.", info.FullName);
        if (follow && attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            var target = info.ResolveLinkTarget(true);
            if (target is not null) attributes = target.Attributes;
        }
        var kind = attributes.HasFlag(FileAttributes.ReparsePoint) && !follow ? FileKind.Link
            : attributes.HasFlag(FileAttributes.Directory) ? FileKind.Directory : FileKind.File;
        return new(info.Name, info.FullName, kind, kind == FileKind.File ? (ulong)new FileInfo(info.FullName).Length : 0,
            (ulong)Math.Max(0, new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeSeconds()), 0);
    }
    public Task MakeDirectoryAsync(string path) => Task.Run(() =>
    {
        // Unlike Directory.CreateDirectory this atomically refuses an existing
        // destination, including a folder created after the conflict prompt.
        if (!CreateDirectoryW(path, 0)) throw new IOException(new Win32Exception(Marshal.GetLastWin32Error()).Message);
    });
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(string path, nint securityAttributes);
    public Task RenameAsync(string from, string to) => Task.Run(() =>
    {
        if (File.GetAttributes(from).HasFlag(FileAttributes.Directory)) Directory.Move(from, to);
        else File.Move(from, to, false);
    });
    public Task RemoveTreeAsync(string path, CancellationToken token) => Task.Run(() => Remove(path, token), token);
    private static void Remove(string path, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var attributes = File.GetAttributes(path);
        if (!attributes.HasFlag(FileAttributes.Directory)) { File.Delete(path); return; }
        if (!attributes.HasFlag(FileAttributes.ReparsePoint))
            foreach (var child in Directory.EnumerateFileSystemEntries(path)) Remove(child, token);
        Directory.Delete(path); // Never recurse through directory links/junctions.
    }
    public Task UploadAsync(string source, string path, bool replace, IProgress<ulong> progress, CancellationToken token) => CopyAsync(source, path, replace, progress, token);
    public Task DownloadAsync(string path, string destination, IProgress<ulong> progress, CancellationToken token) => CopyAsync(path, destination, false, progress, token);
    private static async Task CopyAsync(string source, string destination, bool replace, IProgress<ulong> progress, CancellationToken token)
    {
        if (string.Equals(Path.GetFullPath(source), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
            throw new IOException("The source and destination are the same file.");
        var temporary = Path.Combine(Path.GetDirectoryName(destination)!, ".tether-" + Guid.NewGuid().ToString("N"));
        try
        {
            await using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true))
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                var buffer = new byte[65536]; ulong total = 0;
                int count;
                while ((count = await input.ReadAsync(buffer, token)) != 0)
                { await output.WriteAsync(buffer.AsMemory(0, count), token); total += (ulong)count; progress.Report(total); }
                await output.FlushAsync(token);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, destination, replace);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
