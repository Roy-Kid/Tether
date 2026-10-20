# Windows parity with macOS

Baseline: `origin/master` at `e7c8cb6`, merged into `windows-app`.

## October 15 update

Compared against `origin/master` at `5d2cb9d`. The latest shared Rust SDK and
regressions are ported onto `windows-app`; this is a selective port rather than
a merge of the divergent Apple workspace implementation. Existing native split
layouts, mixed-host restoration and deferred plugin state remain in place.

- **Ports:** a built-in inspector scans every three seconds, discovers up to 64
  development listeners, forwards remote ports through the existing authenticated
  SSH/OpenSSH lease, and offers browser, copy-address and stop actions. Automatic
  forwarding defaults on, can be disabled, and supports an ignored-port list.
  Listeners bind only to IPv4 loopback, try the next available port on conflict,
  and close when their port disappears, the connection ends or the attachment
  is disposed. Native local listeners already run on this machine. WSL rows open
  Windows loopback addresses through the system's WSL localhost relay; enabling
  that relay is a WSL networking preference, not a tunnel created by Tether.
- **Files:** Edit Text opens remote UTF-8 files up to 2 MiB in a native editor.
  Saving checks the downloaded size and modification timestamp, retains remote
  permissions and writes a completed temporary file into place. Conflicts keep
  the text available for editing or Save Copy. Unchanged content keeps its exact
  bytes; edited content retains UTF-8 BOM and the original newline convention.
  Local and WSL files continue to use the registered external editor in place.
- **Shared core:** synchronized terminal damage, cell width, link geometry,
  history and PTY creation fixes from the current mainline. The Windows jump-host
  chain, per-target cryptography and mouse-wheel encoding are retained. Both
  language bindings are regenerated for the extended file and forwarding API.

This update does not port Apple's Credential Exchange UI, iCloud secret sync,
or the newer Apple web-plugin ribbon/install lifecycle. Windows' web-panel
preview keeps the capabilities and differences described below. Remote text
editing uses explicit Save; watching an external remote editor and drag-out
file promises remain Apple-specific.

Validation uses `python scripts/check.py` (Rust format/Clippy/build/tests,
native bindings, WinUI build, Windows regression executables, .NET suites and
single-file portable publish). `dotnet run --project tests/windows-management
-- --wsl` also covers the port scan against a real WSL process with an isolated
socket-table fixture.

Windows now provides configurable workspace and plugin shortcuts, a searchable
command palette and quick switcher, horizontal or vertical tabs, zen mode,
tab renaming, and restoration of closed tabs and previous-launch tabs. Terminal
history uses the shared SQLite archive with configurable retention. Restoration
uses current SSH configuration and refuses changed or removed destinations.

The Windows SDK now exposes session history, encrypted-key passphrase prompts,
skipped-key diagnostics, terminal mouse reporting, working directory and terminal
identity, bounded command execution, and tmux session management. The Windows
tmux inspector supports remote sessions, windows, split panes, zoom, and detach;
its commands participate in the shared command palette and shortcut settings.

Identity management now supports named account identities, default SSH keys,
imported or generated Ed25519 keys, saved passwords, TOTP (SHA1/SHA256/SHA512),
and automatic/before-authentication/every-connection confirmation. Credentials
are encrypted with current-user Windows DPAPI, in a directory accessible only
to that account. Saved OTPs answer only an exact configured non-echo challenge;
retry and other challenges use the generic prompt. Host bindings include the
endpoint, username and jump route, so an external configuration change cannot
silently redirect a saved credential. Managed identities use a fresh SDK login
instead of reusing an OpenSSH master authenticated with another identity.

Manage Hosts provides structured address, label, port, username, identity, key
file, jump route and timeout fields, plus add/edit/delete/import. Editing a
shared Host stanza preserves other aliases, comments and unknown directives;
the save rejects concurrent external edits. Import materializes inherited
settings and anchors relative key paths to the source file. Include files must
be imported directly. Unsupported connection directives are preserved and
reported rather than silently ignored.

Remote Authorization prepares public-key requests for administrators, or installs
and revokes an owned `authorized_keys` entry over an existing connection to the
exact host. Ownership is saved before writing. A cooperative lock, same-directory
temporary file, concurrent-change check and symlink refusal protect unrelated
server entries. Installation remains pending on a lost connection and can be
retried; successful installation still requires a login to verify the key.

The tmux inspector also works in local WSL terminals. Startup preferences select
a distribution; tabs and restoration retain that concrete distribution even
when the system default changes. Each terminal records its own Linux tty and
process identity. Background tmux operations use bounded, cancellable execution
in the same distribution. Create/list/attach/switch/windows/split/zoom/rename/
detach/end share the remote tmux interface. The Files inspector is pinned to that
same distribution.

Closing tabs or the window checks shell activity. File browsing adds bounded text
previews, large-download confirmation, and download-directory preferences. Binary
previews use the operating system's registered viewer. ConPTY exit now releases
the master handle so the final output drains and history checkpoints complete.

## UI chrome and settings alignment

Windows status chrome again exposes split left/right, split top/bottom and
maximize/restore beside plugin inspectors, matching the macOS host status bar.
A title-bar tab-bar toggle mirrors `TabBarToggle`. Middle-click closes a tab.
Quick Switch lists up to five recent hosts when the query is empty; the host
picker groups currently connected hosts above idle ones. Startup settings offer
the same last-tab stay-or-quit choice as macOS General. A Security page lists
trusted `known_hosts` entries with Forget, and password identities with Delete.
Key Bindings now expose primary and secondary chords per command (Command Palette
defaults to one chord, ⌘⇧O). Web plugins install,
update and uninstall from Settings → Extensions; a panel can open as an
inspector beside a terminal or as a full workspace tab in the tab strip.

## Remaining platform differences

- Apple's CloudKit/iCloud synchronization, Secure Enclave identity management,
  cross-device approval/pairing, and continuity have no Windows service
  implementation here. Windows identities and credential protection are local.
- Native Quick Look previews and macOS file-cache/tree performance behavior are
  not fully reproduced by Windows text/external-viewer previews.
- Windows loads API 1 web panels dynamically through WebView2, with package
  validation, exact-origin read-only network access, SSE subscriptions,
  enable/disable lifecycle, Settings install/update/uninstall, full-page
  extension tabs, viewer routing by file suffix (Files → Allow → grant →
  `document.read`), and `storage.plugin` / `host.notify`. Nerve's independent
  web package is installed and exercised against the live hub. Apple's
  WebPluginHost still has no application window integration.

Windows compilation and shared/native regression tests are exercised locally.
`dotnet run --project tests/windows-management` exercises structured config edits,
DPAPI storage, key generation, authentication confirmation, credential binding,
TOTP reference vectors and challenge routing. Add `-- --wsl` to exercise real
ConPTY terminals and tmux in WSL, including two simultaneous terminals, plus
authorized-key installation/revocation in an isolated temporary home directory.
macOS/Swift compilation and interactive Windows UI testing still require their
respective runtime environments. This change establishes common workflow parity,
but does not claim complete parity for the differences above.
