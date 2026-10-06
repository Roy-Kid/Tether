using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

using Tether;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using FileAttributes = System.IO.FileAttributes;

namespace TetherApp.Files;

public sealed partial class FilesPane : UserControl, IAsyncDisposable
{
    private readonly SessionModel _model;
    private IFileSource? _source;
    private CancellationTokenSource? _cancellation;
    private Task _operation = Task.CompletedTask;
    private readonly Stack<string> _back = new();
    private readonly Stack<string> _forward = new();
    private IReadOnlyList<FileEntry> _entries = [];
    private readonly Dictionary<string, IReadOnlyList<FileEntry>> _children = new();
    private readonly HashSet<string> _expanded = new();
    private string? _directory;
    private bool _busy, _disposed, _resetting;
    private Window? _dialog;
    public nint WindowHandle { get; set; }
    /// <summary>Dialogs need a root even before this pane is on screen.</summary>
    public Func<XamlRoot?>? DialogRoot { get; set; }
    public bool HasWork => _busy;
    public event Action? HideRequested;

    public FilesPane(SessionModel model)
    {
        InitializeComponent();
        _model = model;
        _model.SessionChanged += SessionChanged;
        PreviewKeyDown += Browse_KeyDown;
    }
    public Task ShowAsync() => RunAsync(async token =>
    {
        await EnsureSourceAsync(token);
        if (_directory is null) await NavigateAsync(await InitialDirectoryAsync(), false, token);
    });
    private async Task EnsureSourceAsync(CancellationToken token)
    {
        _source ??= _model.IsRemote
            ? new SftpSource(await _model.OpenFilesAsync(token))
            : await LocalFileSource.CreateAsync(IsWsl, token, _model.WslDistribution);
    }
    private bool IsWsl => _model.IsWsl;
    private async Task<string> InitialDirectoryAsync()
    {
        var path = _model.WorkingDirectory;
        if (path is null) return await _source!.HomeAsync();
        if (Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile) path = uri.LocalPath;
        return _source is LocalFileSource local ? local.NativePath(path) : path;
    }
    private void SessionChanged()
    {
        if (!DispatcherQueue.HasThreadAccess) { DispatcherQueue.TryEnqueue(SessionChanged); return; }
        _ = ResetSessionAsync();
    }
    private async Task ResetSessionAsync()
    {
        if (_disposed) return;
        _resetting = true;
        _cancellation?.Cancel(); _dialog?.Close();
        await _operation;
        if (_source is { } previous)
        {
            _source = null;
            try { await previous.DisposeAsync(); } catch (Exception ex) { Problem.Text = ex.Message; }
        }
        _directory = null; _entries = []; _back.Clear(); _forward.Clear(); RenderEntries();
        _resetting = false;
        if (!_disposed && IsLoaded) await ShowAsync();
    }
    private Task RunAsync(Func<CancellationToken, Task> action)
    {
        if (_disposed) return Task.CompletedTask;
        // One at a time, in the order they were asked. A drop that arrives
        // while the browser is still opening has to wait for that, not vanish.
        var run = RunAfter(_operation, action);
        _operation = run;
        return run;
    }

    private async Task RunAfter(Task previous, Func<CancellationToken, Task> action)
    {
        try { await previous; } catch (Exception) { /* the next request still runs */ }
        if (_disposed || _resetting) return;
        await ExecuteAsync(action);
    }
    private async Task ExecuteAsync(Func<CancellationToken, Task> action)
    {
        using var cancellation = new CancellationTokenSource();
        _cancellation = cancellation; _busy = true;
        Problem.Text = ""; Activity.Text = "Working…";
        ProgressBar.Visibility = CancelButton.Visibility = Visibility.Visible;
        ProgressBar.IsIndeterminate = true;
        try { await EnsureSourceAsync(cancellation.Token); await action(cancellation.Token); Activity.Text = ""; }
        catch (OperationCanceledException) { Activity.Text = "Cancelled. Completed changes are kept."; }
        catch (Exception ex) { Problem.Text = ex.Message; Activity.Text = ""; }
        finally
        {
            ProgressBar.Visibility = CancelButton.Visibility = Visibility.Collapsed;
            _cancellation = null; _busy = false;
        }
    }
    private async Task NavigateAsync(string path, bool remember, CancellationToken token)
    {
        var entries = await _source!.ListAsync(path, token);
        token.ThrowIfCancellationRequested();
        if (remember && _directory is not null && _directory != path)
        {
            _back.Push(_directory);
            _forward.Clear();
        }
        if (_directory != path) Filter.Text = "";
        _directory = path; _entries = entries; Address.Text = _source.ShellPath(path);
        _children.Clear(); _expanded.Clear();
        RenderEntries();
    }
    private void RenderEntries()
    {
        var selected = Selected().Select(e => e.Path).ToHashSet();
        var rows = Rows(_entries, 0).ToArray();
        Entries.ItemsSource = rows;
        foreach (var row in rows.Where(r => selected.Contains(r.Entry.Path))) Entries.SelectedItems.Add(row);
        Empty.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Empty.Text = string.IsNullOrWhiteSpace(Filter.Text) ? "This folder is empty." : "No matching names in this folder.";
        ItemCount.Text = $"{rows.Length} item(s) shown";
    }
    private IEnumerable<Row> Rows(IReadOnlyList<FileEntry> entries, int depth)
    {
        var query = Filter.Text.Trim();
        var ordered = entries.Where(e => (HiddenToggle.IsChecked || !e.Name.StartsWith('.'))
            && (query.Length == 0 || e.Name.Contains(query, StringComparison.OrdinalIgnoreCase)))
            .OrderBy(e => e.Kind == FileKind.Directory ? 0 : 1);
        ordered = ordered.ThenBy(e => e.Name, StringComparer.CurrentCultureIgnoreCase);
        foreach (var entry in ordered)
        {
            yield return new Row(entry, depth, _expanded.Contains(entry.Path));
            if (query.Length == 0 && depth < 64 && _expanded.Contains(entry.Path) && _children.TryGetValue(entry.Path, out var children))
                foreach (var child in Rows(children, depth + 1)) yield return child;
        }
    }
    private void Expand_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => e.Handled = true;
    private async void Expand_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string path }) return;
        await RunAsync(async token =>
        {
            if (!_expanded.Remove(path))
            { _children[path] = await _source!.ListAsync(path, token); _expanded.Add(path); }
            RenderEntries();
        });
    }
    private sealed record Row(FileEntry Entry, int Depth = 0, bool Expanded = false)
    {
        public Thickness Indent => new(Depth * (double)Application.Current.Resources["SpaceSection"], 0, 0, 0);
        public bool CanExpand => Entry.Kind == FileKind.Directory;
        public string ExpandGlyph => !CanExpand ? "" : Expanded ? "\uE70D" : "\uE76C";
        public string Name => string.Concat(Entry.Name.Select(c => char.IsControl(c) ? '\uFFFD' : c));
        public string Glyph => Entry.Kind switch { FileKind.Directory => "\uE8B7", FileKind.Link => "\uE71B", _ => "\uE7C3" };
        public string Size => Entry.Kind == FileKind.File ? FormatSize(Entry.Size) : "";
    }
    private static string FormatSize(ulong size) => size < 1024 ? $"{size} B" : size < 1048576 ? $"{size / 1024d:0.#} KB" : $"{size / 1048576d:0.#} MB";
    private FileEntry[] Selected() => Entries.SelectedItems.OfType<Row>().Select(r => r.Entry).ToArray();
    private Task RefreshAsync(CancellationToken token) => _directory is null ? Task.CompletedTask : NavigateAsync(_directory, false, token);
    private async void Back_Click(object sender, RoutedEventArgs e) => await RunAsync(async t =>
    { await HistoryAsync(false, t); });
    private async void Forward_Click(object sender, RoutedEventArgs e) => await RunAsync(t => HistoryAsync(true, t));
    private async Task HistoryAsync(bool forward, CancellationToken token)
    {
        var from = forward ? _forward : _back;
        var to = forward ? _back : _forward;
        if (!from.TryPeek(out var path)) return;
        var previous = _directory;
        await NavigateAsync(path, false, token);
        from.Pop();
        if (previous is not null) to.Push(previous);
    }
    private void Filter_Changed(object sender, TextChangedEventArgs e)
    {
        if (Entries is not null && ItemCount is not null) RenderEntries();
    }
    private void Filter_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape) return;
        Filter.Text = ""; Filter.Visibility = Visibility.Collapsed; Entries.Focus(FocusState.Programmatic); e.Handled = true;
    }
    private async void Browse_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var alt = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (control && e.Key is VirtualKey.F or VirtualKey.L)
        {
            e.Handled = true;
            if (e.Key == VirtualKey.F) Filter.Visibility = Visibility.Visible;
            var input = e.Key == VirtualKey.F ? Filter : Address;
            input.Focus(FocusState.Programmatic); input.SelectAll();
        }
        else if (alt && e.Key is VirtualKey.Left or VirtualKey.Right)
        {
            e.Handled = true;
            await RunAsync(t => HistoryAsync(e.Key == VirtualKey.Right, t));
        }
    }
    private async void Up_Click(object sender, RoutedEventArgs e) => await RunAsync(t => _directory is null ? Task.CompletedTask : NavigateAsync(_source!.Parent(_directory), true, t));
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RunAsync(RefreshAsync);
    private async void Home_Click(object sender, RoutedEventArgs e) => await RunAsync(async t => await NavigateAsync(await _source!.HomeAsync(), true, t));
    private async void TerminalDirectory_Click(object sender, RoutedEventArgs e) => await RunAsync(async t => await NavigateAsync(await InitialDirectoryAsync(), true, t));
    private void Hidden_Click(object sender, RoutedEventArgs e) => RenderEntries();
    private void Close_Click(object sender, RoutedEventArgs e) => HideRequested?.Invoke();
    private void Cancel_Click(object sender, RoutedEventArgs e) { _cancellation?.Cancel(); _dialog?.Close(); }
    private async void Address_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        var path = Address.Text;
        await RunAsync(t => NavigateAsync(_source is LocalFileSource local ? local.NativePath(path) : path, true, t));
    }
    private async void Entries_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    { e.Handled = true; await OpenSelectedAsync(); }
    private async void Open_Click(object sender, RoutedEventArgs e) => await OpenSelectedAsync();
    private async Task OpenSelectedAsync()
    {
        if (Selected() is not [var entry]) return;
        await RunAsync(async t =>
        {
            var target = entry.Kind == FileKind.Link ? await _source!.StatAsync(entry.Path) : entry;
            if (target.Kind == FileKind.Directory) await NavigateAsync(entry.Path, true, t);
            else if (target.Kind == FileKind.File) await OpenFileAsync(entry, t);
        });
    }
    private void Entries_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        for (DependencyObject? node = e.OriginalSource as DependencyObject; node is not null && node != Entries; node = VisualTreeHelper.GetParent(node))
            if (node is FrameworkElement { DataContext: Row row })
            { if (!Entries.SelectedItems.Contains(row)) { Entries.SelectedItems.Clear(); Entries.SelectedItems.Add(row); } break; }
    }
    private async void Entries_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter: e.Handled = true; await OpenSelectedAsync(); break;
            case VirtualKey.F2: e.Handled = true; await RenameAsync(); break;
            case VirtualKey.Delete: e.Handled = true; await DeleteAsync(); break;
            case VirtualKey.Space: e.Handled = true; await PreviewSelectedAsync(); break;
            case VirtualKey.F5: e.Handled = true; await RunAsync(RefreshAsync); break;
        }
    }
    private async Task<ContentDialogResult> DialogAsync(string title, object content, string primary, string? secondary = null)
    {
        _cancellation?.Token.ThrowIfCancellationRequested();
        return await Alerts.ContentAsync(title, content, primary, secondary, ActualTheme,
            window => _dialog = window);
    }
    private async Task<string?> AskNameAsync(string title, string initial)
    {
        var input = new TextBox { Text = initial, MinWidth = 260 };
        input.Loaded += (_, _) => { input.Focus(FocusState.Programmatic); input.SelectAll(); };
        if (await DialogAsync(title, input, "Save") != ContentDialogResult.Primary) return null;
        var name = input.Text;
        if (string.IsNullOrWhiteSpace(name) || name is "." or ".." || name.IndexOfAny(['/', '\\', '\0']) >= 0 || name.Any(char.IsControl))
            throw new IOException("Enter a file name without path separators or control characters.");
        return name;
    }
    private async void NewFolder_Click(object sender, RoutedEventArgs e) => await RunAsync(async t =>
    {
        if (_directory is null) return;
        var name = await AskNameAsync("New Folder", "untitled folder");
        if (name is null) return;
        t.ThrowIfCancellationRequested(); await _source!.MakeDirectoryAsync(_source.Combine(_directory, name)); await RefreshAsync(t);
    });
    private async void Rename_Click(object sender, RoutedEventArgs e) => await RenameAsync();
    private Task RenameAsync() => RunAsync(async t =>
    {
        if (Selected() is not [var entry]) return;
        var name = await AskNameAsync("Rename", entry.Name);
        if (name is null || name == entry.Name) return;
        t.ThrowIfCancellationRequested(); await _source!.RenameAsync(entry.Path, _source.Combine(_source.Parent(entry.Path), name)); await RefreshAsync(t);
    });
    private async void Move_Click(object sender, RoutedEventArgs e) => await RunAsync(async t =>
    {
        var selected = Selected(); if (selected.Length == 0) return;
        var input = new TextBox { Text = Address.Text, Header = "Destination folder" };
        if (await DialogAsync("Move To", input, "Move") != ContentDialogResult.Primary) return;
        var destination = _source is LocalFileSource local ? local.NativePath(input.Text) : input.Text;
        if ((await _source!.StatAsync(destination)).Kind != FileKind.Directory) throw new IOException("Choose a destination folder.");
        foreach (var entry in selected)
        {
            t.ThrowIfCancellationRequested();
            var to = _source.Combine(destination, entry.Name);
            if (to == entry.Path || destination.StartsWith(entry.Path.TrimEnd('/', '\\') + (_source is LocalFileSource ? "\\" : "/"), StringComparison.Ordinal))
                throw new IOException("A folder cannot be moved into itself.");
            await _source.RenameAsync(entry.Path, to);
        }
        await RefreshAsync(t);
    });
    private async void Delete_Click(object sender, RoutedEventArgs e) => await DeleteAsync();
    private Task DeleteAsync() => RunAsync(async t =>
    {
        var selected = Selected(); if (selected.Length == 0) return;
        if (await DialogAsync($"Delete {selected.Length} item(s)?", "This permanently deletes the selected items and folder contents. This cannot be undone.\n\n" +
            string.Join("\n", selected.Take(10).Select(e => new Row(e).Name)), "Delete") != ContentDialogResult.Primary) return;
        try { foreach (var entry in selected) { t.ThrowIfCancellationRequested(); await _source!.RemoveTreeAsync(entry.Path, t); } }
        finally { if (!t.IsCancellationRequested) await RefreshAsync(t); }
    });
    private void CopyPath_Click(object sender, RoutedEventArgs e)
    {
        if (_source is null || Selected().Length == 0) return;
        var package = new DataPackage(); package.SetText(string.Join(Environment.NewLine, Selected().Select(e => _source.ShellPath(e.Path)))); Clipboard.SetContent(package);
    }
    private void InsertPath_Click(object sender, RoutedEventArgs e)
    {
        if (_source is null) return;
        try
        {
            var paths = Selected().Select(e => _source.ShellPath(e.Path)).ToArray();
            if (paths.Any(p => p.Any(char.IsControl))) throw new IOException("Paths with control characters cannot be inserted into the terminal.");
            var style = FilesPaths.StyleFor(_model.IsRemote, IsWsl, _model.LocalProfile);
            if (style == QuoteStyle.Cmd && paths.Any(FilesPaths.CmdUnsafe))
                throw new IOException("This path cannot safely be inserted into cmd. Use Copy Path instead.");
            _model.Send(new TerminalInput.Paste(string.Join(" ", paths.Select(path => FilesPaths.Quote(path, style)))));
        }
        catch (Exception ex) { Problem.Text = ex.Message; }
    }
    private void InitPicker(object picker) => WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle);
    private async void Upload_Click(object sender, RoutedEventArgs e) => await RunAsync(async t =>
    {
        if (_directory is null) return;
        var picker = new FileOpenPicker(); InitPicker(picker); picker.FileTypeFilter.Add("*");
        var items = await picker.PickMultipleFilesAsync();
        foreach (var item in items) await UploadItemAsync(item.Path, _directory, t);
        await RefreshAsync(t);
    });
    private async void UploadFolder_Click(object sender, RoutedEventArgs e) => await RunAsync(async t =>
    {
        if (_directory is null) return;
        var picker = new FolderPicker(); InitPicker(picker); picker.FileTypeFilter.Add("*");
        if (await picker.PickSingleFolderAsync() is { } item) await UploadItemAsync(item.Path, _directory, t);
        await RefreshAsync(t);
    });
    private IProgress<ulong> TransferProgress(string name) => new Progress<ulong>(bytes =>
    { if (!_disposed && _busy) Activity.Text = $"{name} · {FormatSize(bytes)}"; });
    private async Task<(string Path, bool Replace)?> UploadTargetAsync(string directory, string name, bool folder, CancellationToken token)
    {
        var target = _source!.Combine(directory, name);
        var entries = await _source.ListAsync(directory, token);
        var comparison = _source is LocalFileSource && !IsWsl ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var existing = entries.FirstOrDefault(e => string.Equals(e.Name, name, comparison));
        if (existing is null) return (target, false);
        var replaceAllowed = !folder && existing.Kind == FileKind.File;
        var result = await DialogAsync("Already Exists", $"{name} already exists in this folder.", "Keep Both", replaceAllowed ? "Replace" : null);
        token.ThrowIfCancellationRequested();
        if (result == ContentDialogResult.None) return null;
        if (result == ContentDialogResult.Secondary) return (target, true);
        var extension = folder ? "" : Path.GetExtension(name);
        var stem = folder ? name : name[..^extension.Length];
        for (var number = 2; ; number++)
        {
            var candidate = $"{stem} ({number}){extension}";
            if (!entries.Any(e => string.Equals(e.Name, candidate, comparison))) return (_source.Combine(directory, candidate), false);
        }
    }
    private async Task<string?> UploadItemAsync(string path, string directory, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var attributes = File.GetAttributes(path);
        if (attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Uploading links is not supported. Select the target file instead.");
        var folder = attributes.HasFlag(FileAttributes.Directory);
        var target = await UploadTargetAsync(directory, Path.GetFileName(path), folder, token);
        if (target is null) return null;
        if (folder)
        {
            if (_source is LocalFileSource && Path.GetFullPath(target.Value.Path).StartsWith(Path.GetFullPath(path).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("A folder cannot be copied into itself.");
            await _source!.MakeDirectoryAsync(target.Value.Path);
            foreach (var child in Directory.EnumerateFileSystemEntries(path)) await UploadItemAsync(child, target.Value.Path, token);
        }
        else await _source!.UploadAsync(path, target.Value.Path, target.Value.Replace, TransferProgress(Path.GetFileName(path)), token);
        return _source!.ShellPath(target.Value.Path);
    }
    private async void Download_Click(object sender, RoutedEventArgs e) => await RunAsync(async t =>
    {
        var selected = Selected(); if (selected.Length == 0) return;
        var directory = AppSettings.Current.DownloadDirectory;
        if (!Directory.Exists(directory))
        {
            var picker = new FolderPicker(); InitPicker(picker); picker.FileTypeFilter.Add("*");
            if (await picker.PickSingleFolderAsync() is not { } folder) return;
            directory = folder.Path;
        }
        foreach (var entry in selected) await DownloadItemAsync(entry, directory, t);
    });
    private static string SafeName(string name)
    {
        var cleaned = string.Concat(name.Select(c => Path.GetInvalidFileNameChars().Contains(c) || char.IsControl(c) ? '_' : c)).TrimEnd('.', ' ');
        if (string.IsNullOrWhiteSpace(cleaned) || cleaned is "." or "..") cleaned = "download";
        var stem = cleaned.Split('.')[0];
        if (new[] { "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }.Contains(stem, StringComparer.OrdinalIgnoreCase) ||
            (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && char.IsDigit(stem[3]))) cleaned = "_" + cleaned;
        return cleaned.Length > 180 ? cleaned[..180] : cleaned;
    }
    private async Task DownloadItemAsync(FileEntry entry, string directory, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (entry.Kind is FileKind.Link or FileKind.Other) throw new IOException("Saving links and special files is not supported. Open the target folder instead.");
        var name = SafeName(entry.Name); var path = Path.Combine(directory, name);
        for (var n = 2; Path.Exists(path); n++) path = Path.Combine(directory, $"{Path.GetFileNameWithoutExtension(name)} ({n}){Path.GetExtension(name)}");
        if (entry.Kind == FileKind.Directory)
        {
            if (_source is LocalFileSource && Path.GetFullPath(path).StartsWith(Path.GetFullPath(entry.Path).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("A folder cannot be copied into itself.");
            Directory.CreateDirectory(path);
            foreach (var child in await _source!.ListAsync(entry.Path, token)) await DownloadItemAsync(child, path, token);
        }
        else
        {
            // Download privately, then publish without replacement. Never
            // overwrite a user file that appeared after listing.
            if (_source is SftpSource)
            {
                var temporary = Path.Combine(directory, ".tether-" + Guid.NewGuid().ToString("N"));
                try
                {
                    await _source.DownloadAsync(entry.Path, temporary, TransferProgress(name), token);
                    token.ThrowIfCancellationRequested(); File.Move(temporary, path, false);
                }
                finally { if (File.Exists(temporary)) File.Delete(temporary); }
            }
            else await _source!.DownloadAsync(entry.Path, path, TransferProgress(name), token);
        }
    }
    private async Task<bool> ConfirmLargeFileAsync(FileEntry entry)
    {
        var limit = AppSettings.Current.FilesPromptMegabytes;
        if (limit > ulong.MaxValue / 1_000_000 || entry.Size <= limit * 1_000_000) return true;
        return await DialogAsync("Download this file?", $"{entry.Size / 1_000_000.0:N1} MB", "Download") == ContentDialogResult.Primary;
    }

    private async void Preview_Click(object sender, RoutedEventArgs e) => await PreviewSelectedAsync();

    private Task PreviewSelectedAsync() => RunAsync(async token =>
    {
        if (Selected() is not [var entry] || entry.Kind != FileKind.File) return;
        if (_source is SftpSource && !await ConfirmLargeFileAsync(entry)) return;
        // Inline previews are bounded; an external viewer handles larger files.
        if (entry.Size > 2_000_000) { await OpenFileAsync(entry, token); return; }
        var temporary = Path.Combine(Path.GetTempPath(), "tether-preview-" + Guid.NewGuid().ToString("N"));
        try
        {
            string path;
            if (_source is LocalFileSource local) path = local.NativePath(entry.Path);
            else { await _source!.DownloadAsync(entry.Path, temporary, TransferProgress(entry.Name), token); path = temporary; }
            var bytes = new byte[2 * 1024 * 1024 + 1];
            int count;
            using (var stream = File.OpenRead(path)) count = await stream.ReadAtLeastAsync(bytes, bytes.Length, throwOnEndOfStream: false, cancellationToken: token);
            if (count == bytes.Length) { await OpenFileAsync(entry, token); return; }
            Array.Resize(ref bytes, count);
            if (bytes.Take(8192).Contains((byte)0)) { await OpenFileAsync(entry, token); return; }
            var text = System.Text.Encoding.UTF8.GetString(bytes);
            var preview = new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap, Height = 220, MinWidth = 360 };
            await DialogAsync(entry.Name, preview, "Close");
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    });

    private void Entries_DragOver(object sender, DragEventArgs e)
    { if (!_busy && e.DataView.Contains(StandardDataFormats.StorageItems)) { e.AcceptedOperation = DataPackageOperation.Copy; e.Handled = true; } }
    private async void Entries_Drop(object sender, DragEventArgs e)
    {
        var deferral = e.GetDeferral();
        try
        {
            await RunAsync(async t =>
            {
                if (_directory is null) return;
                foreach (var item in await e.DataView.GetStorageItemsAsync()) await UploadItemAsync(item.Path, _directory, t);
                await RefreshAsync(t);
            });
        }
        finally { deferral.Complete(); }
    }
    private async Task OpenFileAsync(FileEntry entry, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        string path;
        if (_source is LocalFileSource local)
        {
            // Windows and WSL files open in place: edits go to the original.
            path = local.NativePath(entry.Path);
        }
        else
        {
            if (!await ConfirmLargeFileAsync(entry)) return;
            // Each remote copy keeps its filename and file association.
            // External apps may read it long after launch returns.
            var directory = Path.Combine(Path.GetTempPath(), "Tether", "OpenedFiles", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            path = Path.Combine(directory, SafeName(entry.Name));
            try
            {
                await _source!.DownloadAsync(entry.Path, path, TransferProgress(entry.Name), token);
                token.ThrowIfCancellationRequested();
            }
            catch
            {
                if (File.Exists(path)) File.Delete(path);
                Directory.Delete(directory);
                throw;
            }
        }

        token.ThrowIfCancellationRequested();
        var file = await StorageFile.GetFileFromPathAsync(path);
        token.ThrowIfCancellationRequested();
        if (!await Launcher.LaunchFileAsync(file))
            throw new IOException($"Windows could not open {entry.Name}. Set a default application for this file type in Windows Settings.");
        // Keep remote copies after launch and pane disposal. Edits stay local.
    }
    public void Report(string message) => Problem.Text = message;

    /// <summary>Puts dropped files where the shell is and returns the paths to type.</summary>
    public async Task<IReadOnlyList<string>> AcceptDropAsync(IReadOnlyList<string> localPaths)
    {
        IReadOnlyList<string> sent = [];
        await RunAsync(async token =>
        {
            await EnsureSourceAsync(token);
            var directory = _directory ?? await _source!.HomeAsync();
            if (_directory is null) await NavigateAsync(directory, false, token);
            var quoted = new List<string>();
            var style = FilesPaths.StyleFor(_model.IsRemote, IsWsl, _model.LocalProfile);
            foreach (var path in localPaths)
            {
                var written = await UploadItemAsync(path, directory, token);
                if (written is not null) quoted.Add(FilesPaths.Quote(written, style));
            }
            await RefreshAsync(token);
            sent = quoted;
        });
        return sent;
    }

    public async Task<bool> ExistsPrintedAsync(string printed, string? working, CancellationToken token)
    {
        try
        {
            await EnsureSourceAsync(token);
            return await ResolvePrintedAsync(printed, working, token) is not null;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { return false; }
    }

    public Task OpenPrintedAsync(string printed, string? working, CancellationToken token) =>
        RunAsync(async t =>
        {
            var entry = await ResolvePrintedAsync(printed, working, t) ?? throw new IOException($"Couldn't find {printed}.");
            if (entry.Kind == FileKind.Directory) await ShowEntryAsync(entry, t);
            else if (entry.Kind == FileKind.File) await OpenFileAsync(entry, t);
        });

    public Task RevealPrintedAsync(string printed, string? working, CancellationToken token) =>
        RunAsync(async t =>
        {
            var entry = await ResolvePrintedAsync(printed, working, t) ?? throw new IOException($"Couldn't find {printed}.");
            await ShowEntryAsync(entry, t);
        });

    private async Task<FileEntry?> ResolvePrintedAsync(string printed, string? working, CancellationToken token)
    {
        await EnsureSourceAsync(token);
        string? home = null;
        try { home = await _source!.HomeAsync(); } catch (Exception) { /* a missing home just drops that candidate */ }
        foreach (var candidate in FilesPaths.Candidates(printed, working, _directory is null ? null : _source!.ShellPath(_directory), home))
        {
            token.ThrowIfCancellationRequested();
            try { return await _source!.StatAsync(_source is LocalFileSource local ? local.NativePath(candidate) : candidate); }
            catch (Exception) { /* the next candidate */ }
        }
        return null;
    }

    private async Task ShowEntryAsync(FileEntry entry, CancellationToken token)
    {
        var folder = entry.Kind == FileKind.Directory ? entry.Path : _source!.Parent(entry.Path);
        await NavigateAsync(folder, true, token);
        if (entry.Kind == FileKind.Directory) return;
        var row = Entries.Items.OfType<Row>().FirstOrDefault(item => item.Entry.Path == entry.Path);
        if (row is null) return;
        Entries.SelectedItems.Clear();
        Entries.SelectedItems.Add(row);
        Entries.ScrollIntoView(row);
    }

    public async ValueTask DisposeAsync()
    {
        _disposed = true; _model.SessionChanged -= SessionChanged;
        _cancellation?.Cancel(); _dialog?.Close(); await _operation;
        if (_source is { } source) { _source = null; await source.DisposeAsync(); }
    }
}
