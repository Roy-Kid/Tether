using System.Text;

namespace TetherApp.Plugins;

/// <summary>Only GET, only declared origins, no redirects, cookies, credentials or proxies.</summary>
public sealed class WebPluginNetwork(WebPluginPackage package) : IDisposable
{
    public const int MaxPayload = 4 * 1024 * 1024;
    private readonly HttpClient _client = new(new HttpClientHandler
    { AllowAutoRedirect = false, UseCookies = false, UseProxy = false, Credentials = null }) { Timeout = Timeout.InfiniteTimeSpan };

    public async Task<string> GetAsync(string url, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(10));
        using var response = await _client.GetAsync(package.NetworkUri(url), HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        Check(response);
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        using var body = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = await stream.ReadAsync(buffer, timeout.Token)) != 0)
        {
            if (body.Length + count > MaxPayload) throw new IOException("Plugin response exceeds 4 MiB.");
            body.Write(buffer, 0, count);
        }
        return Encoding.UTF8.GetString(body.ToArray());
    }

    public async Task StreamAsync(string url, Func<string, Task> frame, CancellationToken token)
    {
        using var headers = CancellationTokenSource.CreateLinkedTokenSource(token); headers.CancelAfter(TimeSpan.FromSeconds(10));
        using var request = new HttpRequestMessage(HttpMethod.Get, package.NetworkUri(url));
        request.Headers.Accept.ParseAdd("text/event-stream");
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, headers.Token);
        Check(response);
        if (response.Content.Headers.ContentType?.MediaType != "text/event-stream") throw new IOException("Expected an event stream.");
        await using var stream = await response.Content.ReadAsStreamAsync(token);
        await PumpAsync(stream, frame, token);
    }

    private static void Check(HttpResponseMessage response)
    {
        if ((int)response.StatusCode is >= 300 and < 400) throw new IOException("Plugin network redirects are not allowed.");
        if (!response.IsSuccessStatusCode) throw new IOException($"Plugin network request failed ({(int)response.StatusCode}).");
        if (response.Content.Headers.ContentLength > MaxPayload) throw new IOException("Plugin response exceeds 4 MiB.");
    }

    // Chunked reads impose the ceiling before buffering a malicious, unterminated line.
    public static async Task PumpAsync(Stream stream, Func<string, Task> frame, CancellationToken token)
    {
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var buffer = new char[4096]; var line = new StringBuilder(); var data = new StringBuilder();
        int count;
        async Task Line()
        {
            var text = line.ToString().TrimEnd('\r'); line.Clear();
            if (text.Length == 0)
            {
                if (data.Length > 0) { var payload = data.ToString().TrimEnd('\n'); data.Clear(); await frame(payload); }
            }
            else if (text.StartsWith("data:", StringComparison.Ordinal))
            {
                var value = text[5..]; if (value.StartsWith(' ')) value = value[1..];
                data.Append(value).Append('\n');
                if (data.Length > MaxPayload) throw new IOException("Plugin event exceeds 4 MiB.");
            }
        }
        while ((count = await reader.ReadAsync(buffer, token)) != 0)
            for (var i = 0; i < count; i++)
            {
                if (buffer[i] == '\n') await Line();
                else { line.Append(buffer[i]); if (line.Length > MaxPayload) throw new IOException("Plugin event line exceeds 4 MiB."); }
            }
        throw new IOException("Plugin event stream disconnected.");
    }

    public void Dispose() => _client.Dispose();
}
