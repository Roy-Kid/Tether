// Settings, as two panes rather than a row of tabs.
//
// A tab strip puts every section on screen at once and then hides all but
// one, which stops scaling the moment a third section exists. A sidebar is
// the same shape as the rest of the app, so the window a person already
// knows how to read does not change its rules when they open preferences.
//
// The Mac's `AppSettings` is `NavigationSplitView` with General /
// Appearance / Security / Extensions. This is the same two columns: the
// sidebar lists the sections a Windows host has something to put in.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tether;

namespace TetherApp;

public sealed partial class SettingsWindow : Window
{
    private sealed record Section(string Title, string Glyph, Action<StackPanel> Build);

    private readonly IReadOnlyList<Section> _sections;

    public SettingsWindow()
    {
        InitializeComponent();

        _sections = new List<Section>
        {
            new("General", "", BuildGeneral),
            new("Appearance", "", BuildAppearance),
        };
        // Sections a platform has nothing to put in are not shown empty.
        SectionList.ItemsSource = _sections.Select(s => s.Title)
            .Select((title, i) => new { Title = title, Glyph = _sections[i].Glyph })
            .ToList();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(null);

        Activate();
        ShowPane(0);
    }

    private void Section_Click(object sender, ItemClickEventArgs e)
    {
        var index = SectionList.Items.IndexOf(e.ClickedItem);
        if (index >= 0) ShowPane(index);
    }

    private void ShowPane(int index)
    {
        Pane.Children.Clear();
        if (index >= 0 && index < _sections.Count) _sections[index].Build(Pane);
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();

    /// <summary>
    /// What the app does on its own, before anyone has asked for anything.
    /// `GeneralSettings` on the Mac — and the shell a local terminal opens,
    /// which is this machine's question and no other's.
    /// </summary>
    private static void BuildGeneral(StackPanel pane)
    {
        pane.Children.Add(Heading("General"));
        pane.Children.Add(Group("At launch", contents =>
        {
            var open = new CheckBox
            {
                Content = "Open a terminal at launch",
                IsChecked = AppSettings.Current.OpenLocalOnStart,
            };
            open.Checked += (_, _) => Save(shell: null, open: true);
            open.Unchecked += (_, _) => Save(shell: null, open: false);
            contents.Children.Add(open);
        }));

        pane.Children.Add(Group("Shell", contents =>
        {
            var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
            var selected = 0;
            for (var i = 0; i < AppSettings.KnownShells.Count; i++)
            {
                var (program, name) = AppSettings.KnownShells[i];
                combo.Items.Add(name);
                if (program == AppSettings.Current.Shell) selected = i;
            }
            combo.SelectedIndex = selected;
            combo.SelectionChanged += (_, _) =>
            {
                var i = combo.SelectedIndex;
                if (i < 0 || i >= AppSettings.KnownShells.Count) return;
                Save(shell: AppSettings.KnownShells[i].Program, open: null);
            };
            contents.Children.Add(combo);
        }));
    }

    /// <summary>
    /// How the window and the terminal look. `AppearanceSettings` on the
    /// Mac: the window follows the system unless told otherwise, and the
    /// terminal is its own question because a terminal is a palette.
    /// </summary>
    private static void BuildAppearance(StackPanel pane)
    {
        pane.Children.Add(Heading("Appearance"));
        pane.Children.Add(Group("Appearance", contents =>
        {
            contents.Children.Add(Caption("Terminal"));
            // The terminal is the palette's (Decision 0011). Until a theme
            // picker lands, dark is what Palette.dark is and what every
            // other terminal on this machine opens with.
            var dark = new RadioButton { Content = "Dark", IsChecked = true, GroupName = "TerminalTheme" };
            var light = new RadioButton { Content = "Light", GroupName = "TerminalTheme" };
            contents.Children.Add(dark);
            contents.Children.Add(light);
        }));
    }

    private static void Save(string? shell, bool? open)
    {
        var current = AppSettings.Current;
        var next = current with
        {
            Shell = shell ?? current.Shell,
            OpenLocalOnStart = open ?? current.OpenLocalOnStart,
        };
        next.Save();
    }

    private static UIElement Heading(string text) => new TextBlock
    {
        Text = text,
        FontSize = 20,
        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
    };

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Opacity = 0.7,
    };

    /// <summary>A titled group, the Windows shape of a `Form` section.</summary>
    private static UIElement Group(string title, Action<StackPanel> build)
    {
        var body = new StackPanel { Spacing = 8 };
        build(body);
        return new Border
        {
            Background = (SolidColorBrush)Application.Current.Resources["ChromeSidebarBrush"],
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(16),
            Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new TextBlock { Text = title, FontSize = 12, Opacity = 0.7 },
                    body,
                },
            },
        };
    }
}
