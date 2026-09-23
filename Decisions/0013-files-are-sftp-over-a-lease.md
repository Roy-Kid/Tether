# 0013 — Files are SFTP over a lease

Status: accepted
Date: 2026-09-23
Phase: 6 (extended — file transfer)

## Context

A person running an agent on a cluster wants to see what it made: a plot, a
PDF, a log. Today the only way is `scp` from another terminal, which is the
app failing at the one thing it is for — being where the files are.

The spec deferred SFTP to Phase 6 and said `russh-sftp` "is person-maintained
and needs the §5 test applied at the time" (§4). tmux, also Phase 6, has
shipped, and file viewing is the next thing asked for. This is that time.

There were three ways to reach files:

1. **Commands on the existing lease** — `ls`, `stat`, `cat` through
   `Connection::capture`. No new dependency.
2. **SFTP on a new channel**, composed from `russh-sftp`.
3. **Something bespoke** — a helper uploaded to the far side.

The first looks cheapest and is not. `capture` holds the whole answer in
memory under a limit (1 MiB for tmux queries), so a 40 MB image either fails
or needs a streaming path of its own. `ls` output differs between GNU,
BSD and busybox, and would be a new parser over remote bytes (§18). `stat`'s
flags differ again. Names with newlines break line-oriented output. Every
one of those is a problem SFTP already solved, in a protocol `sshd` offers on
essentially every host that has a shell. The third is out of the question
for a terminal that runs on someone else's machine.

## Decision

**SFTP, composed from `russh-sftp`, spoken over the lease.**

### `russh-sftp` under §5

1. **Governance** — maintained by one person (AspectUnk). Acceptable only
   because it is mainstream (below): a widely used crate that is abandoned
   gets forked; a niche one does not.
2. **Activity** — 3.0.0 released 2026-09; steady releases before it.
3. **Adoption** — about 3.2 million downloads, 1.4 million recent; it is the
   SFTP client the russh ecosystem uses.
4. **No historical baggage** — protocol version 3 (what OpenSSH speaks) plus
   the `@openssh.com` extensions, and nothing else.
5. **Licence** — Apache-2.0.

**Infrastructure, not architecture.** It provides a protocol over any
`AsyncRead + AsyncWrite`; `russh` is only its dev-dependency. Its types stop
inside `tether-files`, which exposes `Entry`, `Kind` and an `Error` of its
own. Replacing it would change one crate.

### Where the bytes go

`Connection::sftp()` opens the channel, one arm per way of reaching a
machine, as `open` does for a command (0008):

| Arm | Channel |
|---|---|
| `Remote` (russh) | the `sftp` **subsystem** on the authenticated session |
| `OpenSsh` (ControlMaster, 0010) | `ssh -T -s -- <alias> sftp` on pipes |
| `Local` | this machine's `sftp-server`, started directly |

A subsystem, not `exec sftp-server`: the far side's `sshd` chooses the
program, so its path is not our guess, and no login shell runs — a banner a
profile script prints cannot land in the middle of the protocol.

The local arm is not a special case with `std::fs` behind it. It runs the
server OpenSSH installs (`/usr/libexec/sftp-server` on macOS) and speaks the
same protocol through the same client, for the reason 0008 gave for tmux:
the second path would be the one nobody tested.

`tether-files` defines its own `Transport` — an ordered duplex byte stream —
and links neither `tether-core` nor `tether-ssh`. The FFI adapts `Channel`
to it, as it does for tmux.

### What it does

Read and write: list, stat and lstat, download and upload with progress and
cancellation, make a directory, rename, remove, remove a tree.

- **A transfer is whole or absent.** Both directions write a hidden working
  file beside the destination and rename it into place when complete.
  Cancelled or failed, the working file is removed and the destination is
  as it was.
- **Nothing is replaced unless asked**, and a directory never is.
  SFTP version 3 has no atomic replace, so a replacement is a removal and a
  rename; a failure between the two leaves the source where it was.
- **A tree is removed without following links.** The walk uses `lstat`
  semantics; a link inside the tree is removed as a link. A tree cannot
  reach outside itself.
- **Errors are ours** (§18): `NotFound`, `Exists`, `PermissionDenied`,
  `NotEmpty`, `Cancelled`, `Disconnected`, `Failed`. Version 3 reports
  "exists" and "not empty" as a bare `Failure`; those two are decided by
  asking the server what is there, never by reading its message.

## Consequences

- `tether-files` is a new crate, paid for by the file browser that uses it.
  `cargo tree -p tether-local` and `cargo tree -p tether-terminal` are
  unchanged.
- The tests run a real `sftp-server` on pipes: no host, no key, no network.
  CI installs OpenSSH's server package and sets `TETHER_REQUIRE_SFTP`, so a
  missing server fails the build rather than skipping it.
- iOS has no local shell, and so no local files; a remote session's files
  work there as anywhere.
- **Not done:** editing a file in place and writing it back, permissions and
  ownership, remote-to-remote copy (SFTP has no copy primitive), and a File
  Provider extension that would show hosts in Finder and Files. The last
  needs an app-extension target and its own connection outside the app's
  process — its own decision, with this crate as its core.
