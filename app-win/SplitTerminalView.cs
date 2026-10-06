using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace TetherApp;

/// <summary>Native layout containers; resizing never creates a terminal session.</summary>
public sealed class SplitTerminalView : Grid
{
    private readonly Tab _group;
    private readonly Workspace _workspace;
    private SplitLayout? _layout;
    private bool _maximized;
    private readonly Dictionary<Guid, Border> _leaves = [];
    public SplitTerminalView(Tab group, Workspace workspace) { _group = group; _workspace = workspace; Update(); }
    public void Update()
    {
        if (_layout != _group.Layout || _maximized != _group.Maximized)
        {
            Children.Clear();
            foreach (var leaf in _leaves.Values) leaf.Child = null;
            _leaves.Clear();
            _layout = _group.Layout;
            _maximized = _group.Maximized;
            Children.Add(Build(_maximized ? SplitLayout.Leaf(_group.FocusedPane) : _layout));
        }
        foreach (var (id, border) in _leaves)
            border.BorderBrush = id == _group.FocusedPane ? new SolidColorBrush(Microsoft.UI.Colors.CornflowerBlue) : (Brush)Application.Current.Resources["ChromeWindowBrush"];
    }
    private FrameworkElement Build(SplitLayout node)
    {
        if (node.Pane is { } id)
        {
            var pane = _group.Panes.First(p => p.Id == id);
            var border = new Border { BorderThickness = new Thickness(1), Child = pane.Surface };
            _leaves[id] = border;
            return border;
        }
        var grid = new Grid();
        var first = Build(node.First!);
        var second = Build(node.Second!);
        var ratio = Math.Clamp(node.Ratio, .0001, .9999);
        var thumb = new Thumb { Background = (Brush)Application.Current.Resources["ChromeWindowBrush"] };
        double current = ratio;
        if (node.Vertical)
        {
            grid.RowDefinitions.Add(new() { Height = new GridLength(ratio, GridUnitType.Star) });
            grid.RowDefinitions.Add(new() { Height = new GridLength(5) });
            grid.RowDefinitions.Add(new() { Height = new GridLength(1 - ratio, GridUnitType.Star) });
            Grid.SetRow(thumb, 1); Grid.SetRow(second, 2);
        }
        else
        {
            grid.ColumnDefinitions.Add(new() { Width = new GridLength(ratio, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new() { Width = new GridLength(5) });
            grid.ColumnDefinitions.Add(new() { Width = new GridLength(1 - ratio, GridUnitType.Star) });
            Grid.SetColumn(thumb, 1); Grid.SetColumn(second, 2);
        }
        thumb.DragDelta += (_, e) =>
        {
            var extent = (node.Vertical ? grid.ActualHeight : grid.ActualWidth) - 5;
            if (extent <= 0) return;
            var minimum = Math.Min(.5, (node.Vertical ? 100 : 160) / extent);
            current = Math.Clamp(current + (node.Vertical ? e.VerticalChange : e.HorizontalChange) / extent, minimum, 1 - minimum);
            if (node.Vertical)
            {
                grid.RowDefinitions[0].Height = new GridLength(current, GridUnitType.Star);
                grid.RowDefinitions[2].Height = new GridLength(1 - current, GridUnitType.Star);
            }
            else
            {
                grid.ColumnDefinitions[0].Width = new GridLength(current, GridUnitType.Star);
                grid.ColumnDefinitions[2].Width = new GridLength(1 - current, GridUnitType.Star);
            }
        };
        thumb.DragCompleted += (_, _) =>
        {
            _group.Layout = Replace(_group.Layout, node, node with { Ratio = current });
            _layout = _group.Layout;
            _workspace.Persist();
        };
        grid.Children.Add(first); grid.Children.Add(thumb); grid.Children.Add(second);
        return grid;
    }
    private static SplitLayout Replace(SplitLayout root, SplitLayout old, SplitLayout replacement) =>
        root.Leaves.SequenceEqual(old.Leaves) ? replacement : root.Pane is not null ? root :
        root with { First = Replace(root.First!, old, replacement), Second = Replace(root.Second!, old, replacement) };
}
