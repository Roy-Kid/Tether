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
    private readonly Dictionary<Guid, Border> _leaves = [];
    private readonly Brush _clear = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    public SplitTerminalView(Tab group, Workspace workspace) { _group = group; _workspace = workspace; Update(); }
    public void Update()
    {
        var effective = _group.Maximized ? SplitLayout.Leaf(_group.FocusedPane) : _group.Layout;
        if (_layout != effective)
        {
            Children.Clear();
            foreach (var leaf in _leaves.Values) leaf.Child = null;
            _leaves.Clear();
            _layout = effective;
            Children.Add(Build(effective));
        }
        foreach (var (id, border) in _leaves)
        {
            var brush = id == _group.FocusedPane ? (Brush)Application.Current.Resources["AccentBrush"] : _clear;
            if (!ReferenceEquals(border.BorderBrush, brush)) border.BorderBrush = brush;
        }
    }
    private FrameworkElement Build(SplitLayout node)
    {
        if (node.Pane is { } id)
        {
            var pane = _group.Panes.First(p => p.Id == id);
            var border = new Border { BorderThickness = new Thickness(0, _group.Panes.Count > 1 && !_group.Maximized ? 2 : 0, 0, 0), Child = pane.Surface };
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
            var minimumFirst = node.Vertical ? node.First!.MinimumSize.Height : node.First!.MinimumSize.Width;
            var minimumSecond = node.Vertical ? node.Second!.MinimumSize.Height : node.Second!.MinimumSize.Width;
            if (extent < minimumFirst + minimumSecond) return;
            current = Math.Clamp(current + (node.Vertical ? e.VerticalChange : e.HorizontalChange) / extent, minimumFirst / extent, 1 - minimumSecond / extent);
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
            _group.Layout = _group.Layout.WithRatio(node.Leaves, current);
            _layout = _group.Layout;
            _workspace.Persist();
        };
        grid.Children.Add(first); grid.Children.Add(thumb); grid.Children.Add(second);
        return grid;
    }
}
