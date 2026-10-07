using System.Drawing;
using System.Windows.Forms;

namespace TetherApp;

/// <summary>
/// Notification-area icon on its own message loop. Closing the window hides
/// Tether; this is how it comes back. Quit is the path that ends sessions.
/// </summary>
sealed class TrayHost : IDisposable
{
    private readonly Thread _thread;
    private readonly ManualResetEvent _ready = new(false);
    private NotifyIcon? _icon;
    private Form? _pump;
    private ApplicationContext? _context;

    public TrayHost(Action show, Action quit)
    {
        _thread = new Thread(() =>
        {
            _context = new ApplicationContext();
            _pump = new Form { ShowInTaskbar = false };
            _pump.CreateControl();
            var menu = new ContextMenuStrip();
            menu.Items.Add("Show Tether", null, (_, _) => show());
            menu.Items.Add("Quit Tether", null, (_, _) => quit());
            var icon = SystemIcons.Application;
            if (Environment.ProcessPath is { } path) icon = Icon.ExtractAssociatedIcon(path) ?? icon;
            _icon = new NotifyIcon
            {
                Icon = icon,
                Text = "Tether",
                Visible = true,
                ContextMenuStrip = menu,
            };
            _icon.MouseClick += (_, args) =>
            {
                if (args.Button == MouseButtons.Left) show();
            };
            _ready.Set();
            Application.Run(_context);
        });
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.IsBackground = true;
        _thread.Start();
        _ready.WaitOne();
    }

    public void Dispose()
    {
        var pump = _pump;
        var icon = _icon;
        _pump = null;
        _icon = null;
        if (pump is null) return;
        pump.BeginInvoke(new Action(() =>
        {
            if (icon is not null)
            {
                icon.Visible = false;
                icon.Dispose();
            }
            _context?.ExitThread();
        }));
    }
}
