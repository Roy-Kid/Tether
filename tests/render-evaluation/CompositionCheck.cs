using Tether;

/// <summary>Manual, shell-free native compositor fixture; never a CI performance gate.</summary>
internal static class CompositionCheck
{
    [STAThread]
    internal static int Run()
    {
        Environment.SetEnvironmentVariable("WGPU_BACKEND", "dx12");
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        using var window = new Form { Text = "Glass composition fixture (no shell)", ClientSize = new(990, 330), StartPosition = FormStartPosition.CenterScreen };
        window.Paint += (_, e) =>
        {
            using var blue = new SolidBrush(Color.FromArgb(80, 160, 220));
            using var coral = new SolidBrush(Color.FromArgb(230, 150, 100));
            e.Graphics.FillRectangle(blue, 0, 0, window.ClientSize.Width, 180);
            e.Graphics.FillRectangle(coral, 0, 180, window.ClientSize.Width, 150);
        };
        var surfaces = new List<TerminalSurface>();
        var panels = new List<CompositionPanel>();
        var close = false;
        window.FormClosing += (_, e) => e.Cancel = !close;
        window.Show();
        Application.DoEvents();
        try
        {
            SynchronizationContext.SetSynchronizationContext(null);
            foreach (var (alpha, index) in new[] { (0f, 0), (.35f, 1), (1f, 2) })
            {
                var panel = new CompositionPanel { Bounds = new Rectangle(10 + index * 330, 40, 310, 270) };
                panels.Add(panel);
                window.Controls.Add(panel);
                window.Controls.Add(new Label { Text = $"Background opacity: {alpha:P0}", Bounds = new Rectangle(10 + index * 330, 8, 310, 26), BackColor = Color.White });
                var surface = TerminalSurface.FromHwndAsync(panel.Handle, 310, 270).GetAwaiter().GetResult();
                surfaces.Add(surface);
                surface.SetFonts("Consolas", "Microsoft YaHei UI");
                surface.Measure(14);
                var frame = Frames.Create(30, 12, "fonts");
                var palette = Palette.Dark with { Background = Palette.Dark.Background with { Alpha = alpha } };
                if (!surface.Draw(frame, palette)) throw new InvalidOperationException("First composition draw was skipped");
                Console.WriteLine($"Rendered DX12 DirectComposition surface: background alpha={alpha}");
            }
            Console.WriteLine("Inspect: first column reveals blue/coral; middle column tints it once; last column is opaque. Glyphs stay opaque. Closes after 30 seconds.");
            var until = DateTime.UtcNow.AddSeconds(30);
            while (DateTime.UtcNow < until) { Application.DoEvents(); Thread.Sleep(16); }
        }
        finally
        {
            foreach (var surface in surfaces) surface.Dispose();
            foreach (var panel in panels) panel.Dispose();
            close = true;
            window.Close();
        }
        Console.WriteLine("PASS: three native composition surfaces created, rendered and disposed");
        return 0;
    }

    private sealed class CompositionPanel : Panel
    {
        protected override CreateParams CreateParams
        {
            get { var value = base.CreateParams; value.ExStyle |= 0x00200000; return value; }
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }
    }
}
