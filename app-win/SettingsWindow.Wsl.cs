using Microsoft.UI.Xaml.Controls;

namespace TetherApp;

public sealed partial class SettingsWindow
{
    private async void BuildWslPicker()
    {
        WslPicker.Items.Add(new ComboBoxItem { Content = "System default", Tag = "" });
        var selected = AppSettings.Current.WslDistribution;
        try
        {
            foreach (var distro in await WslSession.DistributionsAsync()) WslPicker.Items.Add(new ComboBoxItem { Content = distro, Tag = distro });
        }
        catch { /* Other shell profiles remain available when WSL is not installed. */ }
        if (selected is not null && !WslPicker.Items.Cast<ComboBoxItem>().Any(i => (string)i.Tag == selected))
            WslPicker.Items.Add(new ComboBoxItem { Content = selected, Tag = selected });
        WslPicker.SelectedItem = WslPicker.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == (selected ?? "")) ?? WslPicker.Items[0];
        WslPicker.SelectionChanged += (_, _) =>
        {
            if (WslPicker.SelectedItem is ComboBoxItem { Tag: string name })
                ShowSaveResult((AppSettings.Current with { WslDistribution = name.Length == 0 ? null : name }).Save());
        };
    }
}
