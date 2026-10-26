using System.Diagnostics;
using System.Text.Json;
using Tether;
using TetherApp;

/// <summary>Optional CPU/allocation observation; no GPU and no pass/fail timing budget.</summary>
internal static class AppearanceCost
{
    internal static void Run()
    {
        const int iterations = 250_000;
        var source = Palette.Dark;
        var resolved = TerminalAppearance.ForRendering(source, true);
        Func<Palette, Palette> previous = palette => palette with { Background = palette.Background with { Alpha = 0 } };
        Func<Palette, Palette> reused = _ => TerminalAppearance.ForRendering(resolved, true);
        var samples = new List<object>();
        foreach (var (name, transform) in new[] { ("previous_per_draw_clone", previous), ("resolved_palette_reuse", reused) })
        {
            for (var index = 0; index < 10_000; index++) GC.KeepAlive(transform(source));
            for (var repeat = 0; repeat < 5; repeat++)
            {
                var bytes = GC.GetAllocatedBytesForCurrentThread();
                var start = Stopwatch.GetTimestamp();
                for (var index = 0; index < iterations; index++) GC.KeepAlive(transform(source));
                var milliseconds = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
                var allocated = GC.GetAllocatedBytesForCurrentThread() - bytes;
                samples.Add(new { name, repeat, iterations, milliseconds, allocated_bytes = allocated });
            }
        }
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            kind = "CPU palette lifecycle microbenchmark", runtime = Environment.Version.ToString(),
            os = Environment.OSVersion.ToString(), samples,
            note = "Previous palette cloning versus steady-state reuse only; excludes FFI, shaping, GPU execution and displayed-frame latency. Informational; never a CI performance gate."
        }, new JsonSerializerOptions { WriteIndented = true }));
    }
}
