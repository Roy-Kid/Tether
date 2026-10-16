# 0019 — ProxyJump is a forwarded handshake

Status: accepted
Date: 2026-09-26
Phase: 6 (extended — jump hosts)

## Context

`~/.ssh/config` is the host list (Decisions/0009). A stanza's `ProxyJump`
is part of what that name means to `ssh`: the destination is reached by
logging into another machine first and opening a `direct-tcpip` channel
from there. Preserving the line and then dialling the destination directly
makes the same name behave differently here than at a prompt.

`Connection::connect_over` already existed for a transport that is not a
TCP socket. A jump host's forwarded channel is that case. What was missing
is opening the channel, keeping the hop alive, and authenticating it with
its own credentials.

## Decision

**Each hop is its own login, then a `direct-tcpip` channel to the next.**

- `tether-ssh` opens the channel on an authenticated session and runs the
  next handshake on it (`Connection::connect_through`). The hop session is
  stored on the connection it produced. Dropping the destination drops the
  hops, which is what closes the forwards.
- `tether-core::Dial::through` walks the chain. A hop's credentials are not
  the destination's: a password typed for the far machine is not offered to
  a bastion. A hop's failure names the hop.
- The host key of every hop is verified before that hop is given a
  credential, by the same verifier, against that hop's endpoint.
- The apps resolve `ProxyJump` out of `~/.ssh/config` the way OpenSSH does,
  and hand the chain in. The SDK does not read the file (0009: the file is
  the app's store).
- Resolution: first matching value wins, `none` means no jump, a comma
  separates hops, `[user@]host[:port]` and `[ipv6]:port` are the token
  forms, and a hop's own `ProxyJump` is visited first. A cycle in that
  recursion is an error. `Host *` supplies a jump the same way it supplies
  `User` and `IdentityFile`.
- Windows reads `Host *` with those same rules. It previously took each
  stanza's own keys only, so a wildcard user or key was a different login
  from `ssh`.

A live OpenSSH ControlMaster is unchanged. `ssh` already honours
`ProxyJump`; attaching to the master does not dial again (Decisions/0010).

## What this does not decide

`ProxyCommand`, agent forwarding, and `-L`/`-R` port forwards. A jump is
one channel to one host. Those are different requests, and none of them is
required for a config name to mean what `ssh` means.
