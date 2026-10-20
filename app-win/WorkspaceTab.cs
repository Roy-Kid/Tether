namespace TetherApp;

/// <summary>A named workspace. Session ownership belongs to its panes.</summary>
public sealed class Tab
{
    public Guid Id { get; }
    public string Title { get; set; }
    public SplitLayout Layout { get; set; }
    public List<TerminalPane> Panes { get; } = [];
    public Guid FocusedPane { get; set; }
    public bool Maximized { get; set; }
    public HostEntry? Host { get; set; }
    public TerminalPane Focused => Panes.FirstOrDefault(p => p.Id == FocusedPane) ?? Panes[0];
    public Tab(TerminalPane pane, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Title = pane.Title;
        Panes.Add(pane);
        Layout = SplitLayout.Leaf(pane.Id);
        FocusedPane = pane.Id;
        Host = pane.Model.RemoteHost;
    }
}
