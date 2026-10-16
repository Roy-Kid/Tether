using System.Reflection;
using Tether;

// Exercise the native-to-public boundary without a server or credentials.
try
{
    await TerminalSession.ConnectAsync(new Destination("unused.invalid", 22, "test"),
        new NoTrust(), Array.Empty<Secret>());
    throw new Exception("An empty credential list was accepted.");
}
catch (TetherException.NothingToOffer) { }

// Inject both authentication variants: their generated Message is identical,
// but callers must receive distinct errors and readable method names.
var assembly = typeof(TerminalSession).Assembly;
var lift = typeof(TerminalSession).GetMethod("LiftError", BindingFlags.NonPublic | BindingFlags.Static)!;
foreach (var variant in new[] { "AuthenticationFailed", "MoreFactorsNeeded" })
{
    var type = assembly.GetType("uniffi.tether_ffi.TetherException+" + variant)!;
    var arguments = new List<object> { new[] { "publickey", "keyboard-interactive" } };
    if (variant == "AuthenticationFailed")
    {
        var skipped = assembly.GetType("uniffi.tether_ffi.SkippedKey")!;
        arguments.Add(Array.CreateInstance(skipped, 0));
    }
    var generated = Activator.CreateInstance(type, arguments.ToArray())!;
    var error = (TetherException)lift.Invoke(null, new[] { generated })!;
    if (error.GetType().Name != variant || !error.Message.Contains("publickey, keyboard-interactive")
        || error.Message.Contains("System.String[]"))
        throw new Exception("Lost authentication details: " + error.Message);
}
Console.WriteLine("PASS: native connection error mapping and both authentication variants.");

sealed class NoTrust : IHostTrust
{
    public Task<bool> TrustsAsync(HostIdentity host, CancellationToken cancellationToken = default)
        => throw new Exception("Empty credentials must fail before connecting.");
}
