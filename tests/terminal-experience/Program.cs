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
Console.WriteLine("PASS: shortcuts, paste policy, settings compatibility, Unicode selection and exit states.");

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}
