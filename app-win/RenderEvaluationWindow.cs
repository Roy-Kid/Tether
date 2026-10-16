#if DEBUG
using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TetherApp;

/// <summary>Offline fixture using real TerminalControls; no sessions or saved user state.</summary>
internal static class RenderEvaluationWindow
{
    internal static Window Create(string output)
    {
        output = Path.GetFullPath(output);
        Directory.CreateDirectory(output);
        var window = new Window { Title = "Tether WinUI renderer evaluation" };
        var grid = new Grid { RequestedTheme = ElementTheme.Dark };
        grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        window.Content = grid;
        window.AppWindow.ResizeClient(new Windows.Graphics.SizeInt32(1600, 1100));
        var failures = new List<string>();
        var events = new List<string>();
        var controls = new TerminalControl[2];
        TerminalControl Add(int column)
        {
            var control = new TerminalControl { WantsFocus = () => false };
            control.EvaluationFailure = error => failures.Add(error.ToString());
            Grid.SetColumn(control, column);
            grid.Children.Add(control);
            control.SetEvaluationFrame(Frames.Create(80, 40, "fonts"));
            return control;
        }
        controls[0] = Add(0);
        controls[1] = Add(1);
        var process = Process.GetCurrentProcess();
        var started = Stopwatch.StartNew();
        var samples = new List<object>();
        var tick = 0;
        var nextFrame = 0.0;
        void Save(bool finished) => File.WriteAllText(Path.Combine(output, "winui.json"), JsonSerializer.Serialize(new {
            finished, tick, requested_updates_per_second = 60, updates_per_second = tick / started.Elapsed.TotalSeconds,
            event_count = events.Count, seconds = started.Elapsed.TotalSeconds, events, failures, samples,
            note = "Real TerminalControls and child HWNDs; synthetic frames. Cross-monitor, device loss and production split layout require separate review."
        }, new JsonSerializerOptions { WriteIndented = true }));
        var frames = new[] { Frames.Create(80, 40, "fonts"), Frames.Create(80, 40, "fonts") };
        // A 16.7ms DispatcherTimer can quantize to roughly 32Hz. Use a fast
        // wake with QPC deadlines, and record achieved updates, never FPS.
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1) };
        timer.Tick += (_, _) =>
        {
            var now = started.Elapsed.TotalMilliseconds;
            if (now < nextFrame) return;
            nextFrame = Math.Max(nextFrame + 1000.0 / 60.0, now);
            tick++;
            for (var index = 0; index < controls.Length; index++)
            {
                var (columns, rows) = controls[index].EvaluationGrid;
                frames[index] = frames[index].Columns != columns || frames[index].Rows != rows
                    ? Frames.Create(columns, rows, "fonts")
                    : Frames.Update(frames[index], "fonts", index == 0 ? "cursor" : "scroll", tick);
                controls[index].SetEvaluationFrame(frames[index]);
            }
            if (tick % 120 == 0 && started.Elapsed.TotalSeconds < 80)
            {
                grid.Children.Remove(controls[1]);
                controls[1].DisposeSurface();
                controls[1] = Add(1);
                events.Add($"recreate-second-terminal:{tick}");
            }
            if (tick % 300 == 0)
            {
                var presenter = (OverlappedPresenter)window.AppWindow.Presenter;
                presenter.Minimize();
                presenter.Restore();
                window.AppWindow.ResizeClient(new Windows.Graphics.SizeInt32(1600 + tick % 7, 1100 + tick % 11));
                events.Add($"minimize-restore-resize:{tick}");
            }
            if (tick % 60 == 0)
            {
                process.Refresh();
                samples.Add(new { seconds = started.Elapsed.TotalSeconds, private_bytes = process.PrivateMemorySize64, handles = process.HandleCount });
                Save(false);
            }
            if (started.Elapsed.TotalSeconds >= 90) window.Close();
        };
        grid.Loaded += (_, _) => timer.Start();
        window.Closed += (_, _) =>
        {
            timer.Stop();
            foreach (var control in controls) control.DisposeSurface();
            Save(true);
            process.Dispose();
        };
        return window;
    }
}
#endif
