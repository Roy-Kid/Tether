using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Tether;
using TetherApp;

namespace TetherApp.Plugins;

/// <summary>A runtime-loaded web package. The app never names its product.</summary>
public sealed class WebPlugin(WebPluginPackage package) : ITabPlugin
{
    private readonly HashSet<WebAttachment> _attachments = [];
    public WebPluginPackage Package => package;
    public PluginMetadata Metadata { get; } = new(package.Manifest.Id, package.Manifest.Name,
        package.Manifest.Glyph is { Length: 1 } glyph ? glyph : "\uE774", package.Manifest.Summary ?? package.Manifest.Publisher);
    public TabAccessory Accessory => new(Metadata.Glyph, Metadata.Name, AccessoryPlacement.Inspector);
    public IReadOnlyList<PluginCommandDescriptor> CommandDescriptors => package.Manifest.Contributions
        .Where(c => c.Kind == "command").Select(c => new PluginCommandDescriptor(c.Id, c.Title ?? c.Id)).ToArray();
    public IEnumerable<WebViewerMatch> Viewers => package.Manifest.Contributions
        .Where(c => c.Kind == "viewer")
        .Select(c => new WebViewerMatch(package.Manifest.Id, c.Id, c.Suffixes ?? []));
    public void Activate() { }
    public void Deactivate() { foreach (var attachment in _attachments.ToArray()) _ = attachment.DisposeAsync(); }
    public ITabAttachment Attach(TabContext tab)
    {
        WebAttachment? attachment = null;
        attachment = new WebAttachment(package, tab, () => _attachments.Remove(attachment!));
        _attachments.Add(attachment); return attachment;
    }
}

internal sealed class WebAttachment : ITabAttachment
{
    public const int DocumentByteLimit = 8 * 1024 * 1024;
    private readonly WebPluginPackage _package;
    private readonly TabContext _tab;
    private readonly Action _closed;
    private readonly Grid _view = new();
    private readonly WebView2 _web = new();
    private readonly TextBlock _problem = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12), Visibility = Visibility.Collapsed };
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Dictionary<string, CancellationTokenSource> _streams = new();
    private readonly Dictionary<string, byte[]> _documents = new(StringComparer.Ordinal);
    private readonly WebPluginNetwork _network;
    private readonly string _session = Guid.NewGuid().ToString("N");
    private readonly string _origin;
    private Task? _starting;
    private bool _disposed, _ready, _storageAsked, _storageAllowed;
    private string? _pendingDocument;
    private int _requests;

    public WebAttachment(WebPluginPackage package, TabContext tab, Action closed)
    {
        _package = package; _tab = tab; _closed = closed; _network = new(package);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(package.Manifest.Id))).ToLowerInvariant();
        _origin = "https://p-" + hash[..24] + ".tether.invalid";
        _view.Children.Add(_web); _view.Children.Add(_problem);
        _view.ActualThemeChanged += (_, _) => ContextChanged();
        _tab.Model.SessionChanged += ContextChanged;
    }
    public UIElement View => _view;
    public string? CloseNote => null;
    public bool Receive(IReadOnlyList<string> paths) => false;
    public LinkActions? ActionsFor(TerminalLink link) => null;
    public IReadOnlyList<PluginCommand> Commands => _package.Manifest.Contributions.Where(c => c.Kind == "command")
        .Select(c => new PluginCommand(c.Id, c.Title ?? c.Id, async () =>
        { await ShownAsync(); if (_ready) Post(new { api = 1, type = "command", id = c.Id }); })).ToArray();
    public Task ShownAsync() => _disposed ? Task.CompletedTask : _starting ??= StartAsync();

    private async Task StartAsync()
    {
        try
        {
            var data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tether", "WebPluginSessions", _session);
            var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, data, new CoreWebView2EnvironmentOptions());
            if (_disposed) return;
            var options = environment.CreateCoreWebView2ControllerOptions();
            options.IsInPrivateModeEnabled = true;
            await _web.EnsureCoreWebView2Async(environment, options);
            if (_disposed) return;
            var core = _web.CoreWebView2;
            var settings = core.Settings;
            settings.AreHostObjectsAllowed = false; settings.AreDefaultScriptDialogsEnabled = false;
            settings.AreDefaultContextMenusEnabled = false; settings.AreDevToolsEnabled = false;
            settings.IsStatusBarEnabled = false; settings.IsZoomControlEnabled = false;
            settings.AreBrowserAcceleratorKeysEnabled = false;
            core.SetVirtualHostNameToFolderMapping(new Uri(_origin).Host, _package.Root, CoreWebView2HostResourceAccessKind.DenyCors);
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.DownloadStarting += (_, e) => e.Cancel = true;
            core.NewWindowRequested += (_, e) => e.Handled = true;
            core.NavigationStarting += (_, e) =>
            {
                e.Cancel = !IsAsset(e.Uri); if (!e.Cancel) StopStreams();
            };
            core.FrameNavigationStarting += (_, e) => e.Cancel = true;
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, e) =>
            {
                // Network is exclusively through JSON RPC. No fetch, file URLs,
                // native host objects, popups, downloads or remote page navigation.
                if (!IsAsset(e.Request.Uri) || e.Request.Method != "GET")
                    e.Response = core.Environment.CreateWebResourceResponse(null, 403, "Forbidden", "Content-Type: text/plain");
            };
            core.WebMessageReceived += Message;
            core.NavigationCompleted += (_, e) =>
            {
                if (_disposed) return;
                _ready = e.IsSuccess;
                if (_ready)
                {
                    Post(new { api = 1, type = "ready", session = _session, context = Context() });
                    if (_pendingDocument is { } handle) Post(new { api = 1, type = "document", handle });
                }
                else _problem.Text = "Plugin page could not load: " + e.WebErrorStatus;
                _problem.Visibility = _ready ? Visibility.Collapsed : Visibility.Visible;
            };
            core.Navigate(_origin + "/" + _package.Manifest.Entrypoint);
        }
        catch (Exception ex)
        { if (!_disposed) { _problem.Text = "Plugin could not start: " + ex.Message; _problem.Visibility = Visibility.Visible; } }
    }

    /// <summary>Gives this session the bytes of one file. The page reads them through <c>document.read</c>.</summary>
    public string GrantDocument(byte[] bytes, string? name = null)
    {
        if (!_package.Manifest.Permissions.Contains("document.read")) throw new IOException("This plugin cannot read documents.");
        if (bytes.Length > DocumentByteLimit) throw new IOException("Document exceeds the 8 MiB viewer limit.");
        var handle = Guid.NewGuid().ToString("N");
        _documents[handle] = bytes;
        _pendingDocument = handle;
        if (_ready) Post(new { api = 1, type = "document", handle, name });
        return handle;
    }

    private bool IsAsset(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.GetLeftPart(UriPartial.Authority) == _origin && string.IsNullOrEmpty(uri.UserInfo);
    private object Context() => new
    { hostLabel = _tab.Model.RemoteHost?.Label ?? "localhost", theme = _view.ActualTheme == ElementTheme.Dark ? "dark" : "light" };
    private void ContextChanged()
    {
        if (!_view.DispatcherQueue.HasThreadAccess) { _view.DispatcherQueue.TryEnqueue(ContextChanged); return; }
        if (_ready && !_disposed) Post(new { api = 1, type = "context", context = Context() });
    }
    private void Post(object value)
    {
        if (!_disposed && _web.CoreWebView2 is not null) _web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(value));
    }

    private async void Message(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (_disposed || !IsAsset(e.Source)) return;
        string? id = null;
        try
        {
            if (e.WebMessageAsJson.Length > 64 * 1024) throw new IOException("Plugin message exceeds 64 KiB.");
            using var document = JsonDocument.Parse(e.WebMessageAsJson);
            var root = document.RootElement;
            id = root.GetProperty("id").GetString();
            if (string.IsNullOrWhiteSpace(id) || id.Length > 128 || root.GetProperty("api").GetInt32() != 1 ||
                root.GetProperty("session").GetString() != _session) throw new IOException("Invalid plugin session.");
            if (_requests >= 8) throw new IOException("Too many plugin requests.");
            _requests++;
            try
            {
                var payload = root.GetProperty("payload");
                object? result;
                switch (root.GetProperty("method").GetString())
                {
                    case "service.ensure":
                        await WebPluginServices.EnsureAsync(_package, payload.GetProperty("service").GetString()!, _lifetime.Token);
                        result = new { ready = true };
                        break;
                    case "network.get":
                        result = new { text = await _network.GetAsync(payload.GetProperty("url").GetString()!, _lifetime.Token) };
                        break;
                    case "network.subscribe":
                        if (_streams.Count >= 2) throw new IOException("Too many plugin streams.");
                        var url = payload.GetProperty("url").GetString()!;
                        _package.NetworkUri(url);
                        var subscription = Guid.NewGuid().ToString("N");
                        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
                        _streams.Add(subscription, cancellation);
                        result = new { subscription };
                        Post(new { api = 1, type = "response", id, result });
                        _ = StreamAsync(subscription, url, cancellation);
                        return;
                    case "network.unsubscribe":
                        if (_streams.Remove(payload.GetProperty("subscription").GetString()!, out var pending)) pending.Cancel();
                        result = null;
                        break;
                    case "document.read":
                        if (!_package.Manifest.Permissions.Contains("document.read")) throw new IOException("permissionDenied");
                        var handle = payload.TryGetProperty("handle", out var handleEl) ? handleEl.GetString() : null;
                        if (string.IsNullOrWhiteSpace(handle) || !_documents.TryGetValue(handle, out var bytes))
                            throw new IOException(string.IsNullOrWhiteSpace(handle) ? "noGrant" : "invalidHandle");
                        result = new { bytes = Convert.ToBase64String(bytes) };
                        break;
                    case "storage.plugin.get":
                        result = new { value = await StorageAsync(payload, write: false) };
                        break;
                    case "storage.plugin.set":
                        await StorageAsync(payload, write: true);
                        result = null;
                        break;
                    case "host.notify":
                        var title = payload.GetProperty("title").GetString();
                        if (string.IsNullOrWhiteSpace(title)) throw new IOException("malformed");
                        await Alerts.ContentAsync(_package.Manifest.Name, title, "Close", null, _view.ActualTheme, _ => { });
                        result = null;
                        break;
                    default: throw new IOException("Unknown plugin capability.");
                }
                Post(new { api = 1, type = "response", id, result });
            }
            finally { _requests--; }
        }
        catch (Exception ex) { if (!_disposed) Post(new { api = 1, type = "response", id, error = ex.Message }); }
    }

    private async Task<string?> StorageAsync(JsonElement payload, bool write)
    {
        if (!_package.Manifest.Permissions.Contains("storage.plugin")) throw new IOException("permissionDenied");
        if (!_storageAsked)
        {
            _storageAsked = true;
            _storageAllowed = await Alerts.ContentAsync(_package.Manifest.Name, "storage.plugin", "Allow", null,
                _view.ActualTheme, _ => { }) == ContentDialogResult.Primary;
        }
        if (!_storageAllowed) throw new IOException("consentDenied");
        var key = payload.GetProperty("key").GetString();
        if (string.IsNullOrWhiteSpace(key) || key.Length > 256) throw new IOException("malformed");
        var bucket = WebPluginStorage.Load(_package.Manifest.Id);
        if (!write) return bucket.GetValueOrDefault(key);
        var value = payload.GetProperty("value").GetString() ?? throw new IOException("malformed");
        if (Encoding.UTF8.GetByteCount(value) > 64 * 1024) throw new IOException("malformed");
        bucket[key] = value;
        WebPluginStorage.Save(_package.Manifest.Id, bucket);
        return null;
    }

    private async Task StreamAsync(string id, string url, CancellationTokenSource cancellation)
    {
        try
        {
            await _network.StreamAsync(url, text =>
            {
                Post(new { api = 1, type = "event", subscription = id, text }); return Task.CompletedTask;
            }, cancellation.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (!_disposed) Post(new { api = 1, type = "event", subscription = id, error = ex.Message }); }
        finally { _streams.Remove(id); cancellation.Dispose(); }
    }
    private void StopStreams()
    {
        foreach (var cancellation in _streams.Values.ToArray()) cancellation.Cancel();
        _streams.Clear(); _ready = false;
    }
    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true; _lifetime.Cancel(); StopStreams();
        _documents.Clear(); _pendingDocument = null;
        _tab.Model.SessionChanged -= ContextChanged;
        _web.Close(); _network.Dispose(); _lifetime.Dispose(); _closed();
        return ValueTask.CompletedTask;
    }
}

/// <summary>Per-plugin string storage under the Windows account. No secrets, no paths.</summary>
internal static class WebPluginStorage
{
    private static string PathFor(string id) =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Tether", "PluginStorage", id + ".json");

    public static Dictionary<string, string> Load(string id)
    {
        var path = PathFor(id);
        if (!File.Exists(path)) return new(StringComparer.Ordinal);
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))
                ?.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal)
                ?? new(StringComparer.Ordinal);
        }
        catch { return new(StringComparer.Ordinal); }
    }

    public static void Save(string id, Dictionary<string, string> values)
    {
        var path = PathFor(id);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(values));
    }

    public static void Wipe(string id)
    {
        var path = PathFor(id);
        if (File.Exists(path)) File.Delete(path);
    }
}

public static class WebPluginCatalog
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tether", "Plugins");
    public static List<string> Problems { get; } = [];
    public static bool IsInstalled(string id) => Directory.Exists(Path.Combine(Root, id));
    public static WebPluginPackage? Installed(string id)
    {
        try { return IsInstalled(id) ? WebPluginPackage.Read(Path.Combine(Root, id)) : null; }
        catch { return null; }
    }
    public static void Discover(PluginRegistry registry)
    {
        Problems.Clear();
        if (!Directory.Exists(Root)) return;
        foreach (var directory in Directory.EnumerateDirectories(Root).Where(d => !Path.GetFileName(d).StartsWith('.')))
            try { registry.Register(new WebPlugin(WebPluginPackage.Read(directory))); }
            catch (Exception ex) { Problems.Add(Path.GetFileName(directory) + ": " + ex.Message); }
    }
    public static void Install(string source, PluginRegistry registry, bool replace = false)
    {
        var package = WebPluginPackage.Read(source);
        var existing = registry.Plugins.FirstOrDefault(p => p.Metadata.Id == package.Manifest.Id);
        if (existing is not null && !replace) throw new IOException("This plugin is already registered.");
        if (existing is not null) registry.Unregister(package.Manifest.Id);
        registry.Register(new WebPlugin(WebPluginPackage.Install(source, Root, replace)));
    }
    public static void Update(string source, PluginRegistry registry)
    {
        var package = WebPluginPackage.Read(source);
        if (!registry.Plugins.Any(p => p.Metadata.Id == package.Manifest.Id) && !IsInstalled(package.Manifest.Id))
            throw new IOException("This plugin is not installed. Install it instead of updating.");
        Install(source, registry, replace: true);
    }
    public static void Uninstall(string id, PluginRegistry registry)
    {
        if (!IsInstalled(id) && !registry.Plugins.Any(p => p.Metadata.Id == id))
            throw new IOException("This plugin is not installed.");
        registry.Unregister(id);
        WebPluginPackage.RemoveInstalled(Root, id);
        WebPluginStorage.Wipe(id);
    }

    /// <summary>Enabled web viewers that claim this file suffix (no leading dot).</summary>
    public static IReadOnlyList<(WebPlugin Plugin, WebViewerMatch Match)> ViewersFor(PluginRegistry registry, string suffix)
    {
        var key = WebPluginPackage.NormalizeSuffix(suffix);
        if (key.Length == 0) return [];
        return registry.Plugins.OfType<WebPlugin>()
            .Where(plugin => registry.IsEnabled(plugin.Metadata.Id))
            .SelectMany(plugin => plugin.Viewers
                .Where(viewer => viewer.Suffixes.Contains(key, StringComparer.Ordinal))
                .Select(viewer => (plugin, viewer)))
            .ToArray();
    }
}
