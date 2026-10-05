using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using TetherApp.Plugins;
using Xunit;

namespace TetherApp.PluginTests;

public sealed class WebPluginTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "tether-web-tests-" + Guid.NewGuid().ToString("N"));
    private static WebPluginManifest Manifest(string entry = "web/index.html", string origin = "http://127.0.0.1:17890") =>
        new("test.web", "Test", "Tests", "1.0", 1, "web", entry, "4+", "https://example.com", ["network"], [new("panel", "jobs")], [origin]);
    private string Package(WebPluginManifest? manifest = null)
    {
        var path = Path.Combine(_root, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path.Combine(path, "web"));
        File.WriteAllText(Path.Combine(path, "manifest.json"), JsonSerializer.Serialize(manifest ?? Manifest()));
        File.WriteAllText(Path.Combine(path, "web", "index.html"), "<!doctype html><title>Test</title>"); return path;
    }
    [Fact] public async Task LocalServiceRequiresHostApprovalAndPluginPermission()
    {
        var package = WebPluginPackage.Read(Package());
        await Assert.ThrowsAsync<IOException>(() => WebPluginServices.EnsureAsync(package, "arbitrary", CancellationToken.None));
        var granted = WebPluginPackage.Read(Package(Manifest() with { Permissions = ["network", "service.local"], Services = ["unknown"] }));
        await Assert.ThrowsAsync<IOException>(() => WebPluginServices.EnsureAsync(granted, "unknown", CancellationToken.None));
        Assert.Throws<IOException>(() => WebPluginPackage.Read(Package(Manifest() with { Services = ["unknown"] })));
    }

    [Fact] public async Task ExistingHealthyServiceNeedsNoExecutable()
    {
        using var socket = new TcpListener(IPAddress.Loopback, 0); socket.Start();
        var origin = $"http://127.0.0.1:{((IPEndPoint)socket.LocalEndpoint).Port}";
        var id = Guid.NewGuid().ToString("N");
        var package = WebPluginPackage.Read(Package(Manifest(origin: origin) with { Permissions = ["network", "service.local"], Services = [id] }));
        WebPluginServices.Register(id, package.Manifest.Id, Path.Combine(_root, "missing.exe"), new Uri(origin + "/health"));
        var responder = Task.Run(async () =>
        {
            using var client = await socket.AcceptTcpClientAsync();
            var stream = client.GetStream(); var buffer = new byte[4096]; _ = await stream.ReadAsync(buffer);
            await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"));
        });
        await WebPluginServices.EnsureAsync(package, id, CancellationToken.None);
        await responder;
    }
    [Fact] public void InstallingCopiesOnlyAValidatedPackageAndRefusesDuplicateIDs()
    {
        var source = Package(); var install = Path.Combine(_root, "installed");
        var result = WebPluginPackage.Install(source, install);
        Assert.Equal("test.web", result.Manifest.Id); Assert.True(File.Exists(result.EntryPath));
        Assert.Throws<IOException>(() => WebPluginPackage.Install(source, install));
    }
    [Theory]
    [InlineData("../outside.html")][InlineData("/outside.html")][InlineData("web/../index.html")]
    [InlineData("C:/outside.html")][InlineData("web\\index.html")]
    public void EntryPointsCannotLeaveThePackage(string entry) => Assert.Throws<IOException>(() => WebPluginPackage.Read(Package(Manifest(entry))));

    [Fact] public void RenamingNativeCodeAsJavaScriptDoesNotMakeItAWebAsset()
    {
        var root = Package(); File.WriteAllBytes(Path.Combine(root, "web", "payload.js"), [0x4d, 0x5a, 0, 0]);
        Assert.Throws<IOException>(() => WebPluginPackage.Read(root));
    }
    [Fact] public void InstallScriptsAndNativeExtensionsAreRefusedBeforeCopy()
    {
        var root = Package(); File.WriteAllText(Path.Combine(root, "package.json"), "{\"scripts\":{\"postinstall\":\"run\"}}");
        Assert.Throws<IOException>(() => WebPluginPackage.Read(root));
        var native = Package(); File.WriteAllText(Path.Combine(native, "payload.dll"), "not even a binary");
        Assert.Throws<IOException>(() => WebPluginPackage.Install(native, Path.Combine(_root, "installed")));
        Assert.False(Directory.Exists(Path.Combine(_root, "installed", "test.web")));
    }
    [Fact] public void NetworkAccessMatchesTheWholeOriginIncludingPort()
    {
        var package = WebPluginPackage.Read(Package());
        Assert.Equal(17890, package.NetworkUri("http://127.0.0.1:17890/v1/stream?surface=test").Port);
        foreach (var url in new[] { "http://127.0.0.1:17891/v1/jobs", "http://localhost:17890/v1/jobs", "https://example.com", "file:///etc/passwd", "http://user@127.0.0.1:17890/v1/jobs" })
            Assert.Throws<IOException>(() => package.NetworkUri(url));
    }
    [Theory][InlineData("http://localhost:17890")][InlineData("http://example.com")][InlineData("http://127.0.0.1:17890/path")]
    public void UnencryptedOriginsAreLiteralLoopbackAndContainNoPaths(string origin) =>
        Assert.Throws<IOException>(() => WebPluginPackage.Read(Package(Manifest(origin: origin))));

    [Fact] public async Task EventFramesAreDecodedAcrossUtf8ChunksAndKeepAliveComments()
    {
        var frames = new List<string>();
        using var stream = new MemoryStream(Encoding.UTF8.GetBytes(": ping\r\nevent: frame\r\ndata: {\"jobs\":\r\ndata: [{\"id\":\"中文\"}]}\r\n\r\ndata: {\"jobs\":[]}\n\n"));
        await Assert.ThrowsAsync<IOException>(() => WebPluginNetwork.PumpAsync(stream, text => { frames.Add(text); return Task.CompletedTask; }, CancellationToken.None));
        Assert.Equal(["{\"jobs\":\n[{\"id\":\"中文\"}]}", "{\"jobs\":[]}"], frames);
    }
    [Fact] public async Task AnUnterminatedSseLineCannotGrowWithoutBound()
    {
        using var stream = new MemoryStream(Encoding.UTF8.GetBytes("data: " + new string('x', WebPluginNetwork.MaxPayload)));
        await Assert.ThrowsAsync<IOException>(() => WebPluginNetwork.PumpAsync(stream, _ => Task.CompletedTask, CancellationToken.None));
    }
    [Fact] public async Task StreamsStopOnCancellation()
    {
        using var token = new CancellationTokenSource(); token.Cancel();
        using var stream = new MemoryStream(Encoding.UTF8.GetBytes("data: {}\n\n"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => WebPluginNetwork.PumpAsync(stream, _ => Task.CompletedTask, token.Token));
    }
    [Fact] public async Task NetworkRedirectsCannotEscapeTheGrantedOrigin()
    {
        var socket = new TcpListener(IPAddress.Loopback, 0); socket.Start(); var port = ((IPEndPoint)socket.LocalEndpoint).Port; socket.Stop();
        var origin = $"http://127.0.0.1:{port}";
        using var server = new HttpListener(); server.Prefixes.Add(origin + "/"); server.Start();
        using var network = new WebPluginNetwork(WebPluginPackage.Read(Package(Manifest(origin: origin))));
        var request = network.GetAsync(origin + "/redirect", CancellationToken.None);
        var context = await server.GetContextAsync().WaitAsync(TimeSpan.FromSeconds(5));
        context.Response.StatusCode = 302; context.Response.RedirectLocation = "http://127.0.0.1:1/private"; context.Response.Close();
        var error = await Assert.ThrowsAsync<IOException>(() => request); Assert.Contains("redirect", error.Message);
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }
}

public sealed class RealHubTests
{
    [Fact] public async Task TheInstalledPackageReadsARealHubFrameAndReleasesItsStream()
    {
        var directory = Environment.GetEnvironmentVariable("TETHER_TEST_WEB_PACKAGE");
        if (directory is null) return; // Opt-in: tests must not start or mutate the person's hub.
        var package = WebPluginPackage.Read(directory);
        using var network = new WebPluginNetwork(package);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var received = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stream = network.StreamAsync("http://127.0.0.1:17890/v1/stream?surface=test-web-plugin", text =>
        { received.TrySetResult(text); return Task.CompletedTask; }, timeout.Token);
        try
        {
            using var frame = JsonDocument.Parse(await received.Task.WaitAsync(timeout.Token));
            Assert.Equal(JsonValueKind.Array, frame.RootElement.GetProperty("jobs").ValueKind);
            using var jobs = JsonDocument.Parse(await network.GetAsync("http://127.0.0.1:17890/v1/jobs", timeout.Token));
            Assert.Equal(JsonValueKind.Array, jobs.RootElement.ValueKind);
        }
        finally { timeout.Cancel(); try { await stream; } catch (OperationCanceledException) { } }
    }
}
