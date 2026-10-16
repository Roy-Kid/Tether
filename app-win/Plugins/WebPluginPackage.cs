using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TetherApp.Plugins;

public sealed record WebContribution(string Kind, string Id, string? Title = null, string[]? Suffixes = null);
public sealed record WebPluginManifest(string Id, string Name, string Publisher, string Version, int Api,
    string Runtime, string Entrypoint, string AgeRating, string Link, string[] Permissions,
    WebContribution[] Contributions, string[]? NetworkOrigins = null, string? Glyph = null, string? Summary = null, string[]? Services = null);

public sealed record WebViewerMatch(string PluginId, string ContributionId, string[] Suffixes);

/// <summary>Static package inspection. Loading metadata never executes the page.</summary>
public sealed record WebPluginPackage(string Root, WebPluginManifest Manifest)
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    private static readonly HashSet<string> Assets = new(StringComparer.OrdinalIgnoreCase)
    { ".json", ".html", ".htm", ".css", ".js", ".mjs", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".woff", ".woff2", ".ttf", ".otf", ".wasm" };

    public string EntryPath => Resolve(Manifest.Entrypoint);
    public string Resolve(string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || relative.Contains('\\') || relative.Contains(':') ||
            relative.Split('/').Any(p => p is "" or "." or "..")) throw new IOException("Invalid plugin asset path.");
        var path = Path.GetFullPath(Path.Combine(Root, relative));
        if (!path.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Plugin asset leaves its package.");
        return path;
    }

    public static WebPluginPackage Read(string directory)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory));
        if (!Directory.Exists(root)) throw new IOException("Plugin directory is missing.");
        var package = new WebPluginPackage(root, ReadManifest(root));
        long bytes = 0; var files = 0;
        void Inspect(string folder, int depth = 0)
        {
            if (depth > 32) throw new IOException("Plugin directory nesting exceeds 32 levels.");
            if (File.GetAttributes(folder).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Plugin links are not allowed.");
            foreach (var path in Directory.EnumerateFileSystemEntries(folder))
            {
                var attributes = File.GetAttributes(path);
                if (attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Plugin links are not allowed.");
                if (attributes.HasFlag(FileAttributes.Directory)) { Inspect(path, depth + 1); continue; }
                if (++files > 4096) throw new IOException("Plugin package exceeds 4096 files.");
                var name = Path.GetFileName(path);
                if (!Assets.Contains(Path.GetExtension(path))) throw new IOException($"Unsupported plugin payload: {name}.");
                bytes += new FileInfo(path).Length;
                if (bytes > 32 * 1024 * 1024) throw new IOException("Plugin package exceeds 32 MiB.");
                using var stream = File.OpenRead(path);
                Span<byte> header = new byte[4];
                var count = stream.Read(header);
                if ((count >= 2 && header[0] == 0x4d && header[1] == 0x5a) ||
                    (count == 4 && (header.SequenceEqual(new byte[] { 0x7f, 0x45, 0x4c, 0x46 }) ||
                    header.SequenceEqual(new byte[] { 0xfe, 0xed, 0xfa, 0xce }) || header.SequenceEqual(new byte[] { 0xce, 0xfa, 0xed, 0xfe }) ||
                    header.SequenceEqual(new byte[] { 0xfe, 0xed, 0xfa, 0xcf }) || header.SequenceEqual(new byte[] { 0xcf, 0xfa, 0xed, 0xfe }) ||
                    header.SequenceEqual(new byte[] { 0xca, 0xfe, 0xba, 0xbe }) || header.SequenceEqual(new byte[] { 0xbe, 0xba, 0xfe, 0xca }))))
                    throw new IOException($"Native plugin payload is not allowed: {name}.");
                if (name.Equals("package.json", StringComparison.OrdinalIgnoreCase))
                {
                    using var document = JsonDocument.Parse(File.ReadAllText(path));
                    if (document.RootElement.TryGetProperty("scripts", out var scripts) &&
                        new[] { "install", "preinstall", "postinstall" }.Any(key => scripts.TryGetProperty(key, out _)))
                        throw new IOException("Plugin install scripts are not allowed.");
                }
            }
        }
        Inspect(root);
        if (!File.Exists(package.EntryPath) || Path.GetExtension(package.EntryPath).ToLowerInvariant() is not (".html" or ".htm"))
            throw new IOException("Plugin HTML entrypoint is missing.");
        return package;
    }

    private static WebPluginManifest ReadManifest(string root)
    {
        var path = Path.Combine(root, "manifest.json");
        if (new FileInfo(path).Length > 64 * 1024) throw new IOException("Plugin manifest exceeds 64 KiB.");
        var manifest = JsonSerializer.Deserialize<WebPluginManifest>(File.ReadAllText(path), Json) ?? throw new IOException("Invalid plugin manifest.");
        if (manifest.Api != 1 || manifest.Runtime != "web") throw new IOException("Only API 1 web plugins are supported.");
        if (manifest.Id is null || !Regex.IsMatch(manifest.Id, @"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$") ||
            new[] { manifest.Name, manifest.Publisher, manifest.Version, manifest.AgeRating }.Any(string.IsNullOrWhiteSpace))
            throw new IOException("Plugin identity is incomplete.");
        if (!Uri.TryCreate(manifest.Link, UriKind.Absolute, out var link) || link.Scheme is not ("https" or "http"))
            throw new IOException("Invalid plugin link.");
        var allowed = new HashSet<string> { "network", "service.local", "document.read", "storage.plugin" };
        if (manifest.Permissions is null || manifest.Permissions.Any(p => !allowed.Contains(p)))
            throw new IOException("Unsupported plugin capability.");
        if (manifest.Contributions is null ||
            !manifest.Contributions.Any(c => c.Kind is "panel" or "viewer") ||
            manifest.Contributions.Any(c => c.Kind is not ("panel" or "command" or "viewer") || string.IsNullOrWhiteSpace(c.Id)) ||
            manifest.Contributions.Select(c => c.Id).Distinct(StringComparer.Ordinal).Count() != manifest.Contributions.Length)
            throw new IOException("Plugin must declare a panel or viewer, and unique contributions.");
        foreach (var contribution in manifest.Contributions.Where(c => c.Kind == "viewer"))
        {
            var suffixes = (contribution.Suffixes ?? []).Select(NormalizeSuffix).Where(s => s.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
            if (suffixes.Length == 0) throw new IOException("A viewer contribution needs at least one file suffix.");
            if (!manifest.Permissions.Contains("document.read"))
                throw new IOException("Viewer contributions require the document.read permission.");
        }
        foreach (var origin in manifest.NetworkOrigins ?? [])
        {
            if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri) || uri.GetLeftPart(UriPartial.Authority) != origin ||
                !string.IsNullOrEmpty(uri.UserInfo) || (uri.Scheme != "https" && !(uri.Scheme == "http" &&
                IPAddress.TryParse(uri.Host, out var ip) && IPAddress.IsLoopback(ip))))
                throw new IOException("Network origins must be HTTPS or a literal loopback HTTP origin.");
        }
        if ((manifest.NetworkOrigins?.Length ?? 0) > 0 && !manifest.Permissions.Contains("network"))
            throw new IOException("Network origins require the network permission.");
        if ((manifest.Services?.Length ?? 0) > 0 && !manifest.Permissions.Contains("service.local"))
            throw new IOException("Local services require the service.local permission.");
        return manifest with
        {
            Contributions = manifest.Contributions.Select(c => c.Kind == "viewer"
                ? c with { Suffixes = (c.Suffixes ?? []).Select(NormalizeSuffix).Where(s => s.Length > 0).Distinct(StringComparer.Ordinal).ToArray() }
                : c).ToArray(),
        };
    }

    public static string NormalizeSuffix(string suffix) =>
        suffix.Trim().TrimStart('.').ToLowerInvariant();

    public Uri NetworkUri(string value)
    {
        if (!Manifest.Permissions.Contains("network") || !Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment) ||
            !(Manifest.NetworkOrigins ?? []).Contains(uri.GetLeftPart(UriPartial.Authority), StringComparer.Ordinal))
            throw new IOException("Plugin network origin is not granted.");
        return uri;
    }

    public static WebPluginPackage Install(string source, string installedRoot, bool replace = false)
    {
        var package = Read(source);
        Directory.CreateDirectory(installedRoot);
        var destination = Path.Combine(Path.GetFullPath(installedRoot), package.Manifest.Id);
        if (Directory.Exists(destination) && !replace) throw new IOException("This plugin is already installed.");
        var stage = Path.Combine(Path.GetFullPath(installedRoot), ".install-" + Guid.NewGuid().ToString("N"));
        string? backup = null;
        try
        {
            foreach (var file in Directory.EnumerateFiles(package.Root, "*", SearchOption.AllDirectories))
            {
                var target = Path.Combine(stage, Path.GetRelativePath(package.Root, file));
                Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file, target);
            }
            Read(stage);
            if (Directory.Exists(destination))
            {
                backup = Path.Combine(Path.GetFullPath(installedRoot), ".replace-" + Guid.NewGuid().ToString("N"));
                Directory.Move(destination, backup);
            }
            Directory.Move(stage, destination);
            if (backup is not null) Directory.Delete(backup, true);
            return Read(destination);
        }
        catch
        {
            if (backup is not null && !Directory.Exists(destination) && Directory.Exists(backup))
                Directory.Move(backup, destination);
            throw;
        }
        finally
        {
            if (Directory.Exists(stage)) Directory.Delete(stage, true);
            if (backup is not null && Directory.Exists(backup)) Directory.Delete(backup, true);
        }
    }

    public static void RemoveInstalled(string installedRoot, string id)
    {
        if (string.IsNullOrWhiteSpace(id) || id.Contains('/') || id.Contains('\\') || id is "." or "..")
            throw new IOException("Invalid plugin id.");
        var destination = Path.Combine(Path.GetFullPath(installedRoot), id);
        if (!destination.StartsWith(Path.GetFullPath(installedRoot) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Plugin directory leaves the install root.");
        if (Directory.Exists(destination)) Directory.Delete(destination, true);
    }
}
