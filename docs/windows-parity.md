# Windows parity with macOS

Baseline: `origin/master` at `e7c8cb6`, merged into `windows-app`.

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

## Remaining platform differences

- Apple's CloudKit/iCloud synchronization, Secure Enclave identity management,
  cross-device approval/pairing, and continuity have no Windows service
  implementation here. Windows identities and credential protection are local.
- Native Quick Look previews and macOS file-cache/tree performance behavior are
  not fully reproduced by Windows text/external-viewer previews.
- The upstream WebPluginHost package is not yet integrated into either desktop
  application; it is not represented as a working Windows feature.

Windows compilation and shared/native regression tests are exercised locally.
`dotnet run --project tests/windows-management` exercises structured config edits,
DPAPI storage, key generation, authentication confirmation, credential binding,
TOTP reference vectors and challenge routing. Add `-- --wsl` to exercise real
ConPTY terminals and tmux in WSL, including two simultaneous terminals, plus
authorized-key installation/revocation in an isolated temporary home directory.
macOS/Swift compilation and interactive Windows UI testing still require their
respective runtime environments. This change establishes common workflow parity,
but does not claim complete parity for the differences above.
