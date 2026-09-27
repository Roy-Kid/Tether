// The terminal surface: SwapChainPanel-hosted GPU draw + semantic input.
//
// Input is keys, not bytes (spec §12). Scroll chords are stolen before Send,
// the way `SessionModel.swift` does. One palette chooser feeds both the draw
// path and the session (Decision 0011).
//
// Selection is a rectangle of cells; copy takes the run text inside it and
// paste is a `TerminalInput.Paste` the engine brackets (spec §12).
//
// Links follow Decisions/0015: the terminal finds the shape (`LinkAt`), the
// frontend underlines what a person points at and says what opening does.
// The gestures are ones a program in the terminal cannot claim — Ctrl+click
// and the context menu — because a plain click stays the remote's when mouse
// reporting is on.

using System.Diagnostics;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tether;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TetherApp;

public sealed class TerminalControl : Control
{
    private readonly DispatcherQueue _uiQueue;
    private SessionModel? _model;
    private TerminalSurface? _surface;
    private ChildHwnd? _child;
    private FontMetrics _metrics = FontMetrics.FromAdvances(13, 8, 16, 16);
    private bool _ready;
    private double _fontSize = AppSettings.Current.Terminal.FontSize;
    private bool _pasting;
    private Selection? _selection;
    private bool _selecting;
    private double _scrollRemainder;
    private TerminalLink? _hovered;
    private bool _hoveredConfirmed;

    // Double-click is a timing question WinUI does not answer for us
    // (`PointerPointProperties` has no click count), so we keep it.
    private DateTimeOffset _lastPress = DateTimeOffset.MinValue;
    private Cell _lastPressCell;
    private int _clickCount;

    // Auto-scroll while a drag runs off the edge. A stationary pointer
    // outside the control still gets no move events, so this ticks.
    private readonly DispatcherTimer _autoScroll;
    private readonly DispatcherTimer _gridResize;
    private int _autoScrollDelta;
    /// <summary>A drag is in progress. Drawing now would rebuild the swap chain on every pixel, which is the shake.</summary>
    private bool _holdPaint;
    private int _backedWidth;
    private int _backedHeight;

    private static readonly Rgba SelectionTint = new(0.3f, 0.55f, 1f, 0.12f);
    private static readonly Rgba LinkTint = new(0.3f, 0.55f, 1f, 1f);
    private static readonly TimeSpan ClickInterval = TimeSpan.FromMilliseconds(400);

    public TerminalControl()
    {
        // Capture on the UI thread: FrameChanged also runs on the session
        // worker, where reading properties of this control is not safe.
        _uiQueue = DispatcherQueue;
        IsTabStop = true;
        Background = Appearance.Background(Palette.Dark);

        _autoScroll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _autoScroll.Tick += OnAutoScrollTick;
        // The shell reflows when the grid changes. Doing that on every pixel
        // of a drag is the text jumping under the cursor. Wait until the
        // drag pauses, then tell it once.
        _gridResize = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _gridResize.Tick += (_, _) => CommitSize();

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        SizeChanged += OnSizeChanged;
        GotFocus += (_, _) => FocusTerminal();
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        RightTapped += OnRightTapped;
        AllowDrop = true;
        DragOver += OnDragOver;
        Drop += OnDrop;
    }

    /// <summary>
    /// A plugin's answer to "does this exist?", or null when none has one.
    /// The terminal finds the shape; something with a lease is what can check it.
    /// </summary>
    public Func<TerminalLink, Task<bool?>>? QueryLink { get; set; }

    /// <summary>A plugin opened it. False leaves the local opener to try.</summary>
    public Func<TerminalLink, bool>? TryOpenLink { get; set; }

    /// <summary>Menu items a plugin adds for a link, beside Open and Copy.</summary>
    public Func<TerminalLink, IReadOnlyList<(string Title, Action Run)>>? LinkCommands { get; set; }

    /// <summary>Files dropped on the terminal. The host decides what a path means here.</summary>
    public Func<IReadOnlyList<string>, Task>? ReceiveDrop { get; set; }

    public async Task BindAsync(SessionModel model)
    {
        _model = model;
        SetPalette(model.Palette);
        // Frames arrive on the session's thread; the surface and the
        // pointer state are this control's, so drawing happens here.
        model.FrameChanged += _ => RequestRedraw();
        if (_ready)
        {
            await EnsureSurfaceAsync();
            Redraw();
        }
    }

    public void SetPalette(Palette palette)
    {
        Background = Appearance.Background(palette);
        if (_model?.Palette != palette) _model?.SetPalette(palette);
        RequestRedraw();
    }

    private bool _overlayVisible;
    private int _covers;

    public void SetOverlayVisible(bool visible)
    {
        _overlayVisible = visible;
        // Native child HWNDs otherwise cover XAML ContentDialogs (airspace).
        ApplyCover();
    }

    /// <summary>Hides the GPU child while a XAML popup is open over it. Nested.</summary>
    public void PushCover()
    {
        _covers++;
        ApplyCover();
    }

    public void PopCover()
    {
        if (_covers > 0) _covers--;
        ApplyCover();
    }

    private void ApplyCover()
    {
        if (_overlayVisible || _covers > 0) _child?.Hide();
        else if (_ready) { _child?.Show(); Redraw(); }
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _ready = true;
        AppSettings.Changed += ApplyPreferences;
        ApplyPreferences();
        if (_child is not null)
        {
            // A tab coming back: its child was hidden while another tab
            // was selected.
            _child.Fit(this);
            if (!_overlayVisible && _covers == 0) _child.Show();
        }
        await EnsureSurfaceAsync();
        Redraw();
        FocusTerminal();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _ready = false;
        AppSettings.Changed -= ApplyPreferences;
        _autoScroll.Stop();
        _child?.Hide();
    }

    /// <summary>
    /// Sends the keyboard to the terminal's input window. Deferred, because
    /// the XAML press or activation that asked is still in flight and would
    /// take focus back to the XAML island once it finishes.
    /// </summary>
    public void FocusTerminal()
    {
        _uiQueue.TryEnqueue(() =>
        {
            if (_ready) _child?.Focus();
        });
    }

    /// <summary>
    /// The GPU surface is a child window that covers this control and
    /// nothing else. The host window's handle is the whole window — chrome
    /// included — so drawing to it paints over the tabs (spec §8: the SDK is
    /// told a pointer-sized integer, and it must be *this* rectangle's).
    /// </summary>
    private Task EnsureSurfaceAsync()
    {
        if (_surface is not null) return Task.CompletedTask;

        var parent = ((App)Microsoft.UI.Xaml.Application.Current).MainWindowHandle;
        if (parent == 0 || ActualWidth <= 0 || ActualHeight <= 0) return Task.CompletedTask;

        // Loaded and SizeChanged both ask; one window gets one surface.
        return _creating ??= CreateSurfaceAsync(parent);
    }

    private Task? _creating;

    private async Task CreateSurfaceAsync(nint parent)
    {
        _child ??= ChildHwnd.Create(parent, this, SendText, HandleKey, OnChildPointer);
        _child.Fit(this);
        var (width, height) = _child.Size;
        _backedWidth = width;
        _backedHeight = height;
        _surface = await TerminalSurface.FromHwndAsync(_child.Handle, (uint)width, (uint)height);
        // The surface is in physical pixels. Measuring at a DIP size on a 4K
        // display gives half-sized glyphs and a cursor that stands beside the
        // character it is on — the grid is in the wrong units.
        _surface.SetFonts(AppSettings.Current.Terminal.FontFamily, AppSettings.Current.Terminal.WideFontFamily);
        _metrics = _surface.Measure((float)(_fontSize * DpiScale));
        ApplyResize();
    }

    /// <summary>Device pixels per DIP. 2 on a 4K display at 200%.</summary>
    private double DpiScale => XamlRoot?.RasterizationScale ?? 1.0;

    private int _redrawQueued;

    /// <summary>Asks for one redraw on the UI thread, however many frames arrive first.</summary>
    private void RequestRedraw()
    {
        if (Interlocked.Exchange(ref _redrawQueued, 1) == 1) return;
        if (!_uiQueue.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _redrawQueued, 0);
            Redraw();
        })) Interlocked.Exchange(ref _redrawQueued, 0);
    }

    private void Redraw()
    {
        if (_surface is null || _holdPaint) return;
        // Before a session exists there is still a terminal: paint one empty
        // frame with the palette's background. A light window is a missing
        // control; a dark page is a terminal with nothing in it (law
        // app-ui-chrome — the window *is* the terminal).
        var frame = _model?.CurrentFrame ?? BlankFrame();
        try
        {
            _surface.Draw(frame, _model?.Palette ?? Palette.Dark, BuildOverlay());
        }
        catch (Exception)
        {
            // An outdated or lost swap chain: configure it again at the
            // child's size and let the next frame draw. A missed frame is
            // not a reason to stop drawing — or to stop the session.
            if (_child is not null)
            {
                var (width, height) = _child.Size;
                _surface.Resize((uint)width, (uint)height);
            }
        }
    }

    /// <summary>An empty screen of the size this control is being asked for.</summary>
    private ScreenFrame BlankFrame()
    {
        var columns = (uint)_metrics.ColumnsFitting(ActualWidth * DpiScale);
        var rows = (uint)_metrics.RowsFitting(ActualHeight * DpiScale);
        var line = new StyledRun(new string(' ', (int)columns), columns, RunStyle.Default);
        var lines = new ScreenRow[rows];
        for (var i = 0; i < rows; i++) lines[i] = new ScreenRow(new[] { line });
        return new ScreenFrame(
            columns, rows,
            0, 0,
            CaretShape.Hidden,
            false,
            false,
            0, 0,
            "",
            lines);
    }

    private Overlay BuildOverlay()
    {
        var underlines = new List<LinkUnderline>();
        if (_hovered is { } link)
        {
            foreach (var span in link.Spans)
            {
                underlines.Add(new LinkUnderline(span.Row, span.Start, span.End, _hoveredConfirmed));
            }
        }
        return new Overlay(_selection, underlines, SelectionTint, LinkTint);
    }

    private async void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_surface is null)
        {
            // Loaded at zero size: the surface waits for a real rectangle.
            if (!_ready) return;
            await EnsureSurfaceAsync();
            Redraw();
            FocusTerminal();
            return;
        }
        // Follow the control now, but do not rebuild the swap chain or ask
        // the shell to reflow until the drag pauses. Both of those on every
        // pixel are what shakes a high-DPI window.
        _holdPaint = true;
        _child?.Fit(this);
        _gridResize.Stop();
        _gridResize.Start();
    }

    /// <summary>The drag paused. One swap-chain resize, one grid, one paint.</summary>
    private void CommitSize()
    {
        _gridResize.Stop();
        _holdPaint = false;
        if (_surface is not null && _child is not null)
        {
            var (width, height) = _child.Size;
            if (width != _backedWidth || height != _backedHeight)
            {
                _surface.Resize((uint)width, (uint)height);
                _backedWidth = width;
                _backedHeight = height;
            }
        }
        ApplyResize();
        Redraw();
    }

    /// <summary>
    /// Tells the session how many cells fit. The surface itself is sized in
    /// pixels, from the child window — never from the grid: a swap chain
    /// configured at 80×24 *pixels* is stretched over the whole window and
    /// shows a corner of the screen, without the caret.
    /// </summary>
    private void ApplyResize()
    {
        if (_surface is null || _model is null || _child is null) return;
        var (width, height) = _child.Size;
        var columns = _metrics.ColumnsFitting(width);
        var rows = _metrics.RowsFitting(height);
        _model.Resize(columns, rows);
    }

    // ---- input: keys, not bytes ----
    //
    // The HWND is the input window: keys and the pointer arrive in
    // `ChildHwnd`'s WndProc and are handed here. XAML never sees either for
    // a control sitting under that window. The XAML events stay as the path
    // for when the island holds the pointer; both go through the same
    // handlers, so a key or a click is never taken twice.
    //
    // A key press is decided from the virtual key when it is a named key or
    // a chord; plain text waits for the character message, which carries
    // the layout, dead keys and the IME.

    /// <summary>
    /// Whether this key press was taken. One that was not produces text,
    /// which arrives through <see cref="SendText"/>.
    /// </summary>
    private bool HandleKey(VirtualKey key)
    {
        if (_model is null) return false;

        var shift = IsDown(VirtualKey.Shift);
        var alt = IsDown(VirtualKey.Menu);
        var control = IsDown(VirtualKey.Control);

        var pressed = new Shortcut(key, shift, control, alt);
        foreach (var (name, chordText) in AppSettings.Current.Terminal.Bindings)
        {
            if (!Shortcut.TryParse(chordText, out var shortcut) || shortcut != pressed) continue;
            switch (name)
            {
                case "Copy":
                    if (_selection is { } selected && !selected.IsEmpty()) CopySelection(selected);
                    else if (control && !shift && key == VirtualKey.C) break;
                    return true;
                case "Paste": _ = PasteAsync(); return true;
                case "Zoom in": Zoom(1); return true;
                case "Zoom out": Zoom(-1); return true;
                case "Reset zoom": Zoom(0); return true;
            }
        }
        if (control && !shift && !alt && key == VirtualKey.C && _selection is { } selection && !selection.IsEmpty())
        {
            CopySelection(selection);
            return true;
        }
        if (control && !shift && !alt && key == VirtualKey.V)
        {
            _ = PasteAsync();
            return true;
        }

        // Scroll chords are stolen before Send (SessionModel.swift:314-328).
        if (KeyInput.ScrollChord(key, shift, control, alt) is { } scroll)
        {
            _model.Scroll(scroll);
            return true;
        }

        // Plain and shifted keys type text. So does Ctrl+Alt, which is how
        // AltGr arrives — `@` on a German keyboard is not a chord.
        var chord = control != alt;
        if (!chord && !IsNamedKey(key)) return false;

        if (KeyInput.FromVirtualKey(key, shift, alt, control) is { } input)
        {
            _selection = null;
            _model.Send(input);
            RequestRedraw();
            return true;
        }
        return false;
    }

    /// <summary>Keys that never become text on their own.</summary>
    private static bool IsNamedKey(VirtualKey key) => key switch
    {
        VirtualKey.Enter or VirtualKey.Tab or VirtualKey.Back or VirtualKey.Escape
            or VirtualKey.Delete or VirtualKey.Insert
            or VirtualKey.Up or VirtualKey.Down or VirtualKey.Left or VirtualKey.Right
            or VirtualKey.Home or VirtualKey.End or VirtualKey.PageUp or VirtualKey.PageDown => true,
        >= VirtualKey.F1 and <= VirtualKey.F24 => true,
        _ => false,
    };

    /// <summary>Typed text: one scalar, already composed by the layout.</summary>
    private void SendText(string text)
    {
        if (_model is null) return;
        if (KeyInput.FromVirtualKey(VirtualKey.None, false, false, false, text) is { } input)
        {
            _selection = null;
            _model.Send(input);
            RequestRedraw();
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        _xamlKeyTaken = HandleKey(e.Key);
        if (_xamlKeyTaken) e.Handled = true;
    }

    private char _highSurrogate;
    private bool _xamlKeyTaken;

    private void OnCharacterReceived(object sender, CharacterReceivedRoutedEventArgs e)
    {
        var ch = e.Character;
        e.Handled = true;
        if (_xamlKeyTaken) return;
        if (char.IsHighSurrogate(ch))
        {
            _highSurrogate = ch;
            return;
        }
        if (char.IsLowSurrogate(ch))
        {
            if (_highSurrogate != '\0') SendText(new string([_highSurrogate, ch]));
            _highSurrogate = '\0';
            return;
        }
        _highSurrogate = '\0';
        // Control characters were sent as keys from KeyDown.
        if (ch < ' ' || ch == '\x7F') return;
        SendText(ch.ToString());
    }

    protected override void OnPointerWheelChanged(PointerRoutedEventArgs e)
    {
        if (_model is null) return;
        var point = e.GetCurrentPoint(this);
        var delta = point.Properties.MouseWheelDelta;
        HandleWheel(delta, point.Position);
        e.Handled = true;
        base.OnPointerWheelChanged(e);
    }

    /// <summary>
    /// Pointer input from the render window, whose client pixels cover this
    /// control. XAML never sees those events: the window is in front of the island.
    /// </summary>
    private void OnChildPointer(ChildPointer message)
    {
        var scale = DpiScale;
        if (scale <= 0) scale = 1;
        var position = new Windows.Foundation.Point(message.X / scale, message.Y / scale);
        switch (message.Kind)
        {
            case ChildPointerKind.Wheel:
                HandleWheel(message.Delta, position);
                break;
            case ChildPointerKind.LeftDown:
                PressAt(position);
                break;
            case ChildPointerKind.Move:
                MoveAt(position);
                break;
            case ChildPointerKind.LeftUp:
                ReleaseAt();
                break;
            case ChildPointerKind.RightUp:
                ShowMenu(position);
                break;
        }
    }

    private void HandleWheel(int delta, Windows.Foundation.Point position)
    {
        if (_model is null) return;
        _scrollRemainder += -delta / 120.0;
        var lines = (int)_scrollRemainder;
        if (lines != 0)
        {
            _scrollRemainder -= lines;
            var cell = CellAt(position);
            var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            _model.Wheel(lines, (ushort)Math.Max(0, cell.Row), (ushort)Math.Max(0, cell.Column), shift);
        }
    }

    // ---- selection ----

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        if (point.Properties.IsRightButtonPressed) return;
        PressAt(point.Position);
        CapturePointer(e.Pointer);
        e.Handled = true;
    }

    /// <summary>Starts a selection at <paramref name="position"/>, or opens a link on Ctrl+click.</summary>
    private void PressAt(Windows.Foundation.Point position)
    {
        FocusTerminal();
        var cell = CellAt(position);

        // Ctrl+click opens a link. A plain click stays the remote's when
        // mouse reporting is on (Decisions/0015).
        if (IsDown(VirtualKey.Control) && LinkAt(cell) is { } link)
        {
            OpenLink(link);
            return;
        }

        var now = DateTimeOffset.UtcNow;
        _clickCount = (now - _lastPress <= ClickInterval && cell == _lastPressCell)
            ? _clickCount + 1
            : 1;
        _lastPress = now;
        _lastPressCell = cell;

        if (_model?.CurrentFrame is { } frame)
        {
            // Double-click a word, triple-click a line. The drag that
            // follows extends from that unit, which is what every terminal
            // does and what makes "select the path, drag to widen it" work.
            if (_clickCount == 2 && SelectionText.WordAt(frame, cell) is { } word)
            {
                _selection = word;
                _selecting = true;
                Redraw();
                return;
            }
            if (_clickCount >= 3)
            {
                _selection = SelectionText.LineAt(frame, cell);
                _selecting = true;
                Redraw();
                return;
            }
        }

        _selection = new Selection(cell, cell);
        _selecting = true;
        Redraw();
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        MoveAt(e.GetCurrentPoint(this).Position);
    }

    private void MoveAt(Windows.Foundation.Point raw)
    {
        var cell = CellAt(raw);

        if (_selecting && _selection is { } current)
        {
            // Drag off the edge: the pointer has left the grid. Clamp the
            // cell to it and ask the session to scroll — repeatedly, through
            // the timer, while the pointer stays out there.
            _autoScrollDelta = EdgeDelta(raw.Y);
            if (_autoScrollDelta != 0)
            {
                _autoScroll.Start();
            }
            else
            {
                _autoScroll.Stop();
            }

            _selection = current with { Focus = cell };
            Redraw();
            return;
        }

        _autoScroll.Stop();
        _autoScrollDelta = 0;

        // Hover: ask what the text names, never per frame (0015).
        var link = LinkAt(cell);
        if (link?.Text != _hovered?.Text)
        {
            _hovered = link;
            _hoveredConfirmed = false;
            Redraw();
            if (link is not null) _ = ConfirmLinkAsync(link);
        }
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        ReleaseAt();
        ReleasePointerCapture(e.Pointer);
    }

    private void ReleaseAt()
    {
        _selecting = false;
        _autoScroll.Stop();
        _autoScrollDelta = 0;
        if (_selection is { } s && s.IsEmpty()) _selection = null;
        Redraw();
    }

    /// <summary>
    /// How far the pointer is past the top or bottom edge, as a scroll
    /// direction: negative above, positive below, zero inside.
    /// </summary>
    private int EdgeDelta(double y)
    {
        if (y < 0) return -1;
        if (y > ActualHeight) return 1;
        return 0;
    }

    private void OnAutoScrollTick(object? sender, object e)
    {
        if (!_selecting || _model is null || _autoScrollDelta == 0) return;
        _model.Scroll(ScrollTo.Lines(_autoScrollDelta));

        // Extend the selection to the edge row the scroll just showed.
        if (_selection is { } current)
        {
            var edge = _autoScrollDelta < 0
                ? new Cell(current.Focus.Column, Math.Max(0, current.Focus.Row - 1))
                : new Cell(current.Focus.Column, current.Focus.Row + 1);
            _selection = current with { Focus = edge };
            Redraw();
        }
    }

    // ---- links (Decisions/0015) ----

    private TerminalLink? LinkAt(Cell cell) =>
        _model?.LinkAt((ushort)Math.Max(0, cell.Row), (ushort)Math.Max(0, cell.Column));

    /// <summary>
    /// The underline is dotted while the host is asked whether the thing
    /// exists, solid once it says yes. Without a Files plugin that answers
    /// over the lease, a local path is checked here and anything else is
    /// assumed present — the terminal finds shapes and never checks them
    /// over the wire.
    /// </summary>
    private async Task ConfirmLinkAsync(TerminalLink link)
    {
        var answered = QueryLink is null ? null : await QueryLink(link);
        var exists = answered ?? await Task.Run(() => LinkExists(link));
        if (_hovered?.Text == link.Text)
        {
            _hoveredConfirmed = exists;
            Redraw();
        }
    }

    private static bool LinkExists(TerminalLink link) => link.Kind switch
    {
        LinkKind.Url => true,
        LinkKind.Hyperlink => true,
        LinkKind.Path path => File.Exists(Resolve(path.Location)) || Directory.Exists(Resolve(path.Location)),
        _ => true,
    };

    private static string Resolve(string path) =>
        System.IO.Path.IsPathRooted(path)
            ? path
            : System.IO.Path.Combine(Environment.CurrentDirectory, path);

    private void OpenLink(TerminalLink link)
    {
        if (TryOpenLink?.Invoke(link) == true) return;
        try
        {
            switch (link.Kind)
            {
                case LinkKind.Url url:
                    Process.Start(new ProcessStartInfo(url.Href) { UseShellExecute = true });
                    break;
                case LinkKind.Hyperlink hyperlink:
                    Process.Start(new ProcessStartInfo(hyperlink.Uri) { UseShellExecute = true });
                    break;
                case LinkKind.Path path:
                    var resolved = Resolve(path.Location);
                    if (File.Exists(resolved) || Directory.Exists(resolved))
                    {
                        Process.Start(new ProcessStartInfo(resolved) { UseShellExecute = true });
                    }
                    break;
            }
        }
        catch (Exception)
        {
            // Opening is a local action; a failure is not a session failure.
        }
    }

    private void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        ShowMenu(e.GetPosition(this));
        e.Handled = true;
    }

    private void ShowMenu(Windows.Foundation.Point position)
    {
        var cell = CellAt(position);
        var link = LinkAt(cell);
        var commands = new List<(string Title, Action Run)>();
        if (_selection is { } selected && !selected.IsEmpty())
            commands.Add(("Copy", () => CopySelection(selected)));
        if (link is not null)
        {
            commands.Add(("Open", () => OpenLink(link)));
            commands.AddRange(LinkCommands?.Invoke(link) ?? []);
            commands.Add(("Copy link", () => CopyText(LinkText(link))));
        }
        commands.Add(("Paste", () => _ = PasteAsync()));
        if (_child is not null)
        {
            NativeContextMenu.Show(_child.Handle, (int)Math.Round(position.X * DpiScale),
                (int)Math.Round(position.Y * DpiScale), commands);
        }
        else
        {
            var menu = new MenuFlyout();
            foreach (var command in commands)
            {
                var item = new MenuFlyoutItem { Text = command.Title };
                item.Click += (_, _) => command.Run();
                menu.Items.Add(item);
            }
            menu.ShowAt(this, position);
        }
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.Handled = true;
        }
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (ReceiveDrop is null || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var deferral = e.GetDeferral();
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            var paths = items.Select(item => item.Path).Where(path => path.Length > 0).ToArray();
            if (paths.Length > 0) await ReceiveDrop(paths);
        }
        finally { deferral.Complete(); }
    }

    private static string LinkText(TerminalLink link) => link.Kind switch
    {
        LinkKind.Url url => url.Href,
        LinkKind.Hyperlink hyperlink => hyperlink.Uri,
        LinkKind.Path path => path.Location,
        _ => link.Text,
    };

    private Cell CellAt(Windows.Foundation.Point point)
    {
        // Pointer positions are DIPs; the grid is in physical pixels. A 4K
        // display at 200% would otherwise report every cell as four times
        // its column.
        var x = point.X * DpiScale;
        var y = point.Y * DpiScale;
        var column = (int)(x / _metrics.CellWidth);
        var row = (int)(y / _metrics.LineHeight);
        return new Cell(Math.Max(0, column), Math.Max(0, row));
    }

    private void CopySelection(Selection selection)
    {
        var frame = _model?.CurrentFrame;
        if (frame is null) return;
        CopyText(selection.Text(frame));
    }

    private static void CopyText(string text)
    {
        if (text.Length == 0) return;
        var package = new DataPackage();
        package.SetText(text);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (Exception ex)
        {
            _ = Alerts.ClipboardErrorAsync(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread(), ex.Message);
        }
    }

    private async Task PasteAsync()
    {
        if (_pasting || _model is not { IsLive: true }) return;
        _pasting = true;
        var model = _model;
        var generation = model.Generation;
        try
        {
            var package = Clipboard.GetContent();
            if (!package.Contains(StandardDataFormats.Text)) return;
            var text = await package.GetTextAsync();
            if (string.IsNullOrEmpty(text)) return;
            if (AppSettings.Current.Terminal.ConfirmPaste(text) &&
                !await Alerts.ConfirmPasteAsync(_uiQueue, text.Length)) return;
            if (_ready && ReferenceEquals(model, _model) && model.Generation == generation && model.IsLive)
            {
                _selection = null;
                model.Send(KeyInput.Paste(text));
                RequestRedraw();
            }
        }
        catch (Exception ex) { await Alerts.ClipboardErrorAsync(_uiQueue, ex.Message); }
        finally { _pasting = false; FocusTerminal(); }
    }

    private void Zoom(int delta)
    {
        var size = delta == 0 ? 13 : Math.Clamp(_fontSize + delta, 10, 32);
        (AppSettings.Current with { Terminal = AppSettings.Current.Terminal with { FontSize = size } }).Save();
    }

    private void ApplyPreferences()
    {
        _fontSize = AppSettings.Current.Terminal.FontSize;
        if (_surface is null) return;
        _surface.SetFonts(AppSettings.Current.Terminal.FontFamily, AppSettings.Current.Terminal.WideFontFamily);
        _metrics = _surface.Measure((float)(_fontSize * DpiScale));
        _selection = null;
        ApplyResize();
        RequestRedraw();
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
}
