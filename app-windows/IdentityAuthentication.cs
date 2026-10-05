using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Tether;

namespace TetherApp;

public static class IdentityAuthentication
{
    private static readonly HashSet<string> Approved = new();
    public static async Task<Secret[]> CredentialsAsync(HostEntry host, IAuthPrompter prompts, IPassphrasePrompter unlock,
        Func<AccountIdentity, HostEntry, Task<bool>> confirm, IdentityStore? identityStore = null)
    {
        if (host.Unsupported.Count > 0) throw new IOException("This host requires unsupported OpenSSH settings: " + string.Join(", ", host.Unsupported));
        var store = identityStore ?? IdentityStore.Current; var identity = store.ForHost(host);
        var fingerprint = ApprovalDigest(host, identity);
        if (identity is not null && identity.Confirmation != ConfirmationPolicy.Automatic &&
            (identity.Confirmation == ConfirmationPolicy.EveryConnection || !Approved.Contains(fingerprint)))
        {
            if (!await confirm(identity, host)) throw new OperationCanceledException("Authentication declined.");
            Approved.Add(fingerprint);
        }
        var secrets = new List<Secret>();
        if (identity?.Method == AuthenticationMethod.Password)
        {
            if (identity.Secret is not { } password) throw new IOException("This identity needs a password.");
            secrets.Add(new Secret.Password(store.ReadSecret(password)));
        }
        else if (identity?.Method == AuthenticationMethod.Key)
        {
            var key = identity.Secret is { } saved ? store.ReadSecret(saved) : ReadKey(identity.KeyPath ?? "");
            secrets.Add(new Secret.PrivateKey(key, Unlock: unlock));
        }
        else
        {
            if (identity is null && host.IdentityFile is { Length: > 0 } explicitKey && explicitKey != "none") secrets.Add(new Secret.PrivateKey(ReadKey(explicitKey), Unlock: unlock));
            else foreach (var name in new[] { "id_ed25519", "id_ecdsa", "id_rsa" })
            {
                var path = SshConfig.ExpandHome("~/.ssh/" + name);
                if (File.Exists(path)) secrets.Add(new Secret.PrivateKey(ReadKey(path), Unlock: unlock));
            }
        }
        secrets.Add(new Secret.Interactive(identity is null ? prompts : new IdentityPrompter(identity, store, prompts)));
        return secrets.ToArray();
    }
    public static string ApprovalDigest(HostEntry host, AccountIdentity? identity)
    {
        var text = IdentityStore.EndpointDigest(host) + JsonSerializer.Serialize(identity);
        if (identity?.KeyPath is { } path && File.Exists(SshConfig.ExpandHome(path))) text += Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ReadKey(path))));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }
    public static HostEntry HopHost(Jump hop)
    {
        var configured = SshConfig.Load().FirstOrDefault(h => h.Alias == hop.Alias);
        if (configured?.Unsupported.Count > 0) throw new IOException("The jump host requires unsupported OpenSSH settings: " + string.Join(", ", configured.Unsupported));
        if (configured is not null && IdentityStore.Current.AssignedIdentity(configured.Alias) is not null)
        {
            if (configured.HostName != hop.HostName || (configured.Port ?? 22) != hop.Port ||
                (configured.User ?? Environment.UserName) != (hop.User ?? Environment.UserName))
                throw new IOException("The jump route overrides its saved identity's endpoint or username. Review the route in Manage Hosts.");
            return configured;
        }
        return new HostEntry(hop.Alias ?? hop.HostName, hop.HostName, hop.User, hop.Port, hop.IdentityFile);
    }
    private static string ReadKey(string path)
    {
        path = SshConfig.ExpandHome(path);
        if (!File.Exists(path)) throw new IOException("Could not read the key at " + path + ".");
        if (new FileInfo(path).Length > 128 * 1024) throw new IOException("Private keys must be smaller than 128 KiB.");
        return File.ReadAllText(path);
    }
}

/// <summary>Only an exact, configured non-echo challenge can receive a saved OTP.</summary>
public sealed class IdentityPrompter(AccountIdentity identity, IdentityStore store, IAuthPrompter fallback) : IAuthPrompter
{
    private bool _otpUsed, _passwordUsed;
    public async Task<IReadOnlyList<string>> AnswerAsync(string instruction, IReadOnlyList<AuthPrompt> prompts, CancellationToken cancellationToken = default)
    {
        var answers = new string[prompts.Count]; var unanswered = new List<AuthPrompt>(); var indexes = new List<int>();
        for (var i = 0; i < prompts.Count; i++)
        {
            var prompt = prompts[i];
            if (!prompt.Echo && !_otpUsed && identity.Otp is not null && prompt.Text == identity.OtpPrompt)
            { answers[i] = store.OtpCode(identity, DateTimeOffset.UtcNow); _otpUsed = true; }
            else if (!prompt.Echo && !_passwordUsed && identity.Method == AuthenticationMethod.Password && identity.Secret is { } password &&
                prompt.Text.Trim().Equals("Password:", StringComparison.OrdinalIgnoreCase))
            { answers[i] = store.ReadSecret(password); _passwordUsed = true; }
            else { indexes.Add(i); unanswered.Add(prompt); }
        }
        if (unanswered.Count > 0)
        {
            var supplied = await fallback.AnswerAsync(instruction, unanswered, cancellationToken);
            if (supplied.Count != unanswered.Count) return [];
            for (var i = 0; i < indexes.Count; i++) answers[indexes[i]] = supplied[i];
        }
        return answers;
    }
}
