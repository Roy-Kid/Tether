using System.Text.Json;
using Tether;
using TetherApp;
using Windows.System;

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
    File.WriteAllText(Path.Combine(temporary, "tabs.json"), "broken");
    var damaged = new SessionHistoryStore(temporary);
    Check(damaged.Load().Count == 0 && damaged.Problem is not null, "corruption is reported");
    damaged.Save([], []);
    Check(File.ReadAllText(Path.Combine(temporary, "tabs.json")) == "broken", "corrupt history is preserved");
}
finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
Console.WriteLine("PASS: shortcuts, paste policy, settings compatibility, Unicode selection and exit states.");

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}
