using Gen = global::uniffi.tether_ffi;

namespace Tether;

public enum FileKind { File, Directory, Link, Other }
public sealed record FileEntry(string Name, string Path, FileKind Kind, ulong Size, ulong? Modified, uint Permissions);
public enum FileFailure { NotFound, Exists, PermissionDenied, NotEmpty, Disconnected, Failed }
public sealed class FileOperationException(FileFailure failure, string message) : IOException(message)
{
    public FileFailure Failure { get; } = failure;
}

/// <summary>SFTP on an existing authenticated connection; closing it leaves the shell running.</summary>
public sealed class RemoteFiles : IAsyncDisposable
{
    private readonly Gen.RemoteFiles _inner;
    internal RemoteFiles(Gen.RemoteFiles inner) => _inner = inner;
    public Task<string> HomeAsync() => Call(() => _inner.Home());
    public Task<string> ResolveAsync(string path) => Call(() => _inner.Resolve(path));
    public async Task<IReadOnlyList<FileEntry>> ListAsync(string path, CancellationToken token = default)
    {
        using var c = new Cancellation(token);
        return (await Call(() => _inner.List(path, c.Ffi)).ConfigureAwait(false)).Select(Lift).ToArray();
    }
    public async Task<FileEntry> StatAsync(string path, bool followLinks = true) =>
        Lift(await Call(() => followLinks ? _inner.Stat(path) : _inner.Lstat(path)).ConfigureAwait(false));
    public Task MakeDirectoryAsync(string path) => Call(() => _inner.MakeDirectory(path));
    public Task RenameAsync(string from, string to, bool replace = false) => Call(() => _inner.Rename(from, to, replace));
    public async Task RemoveTreeAsync(string path, CancellationToken token = default)
    {
        using var c = new Cancellation(token);
        await Call(() => _inner.RemoveTree(path, c.Ffi)).ConfigureAwait(false);
    }
    public async Task DownloadAsync(string path, string destination, IProgress<ulong>? progress = null, CancellationToken token = default)
    {
        using var c = new Cancellation(token);
        await Call(() => _inner.Download(path, destination, progress is null ? null : new Progress(progress), c.Ffi)).ConfigureAwait(false);
    }
    public async Task UploadAsync(string source, string path, bool replace = false, IProgress<ulong>? progress = null, CancellationToken token = default)
    {
        using var c = new Cancellation(token);
        await Call(() => _inner.Upload(source, path, replace, progress is null ? null : new Progress(progress), c.Ffi)).ConfigureAwait(false);
    }
    public async ValueTask DisposeAsync()
    {
        try { await _inner.Close().ConfigureAwait(false); }
        finally { _inner.Dispose(); }
    }
    private static FileEntry Lift(Gen.FileEntry e) => new(e.Name, e.Path, (FileKind)e.Kind, e.Size, e.Modified, e.Permissions);
    private sealed class Progress(IProgress<ulong> progress) : Gen.TransferProgress
    {
        public void Advanced(ulong bytes) => progress.Report(bytes);
    }
    private sealed class Cancellation : IDisposable
    {
        public Gen.CancellationToken Ffi { get; } = new();
        private readonly CancellationTokenRegistration _registration;
        public Cancellation(CancellationToken token) => _registration = token.Register(Ffi.Cancel);
        public void Dispose() { _registration.Dispose(); Ffi.Dispose(); }
    }
    private static Exception Map(Gen.FileException e) => e switch
    {
        Gen.FileException.NotFound x => new FileOperationException(FileFailure.NotFound, $"{x.path} does not exist."),
        Gen.FileException.Exists x => new FileOperationException(FileFailure.Exists, $"{x.path} already exists."),
        Gen.FileException.PermissionDenied x => new FileOperationException(FileFailure.PermissionDenied, $"Access denied: {x.path}"),
        Gen.FileException.NotEmpty x => new FileOperationException(FileFailure.NotEmpty, $"{x.path} is not empty."),
        Gen.FileException.Cancelled => new OperationCanceledException(),
        Gen.FileException.Disconnected x => new FileOperationException(FileFailure.Disconnected, x.cause),
        Gen.FileException.Failed x => new FileOperationException(FileFailure.Failed, x.cause),
        _ => new FileOperationException(FileFailure.Failed, e.Message),
    };
    private static async Task<T> Call<T>(Func<Task<T>> action)
    {
        try { return await action().ConfigureAwait(false); }
        catch (Gen.FileException e) { throw Map(e); }
    }
    private static async Task Call(Func<Task> action)
    {
        try { await action().ConfigureAwait(false); }
        catch (Gen.FileException e) { throw Map(e); }
    }
}
