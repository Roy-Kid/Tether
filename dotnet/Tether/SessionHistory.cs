using Gen = global::uniffi.tether_ffi;

namespace Tether;

/// <summary>A disk archive configured before the first terminal output.</summary>
public sealed class SessionHistory : IDisposable
{
    internal Gen.SessionHistory Inner { get; }
    public SessionHistory(string directory, ulong? lineLimit = 10_000, bool restoring = false)
        => Inner = Gen.SessionHistory.Open(directory, lineLimit, restoring);
    public string? Error => Inner.Error();
    public void Dispose() => Inner.Dispose();
}

public sealed record LockedKey(string? Fingerprint, string Comment);

public interface IPassphrasePrompter
{
    Task<string?> PassphraseAsync(LockedKey key, uint attempt);
}
