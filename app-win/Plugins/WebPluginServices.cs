using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;

namespace TetherApp.Plugins;

/// <summary>Host-approved installed companions. Pages cannot choose executables or arguments.</summary>
public static class WebPluginServices
{
    private sealed record Companion(string Plugin, string Executable, Uri Health);
    private static readonly Dictionary<string, Companion> Services = new(StringComparer.Ordinal);
    private static readonly HttpClient Client = new(new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false })
        { Timeout = TimeSpan.FromSeconds(1) };

    public static void Register(string id, string plugin, string executable, Uri health) =>
        Services.Add(id, new(plugin, Path.GetFullPath(executable), health));

    public static async Task EnsureAsync(WebPluginPackage package, string id, CancellationToken cancellation)
    {
        if (!package.Manifest.Permissions.Contains("service.local") ||
            !(package.Manifest.Services ?? []).Contains(id, StringComparer.Ordinal) ||
            !Services.TryGetValue(id, out var service) || service.Plugin != package.Manifest.Id)
            throw new IOException("Local service is not granted by this host.");
        package.NetworkUri(service.Health.AbsoluteUri);
        async Task<bool> Healthy()
        {
            try
            {
                using var response = await Client.GetAsync(service.Health, cancellation);
                if (!response.IsSuccessStatusCode) return false;
                using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellation));
                return body.RootElement.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True;
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException) { return false; }
        }
        if (await Healthy()) return;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tether", "ServiceLocks");
        Directory.CreateDirectory(folder);
        var key = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(id)));
        FileStream? gate = null;
        while (gate is null)
        {
            deadline.Token.ThrowIfCancellationRequested();
            try { gate = new FileStream(Path.Combine(folder, key), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { await Task.Delay(100, deadline.Token); }
        }
        using (gate)
        {
            if (await Healthy()) return;
            if (!File.Exists(service.Executable)) throw new IOException("Install the companion app before opening this plugin.");
            var start = new ProcessStartInfo(service.Executable) { UseShellExecute = false, CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(service.Executable)! };
            start.ArgumentList.Add("serve");
            using var process = Process.Start(start) ?? throw new IOException("Could not start the local service.");
            while (!await Healthy())
            {
                if (process.HasExited && process.ExitCode != 0) throw new IOException("Local service failed to start.");
                await Task.Delay(150, deadline.Token);
            }
        }
    }
}
