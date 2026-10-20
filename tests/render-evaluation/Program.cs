using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Tether;
using TerminalSurface = Tether.TerminalSurface;

internal static class Program
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    [STAThread]
    private static int Main(string[] args)
    {
        try { return Run(args); }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static int Run(string[] args)
    {
        if (args.SequenceEqual(new[] { "--validate-fixtures" }))
        {
            Frames.VerifyFixtures();
            Console.WriteLine("PASS: frame fixture contracts and mixed-width negative control");
            return 0;
        }
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        var options = args.Chunk(2).ToDictionary(pair => pair[0], pair => pair[1]);
        string Option(string name, string fallback) => options.GetValueOrDefault(name, fallback);
        var output = Path.GetFullPath(Option("--output", "artifacts/windows-render-evaluation/single"));
        Directory.CreateDirectory(output);
        if (new[] { "result.json", "native.csv", "calls.csv", "snapshot.ppm" }.Any(name => File.Exists(Path.Combine(output, name))))
            throw new IOException("Use a fresh scenario directory; existing evidence must not be overwritten or appended");
        var columns = uint.Parse(Option("--columns", "80"));
        var rows = uint.Parse(Option("--rows", "24"));
        var shape = Option("--shape", "prose");
        var mode = Option("--mode", "scroll");
        var seconds = double.Parse(Option("--seconds", "5"));
        var scale = double.Parse(Option("--scale", "1"));
        var snapshot = mode == "snapshot";
        if (!new[] { "prose", "highlighted", "worstCase", "fonts" }.Contains(shape)
            || !new[] { "static", "cursor", "line", "scroll", "snapshot", "lifecycle" }.Contains(mode)
            || !double.IsFinite(seconds) || !double.IsFinite(scale)
            || seconds <= 0 || scale <= 0 || columns is < 1 or > 400 || rows is < 1 or > 100)
            throw new ArgumentException("Invalid evaluation scenario");
        Environment.SetEnvironmentVariable("WGPU_BACKEND", "dx12");
        Environment.SetEnvironmentVariable("TETHER_RENDER_TRACE", Path.Combine(output, "native.csv"));
        Environment.SetEnvironmentVariable("TETHER_RENDER_ADAPTER", Path.Combine(output, "adapter.txt"));
        Environment.SetEnvironmentVariable("TETHER_RENDER_CAPTURE", snapshot ? Path.Combine(output, "snapshot.ppm") : null);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        using var window = new EvaluationWindow { Text = "Tether renderer evaluation", StartPosition = FormStartPosition.CenterScreen };
        var cancelled = false;
        var allowClose = false;
        // The HWND must outlive its Rust surface, even when a person closes
        // the benchmark. Defer destruction until after surface.Dispose().
        window.FormClosing += (_, e) => { if (!allowClose) { cancelled = true; e.Cancel = true; } };
        window.Show();
        Application.DoEvents();
        if (cancelled) { allowClose = true; window.Close(); return 3; }
        // Await before returning to the UI loop; no synchronization-context deadlock.
        SynchronizationContext.SetSynchronizationContext(null);
        var watch = Stopwatch.StartNew();
        TerminalSurface surface;
        try { surface = TerminalSurface.FromHwndAsync(window.Handle, 640, 480).GetAwaiter().GetResult(); }
        catch (Exception error) when (error is not (DllNotFoundException or BadImageFormatException or EntryPointNotFoundException or TypeInitializationException))
        {
            File.WriteAllText(Path.Combine(output, "gpu-unverified.json"), JsonSerializer.Serialize(new {
                status = "unverified", reason = "GPU surface initialization unavailable", diagnostic = error.ToString(),
                columns, rows, shape, mode, scale
            }, Json));
            allowClose = true;
            window.Close();
            return 2;
        }
        var createMs = watch.Elapsed.TotalMilliseconds;
        using (surface)
        {
            watch.Restart();
            surface.SetFonts("Consolas", "Microsoft YaHei UI");
            var metrics = surface.Measure((float)(13 * scale));
            var fontsMs = watch.Elapsed.TotalMilliseconds;
            var width = (int)Math.Ceiling(columns * metrics.CellWidth);
            var height = (int)Math.Ceiling(rows * metrics.LineHeight);
            window.ClientSize = new Size(width, height);
            surface.Resize((uint)width, (uint)height);
            Application.DoEvents();
            var frame = Frames.Create(columns, rows, shape);
            Frames.Validate(frame);
            var overlay = new Overlay(new Selection(new Cell(1, 1), new Cell(12, 2)),
                new[] { new LinkUnderline(0, 0, 12, true) }, new Rgba(.3f, .5f, 1f, .25f), new Rgba(.3f, .7f, 1f, 1f));
            watch.Restart();
            surface.Draw(frame, Palette.Dark, overlay);
            var firstDrawMs = watch.Elapsed.TotalMilliseconds;
            using var process = Process.GetCurrentProcess();
            var warmupDraws = 1;
            if (!snapshot)
            {
                for (var n = 0; n < 120; n++)
                {
                    surface.Draw(frame, Palette.Dark, overlay);
                    warmupDraws++;
                    Application.DoEvents();
                }
            }
            process.Refresh();
            var memoryBefore = process.PrivateMemorySize64;
            var cpuBefore = process.TotalProcessorTime;
            using var calls = new StreamWriter(Path.Combine(output, "calls.csv"));
            calls.WriteLine("index,start_qpc,end_qpc,managed_draw_ms,private_bytes");
            var samples = new List<double>();
            var lifecycle = new List<string>();
            var measurementStartQpc = Stopwatch.GetTimestamp();
            var timer = Stopwatch.StartNew();
            var nextTick = 0.0;
            var index = 0;
            while (!snapshot && !cancelled && timer.Elapsed.TotalSeconds < seconds)
            {
                Application.DoEvents();
                if (cancelled) break;
                if (mode == "static") { Thread.Sleep(10); continue; }
                var remaining = nextTick - timer.Elapsed.TotalMilliseconds;
                if (remaining > 1) { Thread.Sleep((int)Math.Min(remaining, 5)); continue; }
                if (remaining > 0) { Thread.Yield(); continue; }
                nextTick += 1000.0 / 60.0;
                // Do not compensate a slow frame by generating a burst of frames.
                nextTick = Math.Max(nextTick, timer.Elapsed.TotalMilliseconds);
                frame = Frames.Update(frame, shape, mode, index);
                if (mode == "lifecycle" && index % 60 == 0)
                {
                    window.WindowState = FormWindowState.Minimized;
                    Application.DoEvents();
                    window.WindowState = FormWindowState.Normal;
                    window.ClientSize = new Size(width + index % 3, height + index % 5);
                    Application.DoEvents();
                    surface.Resize((uint)window.ClientSize.Width, (uint)window.ClientSize.Height);
                    lifecycle.Add($"resize/minimize/restore:{index}");
                }
                var start = Stopwatch.GetTimestamp();
                surface.Draw(frame, Palette.Dark, overlay);
                var end = Stopwatch.GetTimestamp();
                var elapsed = (end - start) * 1000.0 / Stopwatch.Frequency;
                samples.Add(elapsed);
                if (index % 60 == 0) process.Refresh();
                calls.WriteLine($"{index},{start},{end},{elapsed:F6},{process.PrivateMemorySize64}");
                index++;
            }
            process.Refresh();
            var wall = timer.Elapsed.TotalSeconds;
            var cpuSeconds = (process.TotalProcessorTime - cpuBefore).TotalSeconds;
            var result = new {
                schema = 1, pid = Environment.ProcessId, columns, rows, shape, mode, scale,
                cancelled,
                requested_seconds = seconds, measured_seconds = wall,
                qpc_frequency = Stopwatch.Frequency, create_ms = createMs, fonts_ms = fontsMs,
                measurement_start_qpc = measurementStartQpc, measurement_end_qpc = Stopwatch.GetTimestamp(),
                first_draw_ms = firstDrawMs, warmup_draws = warmupDraws,
                draws = index, draw_ms = Summary(samples),
                private_bytes_before = memoryBefore, private_bytes_after = process.PrivateMemorySize64,
                cpu_core_percent = wall > 0 ? cpuSeconds / wall * 100 : 0,
                cpu_machine_percent = wall > 0 ? cpuSeconds / wall / Environment.ProcessorCount * 100 : 0,
                physical_surface = new { width, height }, device_dpi = window.DeviceDpi,
                font_size_physical_px = metrics.Size,
                desktop = Screen.AllScreens.Select(screen => new { screen.DeviceName, screen.Bounds, screen.Primary }),
                primary_font = "Consolas", wide_font = "Microsoft YaHei UI",
                os = Environment.OSVersion.ToString(), runtime = Environment.Version.ToString(),
                lifecycle, actual_present = "requires PresentMon displayed-frame ETW evidence",
                gpu_utilization = (double?)null, gpu_utilization_status = "requires external GPU engine counters",
                note = "managed_draw_ms includes FFI, native work and blocking; it is not presentation latency"
            };
            File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(result, Json));
        }
        allowClose = true;
        window.Close();
        Console.WriteLine(output);
        return cancelled ? 3 : 0;
    }

    private static object? Summary(List<double> values)
    {
        if (values.Count == 0) return null;
        values.Sort();
        double P(double p) => values[Math.Clamp((int)Math.Ceiling(values.Count * p) - 1, 0, values.Count - 1)];
        return new { p50 = P(.5), p95 = P(.95), p99 = P(.99), max = values[^1] };
    }
}

internal sealed class EvaluationWindow : Form
{
    // A visible HWND is required; taking keyboard focus from the user's
    // application every time a scenario starts is not.
    protected override bool ShowWithoutActivation => true;
}
