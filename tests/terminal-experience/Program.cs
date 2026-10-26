using System.Text.Json;
using Tether;
using TetherApp;
using Windows.System;

if (args.SequenceEqual(new[] { "--measure-appearance" }))
{
    AppearanceCost.Run();
    return;
}

var firstPane = Guid.NewGuid();
var secondPane = Guid.NewGuid();
var thirdPane = Guid.NewGuid();
var splitTree = SplitLayout.Leaf(firstPane).Split(firstPane, secondPane, false).Split(secondPane, thirdPane, true);
Check(splitTree.Leaves.SequenceEqual(new[] { firstPane, secondPane, thirdPane }), "recursive split order");
Check(splitTree.MinimumSize == (325d, 205d), "nested branches reserve all pane minimums");
Check(splitTree.IsValid(new HashSet<Guid> { firstPane, secondPane, thirdPane }), "saved layout references exactly its panes");
Check(!splitTree.IsValid(new HashSet<Guid> { firstPane, secondPane }), "reject missing saved pane");
Check(!new SplitLayout(null, Ratio: double.NaN, First: SplitLayout.Leaf(firstPane), Second: SplitLayout.Leaf(secondPane)).IsValid(new HashSet<Guid> { firstPane, secondPane }), "reject non-finite split ratio");
Check(!new SplitLayout(null, First: SplitLayout.Leaf(firstPane), Second: SplitLayout.Leaf(firstPane)).IsValid(new HashSet<Guid> { firstPane }), "reject duplicate pane identities");
Check(splitTree.Remove(secondPane)!.Leaves.SequenceEqual(new[] { firstPane, thirdPane }), "close collapses only its branch");
Check(splitTree.Remove(firstPane)!.RestoreBeside(new HashSet<Guid> { secondPane, thirdPane }, firstPane, false, true, .5) == splitTree, "restore original side around the whole neighboring branch");
Check(splitTree.Remove(firstPane)!.Remove(secondPane)!.Pane == thirdPane, "collapse to final leaf");
Check(splitTree.Remove(firstPane)!.Remove(secondPane)!.Remove(thirdPane) is null, "last pane empties layout");
var left = SplitLayout.Leaf(firstPane).Split(firstPane, secondPane, false, before: true);
Check(left.First!.Pane == secondPane && left.Second!.Pane == firstPane && !left.Vertical, "split left puts the new pane first");
var up = SplitLayout.Leaf(firstPane).Split(firstPane, secondPane, true, before: true);
Check(up.Vertical && up.First!.Pane == secondPane && up.Second!.Pane == firstPane, "split up puts the new pane above");
var draggedLeft = SplitLayout.PlaceInLayout(SplitLayout.Leaf(firstPane).Split(firstPane, secondPane, false), secondPane, firstPane, SplitEdge.Left);
Check(draggedLeft.First!.Pane == secondPane && draggedLeft.Second!.Pane == firstPane, "dragging onto the left edge");
var draggedDown = SplitLayout.PlaceInLayout(draggedLeft, firstPane, secondPane, SplitEdge.Down);
Check(draggedDown.Vertical && draggedDown.First!.Pane == secondPane && draggedDown.Second!.Pane == firstPane, "dragging onto the bottom edge");
Check(SplitEdges.Drop(10, 8, 100, 24, null) == SplitEdge.Left, "a wide chip's left half");
Check(SplitEdges.Drop(80, 8, 100, 24, null) == SplitEdge.Right, "a wide chip's right half");
Check(SplitEdges.Drop(8, 10, 24, 100, null) == SplitEdge.Up, "a tall chip's top half");
Check(SplitEdges.Drop(8, 80, 24, 100, null) == SplitEdge.Down, "a tall chip's bottom half");
Check(SplitEdges.Drop(50, 50, 100, 100, 0.28) is null, "the middle of a pane is not an edge");
Check(SplitEdges.Drop(4, 50, 100, 100, 0.28) == SplitEdge.Left, "a pane's left band");
Check(SplitEdges.Drop(50, 2, 100, 24, 0.28) == SplitEdge.Up, "the top band of a wide chip");
Check(SplitEdges.DropOnChip(50, 12, 100, 24) == SplitEdge.Right, "the middle of a wide chip splits right");
Check(SplitEdges.DropOnChip(8, 12, 100, 24) == SplitEdge.Left, "the left band of a wide chip");
Check(SplitEdges.Drop(0, 0, 0, 10, null) is null, "an empty chip has no edge");
var dragged = splitTree.WithRatio(new[] { secondPane, thirdPane }, .3).WithRatio(splitTree.Leaves, .65);
Check(dragged.Ratio == .65 && dragged.Second!.Ratio == .3, "dragging an outer divider preserves the latest inner ratio");
Check(JsonSerializer.Deserialize<SplitLayout>(JsonSerializer.Serialize(splitTree)) == splitTree, "layout survives restart");

var preferences = new TerminalPreferences();
Check(preferences.Validate() is null, "defaults are valid");
Check(!preferences.ConfirmPaste("echo hello"), "short single-line paste");
Check(!preferences.ConfirmPaste(new string('x', 4095)), "below threshold");
Check(preferences.ConfirmPaste(new string('x', 4096)), "threshold is inclusive");
foreach (var text in new[] { "echo hi\n", "echo hi\r", "a\r\nb" })
    Check(preferences.ConfirmPaste(text), "all line endings require confirmation");
Check((preferences with { PasteThreshold = 4 }).ConfirmPaste("1234"), "custom threshold");
Check((preferences with { FontSize = double.NaN }).Validate() is not null, "reject non-finite size");
Check((preferences with { FontSize = 33 }).Validate() is not null, "font limit");
Check((preferences with { PasteThreshold = 0 }).Validate() is not null, "positive threshold");
Check((preferences with { Copy = "shift+ctrl+v" }).Validate() is not null, "duplicates are normalized");
foreach (var invalid in new[] { "C", "Shift+C", "Ctrl+Alt+C", "Ctrl+Ctrl+C", "Ctrl+", "Ctrl+Unknown", "Ctrl++" })
    Check(!Shortcut.TryParse(invalid, out _), "reject invalid or AltGr chord: " + invalid);
Check(Shortcut.TryParse(" ctrl + shift + c ", out var copy) &&
    copy == new Shortcut(VirtualKey.C, true, true, false), "case and spacing normalization");
Check(Shortcut.TryParse("Ctrl+0", out var reset) && reset.Key == VirtualKey.Number0, "digit mapping");
Check(Shortcut.TryParse("Ctrl+Shift+Equals", out var zoom) && (int)zoom.Key == 187, "OEM plus key");
var restored = JsonSerializer.Deserialize<AppSettings>("{\"Shell\":\"cmd\"}")!;
Check(restored.Terminal == preferences, "old settings retain defaults");
Check(restored.WindowMaterial == "acrylic" && restored.BackgroundOpacity == .6, "old settings get the shared workspace glass default");
// Same cases as WorkspaceAppearanceTests in the macOS app suite.
Check(WorkspaceAppearance.Opacity(false, .65, false, false) == 1, "solid workspace is opaque");
Check(WorkspaceAppearance.Opacity(true, .65, false, false) == .65, "workspace opacity is preserved");
Check(WorkspaceAppearance.Opacity(true, .65, true, false) == 1, "reduce transparency forces solid");
Check(WorkspaceAppearance.Opacity(true, .65, false, true) == 1, "increased contrast forces solid");
foreach (var (stored, expected) in new[] { (.1, .5), (2d, 1d), (double.NaN, .6), (double.PositiveInfinity, .6) })
    Check(WorkspaceAppearance.Opacity(true, stored, false, false) == expected, "workspace opacity bounds match macOS");
foreach (var palette in new[] { Palette.Dark, Palette.Light })
{
    var clear = TerminalAppearance.ForRendering(palette, true);
    Check(ReferenceEquals(TerminalAppearance.ForRendering(clear, true), clear), "already-resolved transparent palettes are reused");
    Check(ReferenceEquals(TerminalAppearance.ForRendering(palette, false), palette), "opaque palettes are reused without cloning");
    Check(clear.Background == palette.Background with { Alpha = 0 }, "glass clears only the default GPU background");
    Check(clear with { Background = palette.Background } == palette, "text, cursor and ANSI palette remain unchanged");
    Check(clear.Resolve(ColorName.Red).Alpha == 1, "explicit ANSI cell backgrounds stay opaque");
    Check(TerminalAppearance.ForRendering(palette, false) == palette, "solid restores the opaque GPU palette");
}
var glassPreferences = restored with { WindowMaterial = "solid", BackgroundOpacity = .75 };
var restoredGlass = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(glassPreferences))!;
Check(restoredGlass.WindowMaterial == "solid" && restoredGlass.BackgroundOpacity == .75,
    "material and tint survive restart without touching user settings");
Check(restored.QuickTerminalEnabled && restored.QuickTerminalAutoHide && restored.QuickTerminalTrayIcon && !restored.AlwaysOnTop,
    "legacy settings get Quick Terminal defaults");
Check(QuickTerminalGeometry.TopHalf(new(-1920, -1080, 1920, 1040), 450) == new QuickTerminalBounds(-1920, -1080, 1920, 520),
    "quick terminal uses work area and preserves negative display origins");
Check(QuickTerminalGeometry.TopHalf(new(0, 40, 800, 400), 520) == new QuickTerminalBounds(0, 40, 800, 400),
    "minimum height is clamped to the screen, with taskbar offset preserved");
Check(Shortcut.TryParse("Ctrl+Backquote", out var quick) && Shortcut.TryParse("Ctrl+`", out var quickAlias) && quick == quickAlias && (int)quick.Key == 192,
    "quick terminal uses the OEM backquote key and supports its literal alias");
Check(WorkspaceCommands.Validate(new Dictionary<string, string> { ["quickTerminal"] = "Ctrl+P" }, preferences) is not null,
    "global shortcut conflicts with local commands are rejected");
var quickPreferences = restored with { QuickTerminalEnabled = false, QuickTerminalAutoHide = false, QuickTerminalTrayIcon = false, AlwaysOnTop = true };
Check(JsonSerializer.Serialize(JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(quickPreferences))) == JsonSerializer.Serialize(quickPreferences),
    "quick terminal preferences round-trip");
var custom = restored with { Terminal = preferences with { Copy = "Alt+C", FontSize = 18, FontFamily = "Cascadia Mono", WideFontFamily = "Microsoft YaHei", PasteThreshold = 100 } };
Check(JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(custom))!.Terminal == custom.Terminal,
    "preferences persist without touching user settings");
Check(SessionStatus.Describe(new SessionEnding.Exited(0)) == "Exited (0)", "successful exit stays explicit");
Check(SessionStatus.Describe(new SessionEnding.Exited(17)) == "Exited (17)", "nonzero exit code");
Check(SessionStatus.Describe(new SessionEnding.Lost("network")) == "Connection lost", "transport loss differs from exit");
Check(SessionStatus.Describe(new SessionEnding.Closed()) == "Closed", "closed connection");
Check(SessionStatus.Describe(null) == "Ended", "unknown ending does not imply success");
var frame = new ScreenFrame(6, 2, 0, 0, CaretShape.Hidden, false, false, 0, 0, "",
    [new ScreenRow([new StyledRun("a", 1, RunStyle.Default), new StyledRun("中", 2, RunStyle.Default),
        new StyledRun("e\u0301  ", 3, RunStyle.Default)]),
     new ScreenRow([new StyledRun("second", 6, RunStyle.Default)])]);
Check(new Selection(new Cell(2, 0), new Cell(3, 0)).Text(frame) == "中e\u0301", "wide and combining characters");
var selectedText = "e\u0301" + Environment.NewLine + "se";
Check(new Selection(new Cell(3, 0), new Cell(1, 1)).Text(frame) == selectedText, "forward multi-line selection");
Check(new Selection(new Cell(1, 1), new Cell(3, 0)).Text(frame) == selectedText, "reverse multi-line selection");

TerminalLabel Row(string serial = "Terminal 1", string? pinned = null, string? session = null,
    string? command = null, string? directory = null) =>
    new(Guid.NewGuid(), pinned, session, command, directory, serial);
string? Title(TerminalLabel row, params TerminalLabel[] rest) =>
    TerminalLabels.Titles(new[] { row }.Concat(rest).ToArray())[row.Id];
Check(Title(Row(command: "ssh", directory: "Nerve")) == "ssh", "a running program is the name");
var first = Row(command: "ssh");
var second = Row("Terminal 2", command: "ssh");
var third = Row("Terminal 3", command: "vim");
var numbered = TerminalLabels.Titles([first, second, third]);
Check(numbered[first.Id] == "ssh 1" && numbered[second.Id] == "ssh 2" && numbered[third.Id] == "vim", "matching automatic names are numbered");
Check(Title(Row(session: "dev", command: "tmux", directory: "Nerve")) == "dev", "tmux session names the chip");
var pinned = Row(pinned: "api", command: "ssh");
var other = Row("Terminal 2", command: "ssh");
var pins = TerminalLabels.Titles([pinned, other]);
Check(pins[pinned.Id] == "api" && pins[other.Id] == "ssh", "a typed name stays and is not numbered with twins");
Check(Title(Row(directory: "Nerve")) == "Nerve", "idle shell uses the directory");
Check(TerminalLabels.DirectoryName("/Users/ada/work/Nerve/", "/Users/ada") == "Nerve", "unix directory base");
Check(TerminalLabels.DirectoryName("/Users/ada", "/Users/ada/") == "~", "home is ~");
Check(TerminalLabels.DirectoryName(@"C:\Users\ada\work\Nerve", @"C:\Users\ada") == "Nerve", "windows directory base");
Check(TerminalLabels.IsSerial("Terminal 12") && !TerminalLabels.IsSerial("api"), "Terminal N is the serial form");
Check(TerminalLabels.RestoredPin("Terminal 3", null) is null && TerminalLabels.RestoredPin("api", null) == "api", "legacy typed names stay pinned");
Check(LocalForeground.Picked(10, 10, "zsh") is null && LocalForeground.Picked(10, 40, "/usr/bin/ssh") == "ssh", "foreground picking matches macOS");

var fonts = TerminalSurface.FontFamilies();
Check(fonts.Length > 0 && fonts.Distinct().Count() == fonts.Length, "native installed-font enumeration");
Check((preferences with { FontFamily = "" }).Validate() is not null, "reject empty font selection");
Check(WorkspaceCommands.Validate(new Dictionary<string, string>(), preferences) is null, "workspace defaults do not collide with terminal shortcuts");
Check(WorkspaceCommands.Validate(new Dictionary<string, string> { ["closeTab"] = "Ctrl+Shift+C" }, preferences) is not null, "reject terminal/workspace conflict");
Check(WorkspaceCommands.Validate(new Dictionary<string, string> { ["closeTab"] = "" }, preferences) is null, "allow unassigned shortcut");
Check(Shortcut.TryParse("Ctrl+PageUp", out var previous) && previous.Key == VirtualKey.PageUp, "named shortcut keys");
var ttyTable = "banner\nTETHER-TTY 20\n1 0 ?\n10 1 ?\n11 10 pts/3\n20 10 ?\n21 20 pts/9\nTETHER-TTY-END\n";
Check(ProcessTable.TtyCandidates(ttyTable).SequenceEqual(new[] { "/dev/pts/3" }), "tty lookup excludes its own command descendants");
Check(ProcessTable.TtyCandidates("banner only").Count == 0, "no tty guess from unframed output");
Check(!ProcessTable.IsDevice("/dev/pts/3;touch /tmp/bad"), "untrusted tty cannot become shell text");
Check(ProcessTable.CloseNote("TETHER-PROCESSES\n10 1 pts/3 S bash\nTETHER-PROCESSES-END", "/dev/pts/3") is null, "idle root shell closes quietly");
Check(ProcessTable.CloseNote("TETHER-PROCESSES\n10 1 pts/3 S bash\n11 10 ? S sleep\nTETHER-PROCESSES-END", "/dev/pts/3") == "Running: sleep", "background descendants require confirmation");
Check(ProcessTable.CloseNote("TETHER-PROCESSES\nbroken\nTETHER-PROCESSES-END", "/dev/pts/3") is not null, "incomplete process table cannot prove idle");
var temporary = Path.Combine(Path.GetTempPath(), "tether-history-test-" + Guid.NewGuid().ToString("N"));
try
{
    var store = new SessionHistoryStore(temporary);
    Check(store.Load().Count == 0, "new manifest starts empty");
    var open = new ClosedTerminal(Guid.NewGuid(), "Shell", "cmd", null, null, null, 0, null);
    var closed = Enumerable.Range(0, 25).Select(i => open with { Id = Guid.NewGuid(), Title = "Tab " + i }).ToArray();
    store.Save([open], closed);
    var saved = File.ReadAllText(Path.Combine(temporary, "tabs.json"));
    Check(!saved.Contains("Password") && !saved.Contains("PrivateKey"), "manifest contains no credential fields");
    var recovered = new SessionHistoryStore(temporary).Load();
    Check(recovered.Count == 20 && recovered[^1].Id == open.Id, "relaunch recovers open tabs and retains latest twenty");
    File.WriteAllText(Path.Combine(temporary, "tabs.json"), JsonSerializer.Serialize(new { Version = 1, Open = new[] { open }, Closed = Array.Empty<ClosedTerminal>() }));
    var legacy = new SessionHistoryStore(temporary).Load();
    Check(legacy.Count == 1 && legacy[0].Id == open.Id && legacy[0].Layout is null, "version one single-pane metadata migrates without reconnecting");
    var panes = new[] { open with { Id = firstPane }, open with { Id = secondPane, HostAlias = "lab", Target = "lab.example" }, open with { Id = thirdPane, WslDistribution = "Ubuntu" } };
    foreach (var pane in panes) Directory.CreateDirectory(Path.Combine(temporary, pane.Id.ToString()));
    var layoutStore = new SessionHistoryStore(temporary);
    layoutStore.Load();
    layoutStore.Save([open with { Layout = splitTree, Panes = panes, FocusedPane = secondPane }], []);
    var mixed = new SessionHistoryStore(temporary).Load().Single();
    Check(mixed.Layout == splitTree && mixed.FocusedPane == secondPane && mixed.Panes!.Select(p => p.Id).SequenceEqual(splitTree.Leaves), "mixed local SSH and WSL metadata restores with its focused pane");
    Check(panes.All(p => Directory.Exists(Path.Combine(temporary, p.Id.ToString()))), "all nested pane history archives are retained");
    File.WriteAllText(Path.Combine(temporary, "tabs.json"), "broken");
    var damaged = new SessionHistoryStore(temporary);
    Check(damaged.Load().Count == 0 && damaged.Problem is not null, "corruption is reported");
    damaged.Save([], []);
    Check(File.ReadAllText(Path.Combine(temporary, "tabs.json")) == "broken", "corrupt history is preserved");
}
finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
Console.WriteLine("PASS: shortcuts, paste policy, settings compatibility, Unicode selection, labels and exit states.");

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}
