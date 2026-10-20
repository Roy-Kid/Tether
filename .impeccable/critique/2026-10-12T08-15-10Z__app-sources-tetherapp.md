---
target: main workspace (app/Sources/TetherApp)
total_score: 21
max_score: 40
na_heuristics:
p0_count: 1
p1_count: 3
target_identity: "file:/Users/roykid/work/Tether/app/Sources/TetherApp"
timestamp: 2026-10-12T08-15-10Z
slug: app-sources-tetherapp
closed: true
---
Method: dual-agent (A: design review · B: detector). Native target; Mac workspace window not capturable (off-screen), no iOS simulator booted; review from source + final mockups. Detector: 0 findings across 109 Swift files — coverage gap (web syntax only), not a clean bill.

## Design Health Score
| # | Heuristic | Score | Key Issue |
|---|---|---|---|
| 1 | Visibility of System Status | 2 | Same grey dot for connecting/failed/ended (WorkspaceChrome.swift:509-517); no connection status on iOS |
| 2 | Match System / Real World | 2 | Tab / Terminal / Shell / Workspace collide (⌘T vs ⌘N, ⌘W vs ⌘⇧W) |
| 3 | User Control and Freedom | 2 | Esc on "Connection Lost" closes the tab (ConnectionDialogs.swift:43) |
| 4 | Consistency and Standards | 2 | Red traffic light minimises; two delete paths differ; tmux command casing differs |
| 5 | Error Prevention | 2 | Sidebar Delete host unconfirmed (Sidebar.swift:77); close dialog Enter = Close |
| 6 | Recognition Rather Than Recall | 2 | Tabs don't show host/session; no tab chevron (spec §1) |
| 7 | Flexibility and Efficiency | 3 | ⌘P, ⌃⇧P, quick-select, rebindable keys; iOS commands flat |
| 8 | Aesthetic and Minimalist Design | 3 | Silent Mac chrome well executed; iOS stacks nav+tab bar+accessory |
| 9 | Error Recovery | 2 | Dialogs name host + Reconnect, but drop wipes screen |
| 10 | Help and Documentation | 1 | No Help → Keyboard Shortcuts |
| Total | | 21/40 | Acceptable |

## Design Specificity Verdict
Half authored. Mac shell specific (tongue tab in terminal palette, bottom-left host bar, status ribbon, in-place tmux picker). Rest category-interchangeable: "Tab 1/Tab 2" titles, "N terminals" subtitle, host colours never on strip, stock iOS List/NavigationStack/TabView. tmux — the headline claim — invisible on the strip.

## Priority Issues
- [P0] Dropped connection erases screen and interrupts from any tab — SessionModel.swift:467-470 sets session=nil; SessionView.swift:33-39 draws EmptyView; TabSet.problem (TabSet.swift:331-335) picks any tab. Fix: keep last frame read-only/dimmed, mark tab + dot, dialog only for selected tab. /impeccable harden
- [P1] Destructive actions one keystroke away — Sidebar.swift:77 unconfirmed delete (syncs, removes keys); close dialog Enter=Close (WorkspaceView.swift:713-717, spec §6 says default Cancel); Esc on Connection Lost closes tab. Fix: shared confirmation, Cancel default, "Not Now" cancel. /impeccable harden
- [P1] Tabs carry no identity — "Tab 1" + "N terminals"; no host colour, no session/window subtitle, no chevron. /impeccable clarify + colorize
- [P1] iOS lacks connection status and authored navigation — no live dot (Sidebar.swift:38-58), TabView of identical icons (WorkspaceView.swift:487-503), 15-item flat Commands menu. /impeccable adapt
- [P2] Status hierarchy and trust question — failed reads as idle; trust dialog "Unrecognised host" + bare fingerprint (HandshakeQuestion.swift:28). Fix: warning colour for failed; "Trust ‹host›?" with key type. /impeccable polish

## Persona Red Flags
- Alex: ⌘\ is app split not tmux split; tmux under Plugins ▸ tmux; ⌘W stalls up to 2s on remote ps; red light never closes.
- Sam: terminal is one "Terminal" element with no value (TerminalSurface.swift:135); unselected tab close buttons hidden from AX; Mac chrome text fixed 10–12pt.
- Casey: nav bar + tab bar + key accessory stack; "Shell" icon reads as new; no | ~ / - keys.
- Researcher on iPhone: blip → output vanishes + modal; no persistent attached signal; prefix needs latched Ctrl.

## Minor Observations
- Tab height: law/spec 36pt, code 32pt (Design.swift:35) with valid traffic-light reason; amend law.
- Empty-label hosts share a colour. HostEditor.swift:101 "Stored on this device" vs keys sync. Sentence dialog titles. KeyBindingSettings.swift:75 tutorial. TabSet.statusLine() dead. Spec §4 "tmux" menu conflicts with "app names no plugin".

## Questions to Consider
- Should a tmux-attached tab look different on the strip?
- Does "no sentences" forbid data (hostname under tab name)?
- Dropped connection: event (modal) or state (frozen tinted screen + Reconnect icon)?
