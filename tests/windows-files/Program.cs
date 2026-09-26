using Tether;
using TetherApp.Files;

// No UI or external test runner. Run: dotnet run --project tests/windows-files
var root = Path.Combine(Path.GetTempPath(), "tether-files-test-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    await using var source = new LocalFileSource(root);
    var input = Path.Combine(root, "input.txt");
    await File.WriteAllTextAsync(input, "hello λ files");
    var directory = Path.Combine(root, "folder");
    await source.MakeDirectoryAsync(directory);
    await Refuses(() => source.MakeDirectoryAsync(directory));
    Check((await source.ListAsync(root, default)).Count == 2, "listing");
    Check((await source.StatAsync(directory)).Kind == FileKind.Directory, "directory stat");
    Check((await source.StatAsync(input)).Size == (ulong)new FileInfo(input).Length, "file stat");
    Check(source.Parent(@"C:\") == @"C:\", "drive root parent");
    Check(source.Parent(@"\\server\share\") == @"\\server\share\", "UNC root parent");
    var output = Path.Combine(directory, "copy.txt");
    ulong progress = 0;
    var report = new ByteProgress(bytes => progress = bytes);
    await source.UploadAsync(input, output, false, report, default);
    Check(await File.ReadAllTextAsync(output) == await File.ReadAllTextAsync(input), "copy contents");
    Check(progress == (ulong)new FileInfo(input).Length, "byte progress");
    await File.WriteAllTextAsync(output, "keep me");
    await Refuses(() => source.UploadAsync(input, output, false, report, default));
    Check(await File.ReadAllTextAsync(output) == "keep me", "refuse overwrite");
    Check(!Temps(directory), "refused overwrite removes temporary files");
    await source.UploadAsync(input, output, true, report, default);
    Check(await File.ReadAllTextAsync(output) == await File.ReadAllTextAsync(input), "explicit replace");
    Check(!Temps(directory), "replace removes temporary files");
    await Refuses(() => source.UploadAsync(input, input, true, report, default));
    Check(await File.ReadAllTextAsync(input) == "hello λ files", "same-file upload leaves the file");
    await Refuses(() => source.RenameAsync(input, output));
    Check(File.Exists(input) && await File.ReadAllTextAsync(input) == "hello λ files", "failed rename retains source");
    var renamed = Path.Combine(root, "renamed.txt");
    await source.RenameAsync(input, renamed);
    Check(!File.Exists(input) && File.Exists(renamed), "rename");
    await File.WriteAllBytesAsync(input, new byte[1024 * 1024]);
    using var cancel = new CancellationTokenSource();
    await File.WriteAllTextAsync(output, "original");
    try
    {
        await source.UploadAsync(input, output, true, new ByteProgress(_ => cancel.Cancel()), cancel.Token);
        throw new Exception("Cancellation was ignored");
    }
    catch (OperationCanceledException) { }
    Check(await File.ReadAllTextAsync(output) == "original", "cancel preserves destination");
    Check(!Temps(directory), "cancel removes temporary files");
    var never = Path.Combine(directory, "never.txt");
    using (var abandoned = new CancellationTokenSource())
    {
        abandoned.Cancel();
        await Cancelled(() => source.UploadAsync(input, never, false, report, abandoned.Token));
    }
    Check(!File.Exists(never) && !Temps(directory), "cancel before copy publishes nothing");
    var download = Path.Combine(root, "download.txt");
    await source.DownloadAsync(output, download, report, default);
    await Refuses(() => source.DownloadAsync(output, download, report, default));
    Check(await File.ReadAllTextAsync(download) == "original", "download refuses overwrite");
    Check(!Temps(root), "refused download removes temporary files");
    var partial = Path.Combine(root, "partial.txt");
    using (var downloadCancel = new CancellationTokenSource())
    {
        await Cancelled(() => source.DownloadAsync(input, partial, new ByteProgress(_ => downloadCancel.Cancel()), downloadCancel.Token));
    }
    Check(!File.Exists(partial) && !Temps(root), "cancelled download leaves no partial file");

    // Junctions need no elevation, unlike Windows symbolic links. Recursive
    // Directory.Delete follows them; removal must delete the link only.
    var outside = Path.Combine(root, "outside"); Directory.CreateDirectory(outside);
    var kept = Path.Combine(outside, "keep.txt");
    await File.WriteAllTextAsync(kept, "survive");
    var nested = Path.Combine(directory, "nested");
    await source.MakeDirectoryAsync(nested);
    await File.WriteAllTextAsync(Path.Combine(nested, "gone.txt"), "gone");
    await File.WriteAllTextAsync(Path.Combine(directory, "marker.txt"), "marker");
    var junction = Path.Combine(nested, "escape");
    Junction(junction, outside);
    var fileLink = Path.Combine(directory, "file-link");
    var directoryLink = Path.Combine(nested, "dir-link");
    var fileSymlink = TrySymlink(fileLink, kept);
    var directorySymlink = TrySymlink(directoryLink, outside, directory: true);
    Check((await source.StatAsync(junction, false)).Kind == FileKind.Link, "lstat junction");
    Check((await source.StatAsync(junction)).Kind == FileKind.Directory, "stat junction target");
    if (fileSymlink)
    {
        Check((await source.StatAsync(fileLink, false)).Kind == FileKind.Link, "lstat file symlink");
        Check((await source.StatAsync(fileLink)).Kind == FileKind.File, "stat file symlink target");
    }
    if (directorySymlink)
        Check((await source.StatAsync(directoryLink, false)).Kind == FileKind.Link, "lstat directory symlink");
    await source.RemoveTreeAsync(junction, default);
    Check(!Directory.Exists(junction) && Directory.Exists(outside) && File.Exists(kept), "deleting a junction removes the link only");
    Check(File.Exists(Path.Combine(directory, "marker.txt")), "deleting a junction leaves its parent");
    Junction(junction, outside);
    await source.RemoveTreeAsync(directory, default);
    Check(!Directory.Exists(directory), "recursive delete removes the real tree");
    Check(File.Exists(kept) && await File.ReadAllTextAsync(kept) == "survive", "recursive delete does not follow links");
    var wsl = new LocalFileSource(@"\\wsl.localhost\Test\home\user", @"\\wsl.localhost\Test");
    Check(wsl.ShellPath(@"\\wsl.localhost\Test\home\user") == "/home/user", "WSL shell path");
    Check(wsl.ShellPath(@"\\WSL.LOCALHOST\Test\tmp\data") == "/tmp/data", "WSL shell path ignores case");
    Check(wsl.ShellPath(@"\\wsl.localhost\Test") == "/", "WSL root");
    Check(wsl.ShellPath(@"\\wsl.localhost\Test\") == "/", "WSL root trailing separator");
    Check(wsl.ShellPath(@"\\wsl.localhost\Test2\home") == @"\\wsl.localhost\Test2\home", "another distro stays a Windows path");
    Check(wsl.ShellPath(@"C:\Temp\data") == @"C:\Temp\data", "a Windows path is not a WSL path");
    Check(wsl.NativePath("/tmp/data") == @"\\wsl.localhost\Test\tmp\data", "WSL native path");
    Check(wsl.NativePath("/") == @"\\wsl.localhost\Test\", "WSL native root");
    Check(wsl.NativePath(@"C:\Temp\data") == @"C:\Temp\data", "Windows path is already native");
    Check(wsl.NativePath("relative") == "relative", "relative path is unchanged");
    Check(wsl.ShellPath(wsl.NativePath("/home/user")) == "/home/user", "WSL round trip");
    Check(wsl.ShellPath(wsl.NativePath("/")) == "/", "WSL root round trip");
    Check(wsl.ShellPath(wsl.Parent(@"\\wsl.localhost\Test\")) == "/", "parent of the share root stays /");
    if (args.Contains("--wsl"))
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        await using var live = await LocalFileSource.CreateAsync(true, timeout.Token);
        var home = await live.HomeAsync();
        Check(live.ShellPath(home).StartsWith('/'), "live WSL home mapping");
        await live.ListAsync(home, timeout.Token);
        Console.WriteLine("PASS: default WSL home listing (read only)");
    }
    Check(!Temps(root), "no temporary files remain");
    Console.WriteLine("PASS: local files, overwrite, rename, cancellation, atomic cleanup, link deletion, WSL paths");
}
finally
{
    // Known unique test root; use the tested non-link-following removal.
    if (Directory.Exists(root))
    {
        await using var cleanup = new LocalFileSource(root);
        await cleanup.RemoveTreeAsync(root, default);
    }
}
static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static bool Temps(string directory) => Directory.Exists(directory) && Directory.EnumerateFiles(directory, ".tether-*", SearchOption.AllDirectories).Any();
static async Task Refuses(Func<Task> action)
{
    try { await action(); } catch (IOException) { return; }
    throw new Exception("An operation that must refuse unexpectedly succeeded.");
}
static async Task Cancelled(Func<Task> action)
{
    try { await action(); } catch (OperationCanceledException) { return; }
    throw new Exception("Cancellation was ignored");
}
static void Junction(string link, string target)
{
    var start = new System.Diagnostics.ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    start.ArgumentList.Add("/c"); start.ArgumentList.Add("mklink"); start.ArgumentList.Add("/J"); start.ArgumentList.Add(link); start.ArgumentList.Add(target);
    using var process = System.Diagnostics.Process.Start(start)!;
    var output = process.StandardOutput.ReadToEndAsync();
    var error = process.StandardError.ReadToEndAsync();
    process.WaitForExit();
    if (process.ExitCode != 0) throw new Exception("create junction fixture: " + error.Result + output.Result);
}
static bool TrySymlink(string link, string target, bool directory = false)
{
    try
    {
        if (directory) Directory.CreateSymbolicLink(link, target);
        else File.CreateSymbolicLink(link, target);
        return true;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
    {
        Console.WriteLine("SKIP: symbolic link (" + ex.Message + ")");
        return false;
    }
}
sealed class ByteProgress(Action<ulong> report) : IProgress<ulong> { public void Report(ulong value) => report(value); }
