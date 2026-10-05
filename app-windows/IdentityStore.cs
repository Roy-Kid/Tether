using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace TetherApp;

public enum AuthenticationMethod { DefaultKeys, Key, Password }
public enum ConfirmationPolicy { Automatic, BeforeAuthentication, EveryConnection }
public sealed record AccountIdentity(Guid Id, string Name, AuthenticationMethod Method,
    Guid? Secret = null, string? KeyPath = null, string? PublicKey = null, Guid? Otp = null,
    string OtpPrompt = "Verification code:", ConfirmationPolicy Confirmation = ConfirmationPolicy.BeforeAuthentication);
public sealed record HostIdentityBinding(string Alias, string EndpointDigest, Guid Identity);
public sealed record IdentitySnapshot(int Version, List<AccountIdentity> Identities, List<HostIdentityBinding> Bindings, List<RemoteAuthorization>? Authorizations = null);

/// <summary>Metadata is separate from user-bound DPAPI encrypted credential bytes.</summary>
public sealed class IdentityStore
{
    public static IdentityStore Current { get; } = new();
    private readonly string _root;
    private IdentitySnapshot _snapshot;
    public IReadOnlyList<AccountIdentity> Identities => _snapshot.Identities;
    public Guid? AssignedIdentity(string alias) => _snapshot.Bindings.SingleOrDefault(b => b.Alias == alias)?.Identity;
    public IReadOnlyList<RemoteAuthorization> Authorizations => _snapshot.Authorizations ?? [];
    public void SaveAuthorization(RemoteAuthorization authorization) => Commit(_snapshot with
    { Authorizations = Authorizations.Where(a => a.Id != authorization.Id).Append(authorization).ToList() });
    public IdentityStore(string? root = null)
    {
        _root = root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tether", "Identities");
        var path = Path.Combine(_root, "identities.json");
        _snapshot = File.Exists(path) ? JsonSerializer.Deserialize<IdentitySnapshot>(File.ReadAllText(path)) ?? throw new IOException("Identity database is unreadable.")
            : new(1, [], []);
        if (_snapshot.Version != 1 || _snapshot.Identities.Select(i => i.Id).Distinct().Count() != _snapshot.Identities.Count)
            throw new IOException("Identity database version or identifiers are invalid.");
    }
    public static string EndpointDigest(HostEntry host) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
        JsonSerializer.Serialize(new { host.HostName, User = host.User ?? Environment.UserName, Port = host.Port ?? 22, host.Route, host.JumpError }))));
    public AccountIdentity? ForHost(HostEntry host)
    {
        var binding = _snapshot.Bindings.SingleOrDefault(b => b.Alias == host.Alias);
        if (binding is null) return null;
        if (binding.EndpointDigest != EndpointDigest(host)) throw new IOException("This host's address, account or jump route changed. Review its identity in Manage Hosts before connecting.");
        return _snapshot.Identities.SingleOrDefault(i => i.Id == binding.Identity) ?? throw new IOException("This host's identity was deleted.");
    }
    public void Bind(HostEntry host, Guid? identity, string? oldAlias = null)
    {
        if (identity is not null && !_snapshot.Identities.Any(i => i.Id == identity)) throw new IOException("Choose an existing identity.");
        var bindings = _snapshot.Bindings.Where(b => b.Alias != host.Alias && b.Alias != oldAlias).ToList();
        if (identity is { } id) bindings.Add(new(host.Alias, EndpointDigest(host), id));
        var authorizations = oldAlias is not null && oldAlias != host.Alias
            ? Authorizations.Select(a => a.HostAlias == oldAlias ? a with { HostAlias = host.Alias } : a).ToList() : _snapshot.Authorizations;
        Commit(_snapshot with { Bindings = bindings, Authorizations = authorizations });
    }
    public void Unbind(string alias) => Commit(_snapshot with { Bindings = _snapshot.Bindings.Where(b => b.Alias != alias).ToList() });
    public void Save(AccountIdentity identity, string? secret = null, string? otp = null, bool clearOtp = false)
    {
        if (string.IsNullOrWhiteSpace(identity.Name) || identity.Name.Length > 128 || identity.Name.Any(char.IsControl) || string.IsNullOrWhiteSpace(identity.OtpPrompt) || identity.OtpPrompt.Length > 256 ||
            !Enum.IsDefined(identity.Method) || !Enum.IsDefined(identity.Confirmation)) throw new IOException("Enter a valid identity name, authentication policy and exact OTP challenge label.");
        if (secret?.Length > 128 * 1024 || otp?.Length > 2048) throw new IOException("Credential exceeds the storage limit.");
        if (identity.Method == AuthenticationMethod.Key && secret is null && identity.Secret is null && !File.Exists(SshConfig.ExpandHome(identity.KeyPath ?? ""))) throw new IOException("Import a private key or choose an existing key file.");
        var old = _snapshot.Identities.FirstOrDefault(i => i.Id == identity.Id);
        if (old is not null && old.Method != identity.Method && secret is null && identity.Secret == old.Secret) identity = identity with { Secret = null };
        if (identity.Method == AuthenticationMethod.Password && identity.Secret is null && string.IsNullOrEmpty(secret)) throw new IOException("Enter a password for this identity.");
        var written = new List<Guid>();
        try
        {
            if (secret is not null) { var id = Guid.NewGuid(); WriteSecret(id, secret); written.Add(id); identity = identity with { Secret = id, KeyPath = null }; }
            if (otp is not null) { var id = Guid.NewGuid(); WriteSecret(id, JsonSerializer.Serialize(TotpCredential.Parse(otp))); written.Add(id); identity = identity with { Otp = id }; }
            if (clearOtp) identity = identity with { Otp = null };
            if (identity.Method == AuthenticationMethod.DefaultKeys) identity = identity with { Secret = null, KeyPath = null, PublicKey = null };
            if (identity.Method == AuthenticationMethod.Password) identity = identity with { KeyPath = null, PublicKey = null };
            var list = _snapshot.Identities.Where(i => i.Id != identity.Id).Append(identity).ToList();
            Commit(_snapshot with { Identities = list });
        }
        catch { foreach (var id in written) DeleteSecret(id); throw; }
        foreach (var id in new[] { old?.Secret, old?.Otp }.OfType<Guid>())
            if (id != identity.Secret && id != identity.Otp) DeleteSecret(id);
    }
    public void Delete(Guid id)
    {
        if (_snapshot.Bindings.Any(b => b.Identity == id)) throw new IOException("Assign another identity to its hosts before deleting this identity.");
        var old = _snapshot.Identities.Single(i => i.Id == id);
        Commit(_snapshot with { Identities = _snapshot.Identities.Where(i => i.Id != id).ToList() });
        foreach (var secret in new[] { old.Secret, old.Otp }.OfType<Guid>()) DeleteSecret(secret);
    }
    public string ReadSecret(Guid id)
    {
        if (new FileInfo(SecretPath(id)).Length > 256 * 1024) throw new IOException("Stored credential exceeds the size limit.");
        var plaintext = Dpapi.Unprotect(File.ReadAllBytes(SecretPath(id)));
        try { return Encoding.UTF8.GetString(plaintext); }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }
    public string OtpCode(AccountIdentity identity, DateTimeOffset now) => identity.Otp is { } id
        ? (JsonSerializer.Deserialize<TotpCredential>(ReadSecret(id)) ?? throw new IOException("OTP credential is unreadable.")).Code(now)
        : throw new IOException("This identity has no OTP credential.");
    public static async Task<(string Private, string Public)> GenerateKeyAsync(CancellationToken token = default)
    {
        var folder = Path.Combine(Path.GetTempPath(), "tether-key-" + Guid.NewGuid().ToString("N"));
        CreatePrivateDirectory(folder);
        var path = Path.Combine(folder, "key");
        try
        {
            await BoundedProcess.RunAsync(KeygenProgram, ["-q", "-t", "ed25519", "-N", "", "-C", "tether", "-f", path], token: token);
            return (await File.ReadAllTextAsync(path, token), (await File.ReadAllTextAsync(path + ".pub", token)).Trim());
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
    public static string KeygenProgram
    {
        get
        {
            var bundled = Path.Combine(Environment.SystemDirectory, "OpenSSH", "ssh-keygen.exe");
            if (File.Exists(bundled)) return bundled;
            return "ssh-keygen.exe";
        }
    }
    public static void CreatePrivateDirectory(string path)
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        var owner = WindowsIdentity.GetCurrent().User ?? throw new IOException("Unable to determine the Windows account.");
        security.SetOwner(owner);
        security.AddAccessRule(new FileSystemAccessRule(owner, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        FileSystemAclExtensions.CreateDirectory(security, path);
    }
    private string SecretPath(Guid id) => Path.Combine(_root, id.ToString("N") + ".credential");
    private void WriteSecret(Guid id, string value)
    {
        CreatePrivateDirectory(_root);
        var bytes = Encoding.UTF8.GetBytes(value);
        try { File.WriteAllBytes(SecretPath(id), Dpapi.Protect(bytes)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private void DeleteSecret(Guid id) { var path = SecretPath(id); if (File.Exists(path)) File.Delete(path); }
    private void Commit(IdentitySnapshot snapshot)
    {
        CreatePrivateDirectory(_root);
        var path = Path.Combine(_root, "identities.json"); var temporary = path + ".tmp";
        using var guard = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        if (File.Exists(path))
        {
            var current = JsonSerializer.Deserialize<IdentitySnapshot>(File.ReadAllText(path));
            if (JsonSerializer.Serialize(current) != JsonSerializer.Serialize(_snapshot)) throw new IOException("Identities changed in another window or process. Reopen Tether before saving.");
        }
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(snapshot, new JsonSerializerOptions { WriteIndented = true })); File.Move(temporary, path, true); _snapshot = snapshot; }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

internal static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob data, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob data, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static byte[] Protect(byte[] input) => Transform(input, true);
    public static byte[] Unprotect(byte[] input) => Transform(input, false);
    private static byte[] Transform(byte[] input, bool encrypt)
    {
        var data = new Blob { Length = input.Length, Data = Marshal.AllocHGlobal(input.Length) }; Blob output = default;
        try
        {
            Marshal.Copy(input, 0, data.Data, input.Length);
            var ok = encrypt ? CryptProtectData(ref data, "Tether credential", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref data, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Windows could not protect or unlock this credential.");
            var result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally
        {
            for (var i = 0; i < data.Length; i++) Marshal.WriteByte(data.Data, i, 0);
            Marshal.FreeHGlobal(data.Data);
            if (output.Data != IntPtr.Zero) { for (var i = 0; i < output.Length; i++) Marshal.WriteByte(output.Data, i, 0); LocalFree(output.Data); }
        }
    }
}
