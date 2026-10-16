using System.Net.NetworkInformation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tether;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TetherApp.Plugins;

public sealed class PortsPlugin : ITabPlugin
{
    public PluginMetadata Metadata { get; } = new("dev.tether.ports", "Ports", "\uE968", "Discover and forward development servers through the current connection.");
    public TabAccessory Accessory { get; } = new("\uE968", "Ports", AccessoryPlacement.Inspector);
    public IReadOnlyList<PluginCommandDescriptor> CommandDescriptors => [new("refresh", "Refresh Ports")];
    public void Activate() { }
    public void Deactivate() { }
    public ITabAttachment Attach(TabContext tab) => new PortsAttachment(tab);
}

internal sealed class PortsAttachment : ITabAttachment
{
    private readonly TabContext _tab;
    private readonly StackPanel _panel = new() { Padding = new Thickness(12), Spacing = 8 };
    private readonly StackPanel _rows = new() { Spacing = 4 };
    private readonly TextBlock _problem = new() { TextWrapping = TextWrapping.Wrap };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(3) };
    private readonly Dictionary<ushort, ForwardedPort> _forwards = [];
    private readonly HashSet<ushort> _stopped = [];
    private CancellationTokenSource _scan = new();
    private Task _operation = Task.CompletedTask;
    private Task _resetTask = Task.CompletedTask;
    private bool _busy, _disposed, _resetting;
    private int _generation;
    private IReadOnlyList<HeardPort> _ports = [];

    public PortsAttachment(TabContext tab)
    {
        _tab = tab; _generation = tab.Model.Generation;
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        tools.Children.Add(EditorDialog.Icon("\uE72C", "Refresh Ports", () => _ = RefreshAsync()));
        var automatic = new ToggleSwitch { Header = "Automatic", IsOn = AppSettings.Current.PortsAutomatic };
        automatic.Toggled += (_, _) =>
        {
            (AppSettings.Current with { PortsAutomatic = automatic.IsOn }).Save();
            _ = RefreshAsync();
        };
        var ignored = new TextBox { Header = "Ignore", Text = AppSettings.Current.PortsIgnored, PlaceholderText = "3000, 8080" };
        ignored.LostFocus += (_, _) => { (AppSettings.Current with { PortsIgnored = ignored.Text }).Save(); _ = RefreshAsync(); };
        _panel.Children.Add(tools); _panel.Children.Add(automatic); _panel.Children.Add(ignored);
        _panel.Children.Add(new ScrollViewer { Content = _rows, MaxHeight = 400 }); _panel.Children.Add(_problem);
        _timer.Tick += Tick; _timer.Start();
        _tab.Model.SessionChanged += SessionChanged;
    }

    public UIElement View => _panel;
    public string? CloseNote => _forwards.Values.Any(f => !f.AlreadyLocal) ? "Forwarded ports close." : null;
    public IReadOnlyList<PluginCommand> Commands => [new("refresh", "Refresh Ports", RefreshAsync)];
    public Task ShownAsync() => RefreshAsync();
    public bool Receive(IReadOnlyList<string> paths) => false;
    public LinkActions? ActionsFor(TerminalLink link) => null;
    private async void Tick(object? sender, object e) => await RefreshAsync();
    private void SessionChanged() => _panel.DispatcherQueue.TryEnqueue(() =>
    {
        if (_disposed || _resetting || (_generation == _tab.Model.Generation && _tab.Model.IsLive)) return;
        _resetTask = ResetSessionAsync();
    });
    private async Task ResetSessionAsync()
    {
        _resetting = true;
        try
        {
            _scan.Cancel(); await _operation;
            if (_disposed) return;
            if (_generation == _tab.Model.Generation)
                foreach (var port in _forwards.Keys) await _tab.Model.StopForwardAsync(port);
            _forwards.Clear(); _ports = []; _stopped.Clear(); Render();
            _generation = _tab.Model.Generation;
        }
        finally { _resetting = false; }
    }

    private Task RunAsync(Func<CancellationToken, Task> action)
    {
        if (_disposed || _busy || _resetting) return _operation;
        _busy = true;
        _operation = RunCoreAsync(action);
        return _operation;
    }
    private async Task RunCoreAsync(Func<CancellationToken, Task> action)
    {
        var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var previous = _scan; _scan = cancellation; previous.Dispose();
        try { _problem.Text = ""; await action(cancellation.Token); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _problem.Text = ex.Message; }
        finally { _busy = false; }
    }
    private Task RefreshAsync() => RunAsync(async token =>
    {
        if (!_tab.Model.IsLive) return;
        var generation = _tab.Model.Generation;
        IReadOnlyList<HeardPort> heard;
        if (_tab.Model.IsRemote || _tab.Model.IsWsl)
            heard = PortScan.Parse(await _tab.Model.ExecuteAsync(PortScan.Command, token));
        else
            heard = (await Task.Run(() => IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners(), token))
                .Where(p => p.Port >= 1024).Select(p => (ushort)p.Port).Distinct().Order().Take(PortScan.Limit)
                .Select(p => new HeardPort(p, "?")).ToArray();
        token.ThrowIfCancellationRequested();
        if (_disposed || generation != _tab.Model.Generation) return;
        _generation = generation;
        var ignored = PortScan.Ignored(AppSettings.Current.PortsIgnored);
        _ports = heard.Where(p => !ignored.Contains(p.Port)).ToArray();
        var current = _ports.Select(p => p.Port).ToHashSet();
        foreach (var port in _forwards.Keys.Where(p => !current.Contains(p)).ToArray())
        { await _tab.Model.StopForwardAsync(port); _forwards.Remove(port); }
        _stopped.IntersectWith(current);
        if (AppSettings.Current.PortsAutomatic && _tab.Model.IsRemote)
            foreach (var port in _ports.Where(p => !_stopped.Contains(p.Port)))
                if (!_forwards.ContainsKey(port.Port))
                {
                    if (_forwards.Count >= 20) break;
                    try { _forwards[port.Port] = await _tab.Model.ForwardPortAsync(port.Port, token); }
                    catch (Exception ex) when (ex is IOException or TetherException) { _problem.Text = ex.Message; }
                    token.ThrowIfCancellationRequested();
                }
        Render();
    });

    private void Render()
    {
        if (_disposed) return;
        _rows.Children.Clear();
        foreach (var port in _ports)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            _forwards.TryGetValue(port.Port, out var forwarded);
            // Windows owns WSL's localhost relay. Show its address without
            // creating a listener over it or claiming to stop that relay.
            if (!_tab.Model.IsRemote) forwarded = new(port.Port, true);
            row.Children.Add(new TextBlock { Text = $"{port.Port}  {port.Name}" + (_tab.Model.IsWsl ? " · WSL" : !_tab.Model.IsRemote || forwarded is null ? "" : $" → {forwarded.LocalPort}"), VerticalAlignment = VerticalAlignment.Center });
            if (forwarded is not null)
            {
                var url = $"http://127.0.0.1:{forwarded.LocalPort}";
                row.Children.Add(EditorDialog.Icon("\uE8A7", "Open in Browser", () => _ = RunAsync(async _ => { await Launcher.LaunchUriAsync(new Uri(url)); })));
                row.Children.Add(EditorDialog.Icon("\uE8C8", "Copy Address", () => { var data = new DataPackage(); data.SetText(url); Clipboard.SetContent(data); }));
                if (!forwarded.AlreadyLocal)
                    row.Children.Add(EditorDialog.Icon("\uE71A", "Stop Forward", () => _ = RunAsync(async _ =>
                    { await _tab.Model.StopForwardAsync(port.Port); _forwards.Remove(port.Port); _stopped.Add(port.Port); Render(); })));
            }
            else row.Children.Add(EditorDialog.Icon("\uE72A", "Forward Port", () => _ = RunAsync(async token =>
            { _forwards[port.Port] = await _tab.Model.ForwardPortAsync(port.Port, token); _stopped.Remove(port.Port); Render(); })));
            _rows.Children.Add(row);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true; _timer.Stop(); _timer.Tick -= Tick; _tab.Model.SessionChanged -= SessionChanged;
        _scan.Cancel(); await _resetTask; await _operation;
        if (_generation == _tab.Model.Generation)
            foreach (var port in _forwards.Keys) await _tab.Model.StopForwardAsync(port);
        _forwards.Clear(); _scan.Dispose();
    }
}
