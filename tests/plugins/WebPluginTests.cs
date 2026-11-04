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

    [Fact] public void InstallingCopiesOnlyAValidatedPackageAndRefusesDuplicateIDs()
    {
        var source = Package(); var install = Path.Combine(_root, "installed");
        var result = WebPluginPackage.Install(source, install);
        Assert.Equal("test.web", result.Manifest.Id); Assert.True(File.Exists(result.EntryPath));
        Assert.Throws<IOException>(() => WebPluginPackage.Install(source, install));
    }
    [Fact] public void ViewerContributionsNeedDocumentReadAndNormalizedSuffixes()
    {
        Assert.Throws<IOException>(() => WebPluginPackage.Read(Package(Manifest() with
        {
            Permissions = ["document.read"], NetworkOrigins = null,
            Contributions = [new("viewer", "viewer/fixture")],
        })));
        Assert.Throws<IOException>(() => WebPluginPackage.Read(Package(Manifest() with
        {
            Permissions = ["network"],
            Contributions = [new("viewer", "viewer/fixture", Suffixes: ["fixture"])],
        })));
        var package = WebPluginPackage.Read(Package(Manifest() with
        {
            Permissions = ["document.read"], NetworkOrigins = null,
            Contributions = [new("viewer", "viewer/fixture", Suffixes: [".FIXTURE", "fixture"])],
        }));
        Assert.Equal(["fixture"], package.Manifest.Contributions.Single().Suffixes!);
        Assert.Equal("fixture", WebPluginPackage.NormalizeSuffix(".Fixture"));
    }

    private sealed class StubPlugin(string id) : ITetherPlugin
    {
        public PluginMetadata Metadata { get; } = new(id, id, "W", "stub");
        public bool Deactivated { get; private set; }
        public void Activate() { }
        public void Deactivate() => Deactivated = true;
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
}
