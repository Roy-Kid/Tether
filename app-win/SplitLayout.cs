namespace TetherApp;

/// <summary>App-owned layout. Leaves reference independent terminal sessions.</summary>
public sealed record SplitLayout(Guid? Pane, bool Vertical = false, double Ratio = .5,
    SplitLayout? First = null, SplitLayout? Second = null)
{
    public static SplitLayout Leaf(Guid id) => new(id);
    public IEnumerable<Guid> Leaves => Pane is { } id ? [id] : First!.Leaves.Concat(Second!.Leaves);
    public SplitLayout Split(Guid id, Guid added, bool vertical) => Pane == id
        ? new(null, vertical, .5, this, Leaf(added))
        : Pane is not null ? this : this with { First = First!.Split(id, added, vertical), Second = Second!.Split(id, added, vertical) };
    public bool IsValid(IReadOnlySet<Guid> panes) => Validate(panes, new HashSet<Guid>()) && Leaves.Count() == panes.Count;
    private bool Validate(IReadOnlySet<Guid> panes, HashSet<Guid> seen) => Pane is { } id
        ? First is null && Second is null && panes.Contains(id) && seen.Add(id)
        : First is not null && Second is not null && double.IsFinite(Ratio) && Ratio > 0 && Ratio < 1 &&
          First.Validate(panes, seen) && Second.Validate(panes, seen);
    public SplitLayout ReplacePane(Guid id, Guid replacement) => Pane == id ? Leaf(replacement) : Pane is not null ? this :
        this with { First = First!.ReplacePane(id, replacement), Second = Second!.ReplacePane(id, replacement) };
    public SplitLayout? Remove(Guid id)
    {
        if (Pane is not null) return Pane == id ? null : this;
        var a = First!.Remove(id);
        var b = Second!.Remove(id);
        return a is null ? b : b is null ? a : this with { First = a, Second = b };
    }
}
