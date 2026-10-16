using System.Diagnostics;
using System.Text;

namespace TetherApp;

public static class BoundedProcess
{
    public static async Task<string> RunAsync(string program, IEnumerable<string> arguments, string? input = null,
        CancellationToken token = default, int limit = 2 * 1024 * 1024, int timeoutSeconds = 15, Encoding? outputEncoding = null)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        var start = new ProcessStartInfo(program) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = outputEncoding ?? Encoding.UTF8, StandardErrorEncoding = outputEncoding ?? Encoding.UTF8 };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Unable to start " + Path.GetFileName(program));
        using var cancellation = timeout.Token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        async Task<string> ReadAsync(StreamReader reader)
        {
            var result = new StringBuilder(); var buffer = new char[4096];
            while (true)
            {
                var count = await reader.ReadAsync(buffer, timeout.Token);
                if (count == 0) return result.ToString();
                if (result.Length + count > limit) { timeout.Cancel(); throw new IOException("Command output exceeded the capture limit."); }
                result.Append(buffer, 0, count);
            }
        }
        var output = ReadAsync(process.StandardOutput); var error = ReadAsync(process.StandardError);
        var io = Task.WhenAll(output, error);
        try
        {
            if (input is not null) await process.StandardInput.WriteAsync(input.AsMemory(), timeout.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token);
            await io;
            if (process.ExitCode != 0) throw new IOException(string.IsNullOrWhiteSpace(error.Result) ? "Command failed (status " + process.ExitCode + ")." : error.Result.Trim());
            return output.Result;
        }
        catch
        {
            timeout.Cancel();
            try { await io; } catch { }
            throw;
        }
    }
}
