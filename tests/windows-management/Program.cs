using System.Text;
using System.Text.Json;
using Tether;
using TetherApp;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static void Reject(Action action, string message) { try { action(); } catch { return; } throw new Exception(message); }
static string Base32(byte[] bytes)
{
    var result = new StringBuilder(); var bits = 0; var value = 0;
    foreach (var b in bytes) { value = (value << 8) | b; bits += 8; while (bits >= 5) { bits -= 5; result.Append("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[(value >> bits) & 31]); } }
    if (bits > 0) result.Append("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[(value << (5 - bits)) & 31]); return result.ToString();
}

var source = "# global comment\nHost *\n    ServerAliveInterval 30\n\nHost old other # keep shared\n    HostName old.example\n    User original\n    IdentityFile \"~/.ssh/old key\"\n    ForwardAgent no\n    # keep this\nMatch exec \"test true\"\n    SendEnv LANG\nHost untouched\n    HostName untouched.example\n";
var changed = SshConfigEditor.Update(source, "old", new("renamed", "new.example", "alice", 2200, "~/.ssh/new key"));
var hosts = SshConfig.LoadText(changed);
Check(hosts.Single(h => h.Alias == "renamed").Target == "alice@new.example:2200", "Explicit settings must override prior wildcards");
Check(hosts.Any(h => h.Alias == "other" && h.HostName == "old.example") && !hosts.Any(h => h.Alias == "old"), "Shared aliases must survive renaming");
Check(changed.Contains("ForwardAgent no") && changed.Contains("Match exec \"test true\"\n    SendEnv LANG\nHost untouched"), "Unknown directives/Match must be preserved");
Check(!SshConfig.LoadText(SshConfigEditor.Update(changed, "renamed", null)).Any(h => h.Alias == "renamed"), "Delete host");
Reject(() => SshConfigEditor.Update(changed, null, new("other", "bad", "alice")), "Duplicate label accepted");
Reject(() => SshConfigEditor.Update(changed, null, new("bad\nHost attack", "bad", "alice")), "Config injection accepted");
Reject(() => SshConfigEditor.Update("Host a\n ProxyJump b\nHost b\n ProxyJump a\n", "a", new("a", "a", "alice", ProxyJump: "b")), "Jump cycle accepted");
var importedConfig = SshConfigEditor.Import("Host existing\n HostName existing.example\n", "User imported\nHost destination\n HostName remote.example\n ProxyJump jump\n ForwardAgent no\nHost jump\n HostName jump.example\n IdentityFile keys/jump\n", ["destination", "jump"], sourceDirectory: Path.GetTempPath());
Check(SshConfig.LoadText(importedConfig).Single(h => h.Alias == "destination").Route.Single().Alias == "jump", "Imported jump alias identity lost");
Check(SshConfig.ResolvedDirectives(importedConfig, "destination")["forwardagent"] == "no" && SshConfig.LoadText(importedConfig).Single(h => h.Alias == "destination").User == "imported", "Import dropped settings or global account");
Check(Path.IsPathRooted(SshConfig.LoadText(importedConfig).Single(h => h.Alias == "jump").IdentityFile!), "Imported relative key path was not anchored to source config");
var precedence = SshConfigEditor.Update("Host *\n ForwardAgent yes\nHost foo\n HostName foo\n User alice\n ForwardAgent no\n", "foo", new("foo", "new.example", "alice"));
Check(SshConfig.ResolvedDirectives(precedence, "foo")["forwardagent"] == "yes", "Editing changed unknown-option wildcard precedence");
Check(SshConfig.LoadText(precedence).Count == 1, "Supplemental preserved-options stanza created duplicate picker rows");

var instant = DateTimeOffset.FromUnixTimeSeconds(59);
Check(new TotpCredential(Base32(Encoding.ASCII.GetBytes("12345678901234567890")), "SHA1", 8).Code(instant) == "94287082", "RFC6238 SHA1");
Check(new TotpCredential(Base32(Encoding.ASCII.GetBytes("12345678901234567890123456789012")), "SHA256", 8).Code(instant) == "46119246", "RFC6238 SHA256");
Check(new TotpCredential(Base32(Encoding.ASCII.GetBytes("1234567890123456789012345678901234567890123456789012345678901234")), "SHA512", 8).Code(instant) == "90693936", "RFC6238 SHA512");
Reject(() => TotpCredential.Parse("otpauth://hotp/test?secret=JBSWY3DPEHPK3PXP"), "HOTP accepted as TOTP");

var root = Path.Combine(Path.GetTempPath(), "tether-management-test-" + Guid.NewGuid().ToString("N"));
string generatedPublic;
try
{
    var store = new IdentityStore(root);
    var identity = new AccountIdentity(Guid.NewGuid(), "Test account", AuthenticationMethod.Password);
    store.Save(identity, "unique-test-password", "JBSWY3DPEHPK3PXP"); identity = store.Identities.Single();
    Check(store.ReadSecret(identity.Secret!.Value) == "unique-test-password", "DPAPI password round trip");
    Check(!Directory.GetFiles(root).Any(f => Encoding.UTF8.GetString(File.ReadAllBytes(f)).Contains("unique-test-password")), "Secret leaked into on-disk metadata");
    var target = new HostEntry("test", "one.example", "alice", 22, null);
    store.Bind(target, identity.Id);
    Check(new IdentityStore(root).ForHost(target)?.Id == identity.Id, "Identity binding reload");
    var confirmations = 0;
    Task<bool> Confirm(AccountIdentity account, HostEntry endpoint) { confirmations++; return Task.FromResult(true); }
    var loginPrompt = new Fallback();
    var offered = await IdentityAuthentication.CredentialsAsync(target, loginPrompt, new Unlock(), Confirm, store);
    Check(offered.OfType<Secret.Password>().Single().Value == "unique-test-password" && confirmations == 1, "Saved password not connected to authentication/confirmation policy");
    await IdentityAuthentication.CredentialsAsync(target, loginPrompt, new Unlock(), Confirm, store);
    Check(confirmations == 1, "Before-authentication approval not reused for same policy");
    store.Save(identity with { Confirmation = ConfirmationPolicy.EveryConnection }); identity = store.Identities.Single();
    await IdentityAuthentication.CredentialsAsync(target, loginPrompt, new Unlock(), Confirm, store);
    await IdentityAuthentication.CredentialsAsync(target, loginPrompt, new Unlock(), Confirm, store);
    Check(confirmations == 3, "Every-connection confirmation not enforced");
    var declined = false;
    try { await IdentityAuthentication.CredentialsAsync(target, loginPrompt, new Unlock(), (_, _) => Task.FromResult(false), store); } catch (OperationCanceledException) { declined = true; }
    Check(declined, "Declined approval still offered credentials");
    Reject(() => store.ForHost(target with { HostName = "other.example" }), "Credential followed changed endpoint");
    Reject(() => store.ForHost(target with { User = "bob" }), "Credential followed changed account");
    Reject(() => store.Delete(identity.Id), "Bound identity deletion allowed");
    var fallback = new Fallback(); var prompter = new IdentityPrompter(identity, store, fallback);
    var answers = await prompter.AnswerAsync("MFA", [new AuthPrompt("Verification code:", false), new AuthPrompt("Anything else:", false)]);
    Check(answers[0].Length == 6 && answers[1] == "asked" && fallback.Count == 1, "Exact OTP challenge routing");
    var retry = await prompter.AnswerAsync("Retry", [new AuthPrompt("Verification code:", false)]);
    Check(retry[0] == "asked", "OTP retry must ask rather than replay");
    var echo = await new IdentityPrompter(identity, store, fallback).AnswerAsync("Echo", [new AuthPrompt("Verification code:", true)]);
    Check(echo[0] == "asked", "OTP leaked into echo prompt");
    store.Save(identity, "replacement-password", clearOtp: true);
    Check(!File.Exists(Path.Combine(root, identity.Secret!.Value.ToString("N") + ".credential")), "Old secret retained after replacement");
    identity = store.Identities.Single();
    Check(identity.Otp is null, "OTP not removed");
    store.Unbind("test"); store.Delete(identity.Id);
    var configPath = Path.Combine(root, "config"); File.WriteAllText(configPath, source);
    Reject(() => SshConfigEditor.Save("obsolete", changed, configPath), "External config change overwritten");
    Check(File.ReadAllText(configPath) == source, "Failed write changed original");
    SshConfigEditor.Save(source, changed, configPath); Check(File.ReadAllText(configPath) == changed, "Atomic config replacement");
    var key = await IdentityStore.GenerateKeyAsync();
    generatedPublic = key.Public;
    Check(key.Private.Contains("OPENSSH PRIVATE KEY") && key.Public.StartsWith("ssh-ed25519 "), "Generated key format");
    Reject(() => AuthorizedKeysProvider.KeyMaterial("ssh-rsa " + key.Public.Split(' ')[1]), "Public key type mismatch accepted");
    Reject(() => AuthorizedKeysProvider.KeyMaterial(key.Public + "\ncommand"), "Public key newline accepted");
    var authorization = new RemoteAuthorization(Guid.NewGuid(), target.Alias, IdentityStore.EndpointDigest(target), AuthorizedKeysProvider.KeyMaterial(key.Public), "Test device");
    store.SaveAuthorization(authorization);
    Check(new IdentityStore(root).Authorizations.Single().Id == authorization.Id, "Authorization ownership reload");
    var keyIdentity = new AccountIdentity(Guid.NewGuid(), "Generated", AuthenticationMethod.Key, PublicKey: key.Public);
    store.Save(keyIdentity, key.Private); Check(store.ReadSecret(store.Identities.Single().Secret!.Value) == key.Private, "DPAPI private-key round trip");
    var credentialFile = Directory.GetFiles(root, "*.credential").Single(); File.WriteAllBytes(credentialFile, [1, 2, 3]);
    Reject(() => store.ReadSecret(store.Identities.Single().Secret!.Value), "Damaged credential accepted");
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
Check(WslSession.ParseSessions("$1|0|a|b\n").Single().Name == "a|b", "tmux delimiter in names");
Check(WslSession.ParseWindows("@2|3|1|2|a|b\n").Single().Name == "a|b", "tmux window delimiter in names");
Reject(() => WslSession.SessionId("$1;touch bad"), "tmux identifier injection accepted");
Reject(() => WslSession.Quote("bad\ncommand"), "tmux control characters accepted");
Reject(() => BoundedProcess.RunAsync("cmd.exe", ["/d", "/c", "echo 0123456789"], limit: 5).GetAwaiter().GetResult(), "Output bound not enforced");
Console.WriteLine("PASS: host edits, DPAPI identities, key generation, TOTP vectors/challenge routing, credential binding, bounded command capture.");

if (args.Contains("--wsl"))
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
    await using var wsl = await WslSession.CreateAsync(timeout.Token);
    Check((await WslSession.DistributionsAsync()).Contains(wsl.Distribution), "WSL distribution enumeration/encoding");
    await using var secondWsl = await WslSession.CreateAsync(timeout.Token, wsl.Distribution);
    using var terminal = await TerminalSession.OpenLocalAsync(shell: WslSession.Program, arguments: wsl.ShellArguments(null));
    using var secondTerminal = await TerminalSession.OpenLocalAsync(shell: WslSession.Program, arguments: secondWsl.ShellArguments(null));
    string? tty = null;
    for (var attempt = 0; attempt < 40 && tty is null; attempt++)
    {
        try { tty = await wsl.TerminalNameAsync(timeout.Token); } catch (IOException) { }
        if (tty is null) await Task.Delay(100, timeout.Token);
    }
    Check(tty is not null, "WSL terminal identity unavailable");
    var secondTty = await secondWsl.TerminalNameAsync(timeout.Token);
    Check(secondTty is not null && tty != secondTty, "WSL tabs share or guess a terminal device");
    Check((await wsl.DirectoryAsync(timeout.Token))?.StartsWith('/') == true, "WSL current directory not read from its own shell");
    var processes = await wsl.ExecuteAsync("printf '%s\\n' TETHER-PROCESSES; ps -ax -o pid= -o ppid= -o tty= -o stat= -o comm=; printf '%s\\n' TETHER-PROCESSES-END", timeout.Token);
    Check(ProcessTable.CloseNote(processes, tty) is null, "Idle WSL login shell falsely reported as a running job");
    var sandbox = "/tmp/tether-authorization-test-" + Guid.NewGuid().ToString("N");
    var record = new RemoteAuthorization(Guid.NewGuid(), "test", "test", generatedPublic, "Test device");
    try
    {
        await wsl.ExecuteAsync("mkdir -m 700 " + WslSession.Quote(sandbox), timeout.Token);
        var home = "export HOME=" + WslSession.Quote(sandbox) + "\n";
        await wsl.ExecuteAsync(home + "mkdir -m 700 \"$HOME/.ssh\"; printf '%s\\n' '# administrator entry' > \"$HOME/.ssh/authorized_keys\"", timeout.Token);
        await wsl.ExecuteAsync(home + AuthorizedKeysProvider.Script(record, false), timeout.Token);
        await wsl.ExecuteAsync(home + AuthorizedKeysProvider.Script(record, false), timeout.Token);
        var authorized = await wsl.ExecuteAsync(home + "cat \"$HOME/.ssh/authorized_keys\"", timeout.Token);
        Check(authorized.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length == 2 && authorized.Contains("# administrator entry") && authorized.Contains(record.Id.ToString("D")), "Authorization is not idempotent or dropped unrelated keys");
        await wsl.ExecuteAsync(home + AuthorizedKeysProvider.Script(record, true), timeout.Token);
        Check((await wsl.ExecuteAsync(home + "cat \"$HOME/.ssh/authorized_keys\"", timeout.Token)).Trim() == "# administrator entry", "Revocation removed unrelated keys");
        await wsl.ExecuteAsync(home + "mv \"$HOME/.ssh/authorized_keys\" \"$HOME/keys\"; ln -s \"$HOME/keys\" \"$HOME/.ssh/authorized_keys\"", timeout.Token);
        var refused = false; try { await wsl.ExecuteAsync(home + AuthorizedKeysProvider.Script(record, false), timeout.Token); } catch (IOException) { refused = true; }
        Check(refused, "Authorization followed a symbolic link");
    }
    finally
    {
        // The exact random sandbox above is the only recursively removed path.
        await wsl.ExecuteAsync("rm -rf -- " + WslSession.Quote(sandbox), timeout.Token);
    }
    var session = await wsl.CreateAsync("tether-test-" + Guid.NewGuid().ToString("N"), null, timeout.Token);
    try
    {
        Check((await wsl.SessionsAsync(timeout.Token)).Any(s => s.Id == session.Id), "WSL tmux creation/listing");
        terminal.Send(new TerminalInput.Paste("tmux attach-session -t " + WslSession.SessionId(session.Id)));
        terminal.Send(new TerminalInput.Key(new KeyPress.Enter(), new KeyModifiers()));
        string? attached = null;
        for (var attempt = 0; attempt < 40 && attached is null; attempt++) { attached = await wsl.SessionForClientAsync(tty!); if (attached is null) await Task.Delay(100, timeout.Token); }
        Check(attached == session.Id, "WSL tmux client attached to wrong terminal");
        Check(await secondWsl.SessionForClientAsync(secondTty!) is null, "Attach affected a different WSL terminal");
        await wsl.ExecuteAsync("tmux split-window -h -t " + WslSession.SessionId(session.Id), timeout.Token);
        Check((await wsl.SessionsAsync(timeout.Token)).Single(s => s.Id == session.Id).Windows.Sum(w => w.Panes) == 2, "WSL tmux split");
        await wsl.ExecuteAsync("tmux rename-session -t " + WslSession.SessionId(session.Id) + " " + WslSession.Quote("tether-renamed-" + Guid.NewGuid().ToString("N")), timeout.Token);
        await wsl.ExecuteAsync("tmux detach-client -t " + WslSession.Quote(tty!), timeout.Token);
        Check(await wsl.SessionForClientAsync(tty!) is null, "WSL tmux detach");
        Check((await wsl.SessionsAsync(timeout.Token)).Any(s => s.Id == session.Id), "Detach killed server session");
    }
    finally { await wsl.ExecuteAsync("tmux kill-session -t " + WslSession.SessionId(session.Id), timeout.Token); }
    Console.WriteLine("PASS: isolated authorized_keys install/revoke/symlink refusal, concurrent WSL ConPTY terminal identity, tmux create/list/attach/split/rename/detach/end on " + wsl.Distribution + ".");
}

sealed class Fallback : IAuthPrompter
{
    public int Count;
    public Task<IReadOnlyList<string>> AnswerAsync(string instruction, IReadOnlyList<AuthPrompt> prompts, CancellationToken cancellationToken = default)
    { Count += prompts.Count; return Task.FromResult<IReadOnlyList<string>>(prompts.Select(_ => "asked").ToArray()); }
}
sealed class Unlock : IPassphrasePrompter
{
    public Task<string?> PassphraseAsync(LockedKey key, uint attempt) => Task.FromResult<string?>(null);
}
