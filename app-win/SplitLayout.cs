namespace TetherApp;

/// <summary>App-owned layout. Leaves reference independent terminal sessions.</summary>
public sealed record SplitLayout(Guid? Pane, bool Vertical = false, double Ratio = .5,
    SplitLayout? First = null, SplitLayout? Second = null)
{
    public static SplitLayout Leaf(Guid id) => new(id);
    public IEnumerable<Guid> Leaves => Pane is { } id ? [id] : First!.Leaves.Concat(Second!.Leaves);
    /// <summary><paramref name="before"/> puts the new pane on the left or the top.</summary>
    public SplitLayout Split(Guid id, Guid added, bool vertical, bool before = false) => Pane == id
        ? before ? new(null, vertical, .5, Leaf(added), this) : new(null, vertical, .5, this, Leaf(added))
        : Pane is not null ? this : this with
        {
            First = First!.Split(id, added, vertical, before),
            Second = Second!.Split(id, added, vertical, before),
        };

    /// <summary>Move <paramref name="dragged"/> onto one edge of <paramref name="target"/>.</summary>
    public static SplitLayout PlaceInLayout(SplitLayout layout, Guid dragged, Guid target, SplitEdge edge)
    {
        if (dragged == target) return layout;
        var remaining = layout.Remove(dragged) ?? Leaf(target);
        if (!remaining.Leaves.Contains(target)) remaining = Leaf(target);
        return InsertBeside(remaining, target, dragged, edge);
    }

    public static SplitLayout InsertBeside(SplitLayout layout, Guid target, Guid added, SplitEdge edge)
    {
        var rooted = layout.Leaves.Contains(target) ? layout : Leaf(target);
        var before = edge is SplitEdge.Left or SplitEdge.Up;
        var vertical = edge is SplitEdge.Up or SplitEdge.Down;
        var panes = before
            ? new SplitLayout(null, vertical, .5, Leaf(added), Leaf(target))
            : new SplitLayout(null, vertical, .5, Leaf(target), Leaf(added));
        return Replace(rooted, target, panes);
    }

    public static SplitLayout Replace(SplitLayout layout, Guid id, SplitLayout replacement) =>
        layout.Pane == id ? replacement : layout.Pane is not null ? layout
        : layout with { First = Replace(layout.First!, id, replacement), Second = Replace(layout.Second!, id, replacement) };
    public SplitLayout RestoreBeside(IReadOnlySet<Guid> neighbors, Guid pane, bool vertical, bool before, double ratio)
    {
        if (Pane is null)
        {
            if (neighbors.All(First!.Leaves.Contains)) return this with { First = First.RestoreBeside(neighbors, pane, vertical, before, ratio) };
            if (neighbors.All(Second!.Leaves.Contains)) return this with { Second = Second.RestoreBeside(neighbors, pane, vertical, before, ratio) };
        }
        ratio = double.IsFinite(ratio) ? Math.Clamp(ratio, .0001, .9999) : .5;
        return before ? new(null, vertical, ratio, Leaf(pane), this) : new(null, vertical, ratio, this, Leaf(pane));
    }
    public (double Width, double Height) MinimumSize => Pane is not null ? (160, 100) : Vertical
        ? (Math.Max(First!.MinimumSize.Width, Second!.MinimumSize.Width), First.MinimumSize.Height + 5 + Second.MinimumSize.Height)
        : (First!.MinimumSize.Width + 5 + Second!.MinimumSize.Width, Math.Max(First.MinimumSize.Height, Second.MinimumSize.Height));
    public bool IsValid(IReadOnlySet<Guid> panes) => Validate(panes, new HashSet<Guid>()) && Leaves.Count() == panes.Count;
    public bool IsValidSubset(IReadOnlySet<Guid> panes) => Validate(panes, new HashSet<Guid>());
    private bool Validate(IReadOnlySet<Guid> panes, HashSet<Guid> seen) => Pane is { } id
        ? First is null && Second is null && panes.Contains(id) && seen.Add(id)
        : First is not null && Second is not null && double.IsFinite(Ratio) && Ratio > 0 && Ratio < 1 &&
          First.Validate(panes, seen) && Second.Validate(panes, seen);
    public SplitLayout WithRatio(IEnumerable<Guid> branch, double ratio)
    {
        if (Pane is not null) return this;
        if (Leaves.SequenceEqual(branch)) return this with { Ratio = Math.Clamp(ratio, .0001, .9999) };
        return this with { First = First!.WithRatio(branch, ratio), Second = Second!.WithRatio(branch, ratio) };
    }
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

public enum SplitEdge { Left, Right, Up, Down }

/// <summary>Which side of a chip or a pane a drop landed on. Same rule as the Mac tab strip.</summary>
public static class SplitEdges
{
    public static SplitEdge? Drop(double x, double y, double width, double height, double? band)
    {
        if (width <= 0 || height <= 0 || !double.IsFinite(x) || !double.IsFinite(y)) return null;
        if (band is { } limit)
        {
            var left = x / width;
            var right = 1 - left;
            var top = y / height;
            var bottom = 1 - top;
            (SplitEdge Edge, double Distance) nearest = (SplitEdge.Left, left);
            foreach (var candidate in new[] { (SplitEdge.Right, right), (SplitEdge.Up, top), (SplitEdge.Down, bottom) })
                if (candidate.Item2 < nearest.Distance) nearest = candidate;
            return nearest.Distance <= limit ? nearest.Edge : null;
        }
        if (height > width) return y < height / 2 ? SplitEdge.Up : SplitEdge.Down;
        return x < width / 2 ? SplitEdge.Left : SplitEdge.Right;
    }

    /// <summary>An edge band wins. The middle of a wide chip is left or right; a tall chip is up or down.</summary>
    public static SplitEdge DropOnChip(double x, double y, double width, double height) =>
        Drop(x, y, width, height, 0.28) ?? Drop(x, y, width, height, null) ?? SplitEdge.Right;
}
