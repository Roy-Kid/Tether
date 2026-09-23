# 0010 — An OpenSSH ControlMaster is a connection we can lease

Status: accepted
Date: 2026-09-21
Phase: 3 (composition)

## Context

A person who uses SSH every day already has multiplexing written down:

```
Host Arrhenius
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 8h
```

`ssh Arrhenius` from a terminal creates a master. The next `ssh Arrhenius`
opens another session on that socket and is not asked for a key, a password
or a verification code — the handshake was spent getting the master.

Tether spoke russh, which has never heard of that socket. Opening the same
host from the app always started a new TCP connection and a new
keyboard-interactive exchange, so a person who was already on the machine
was asked for the one-time code again.

ControlMaster is not an SSH protocol feature. It is OpenSSH's own
multiplexing protocol on a Unix socket. russh cannot "reuse" another
process's session except by speaking that protocol, and speaking it
ourselves would be rewriting the client that already owns it.

## Decision

**When `ssh -O check <alias>` says a master is running, attach through the
OpenSSH client instead of dialling russh.**

The alias is the stanza name (`Arrhenius`), not the resolved hostname,
because that is the name `ssh` takes and the name the ControlPath was
keyed on.

The interactive shell is `ssh -tt <alias>` on a pseudo-terminal. A second
command — tmux listing, tmux control mode — is `ssh -T <alias> <command>`
on pipes. Both are the existing local producer and the existing
`Connection` lease; the far side is still "where this session's shell is
running". russh is not involved, and `tether-local` still links no SSH
symbol.

If the check fails, the russh handshake is unchanged. Tether does not
*become* a ControlMaster: creating one is OpenSSH's job, and a GUI that
tried would have to keep a master process alive for the rest of the
session on someone else's behalf.

## Consequences

A live master is a credential that has already been spent. The password
sheet and the interactive prompter are not shown.

`BatchMode=yes` is set on the attach, so a master that dies between the
check and the shell fails instead of prompting inside the terminal for a
password the person was not asked to give this app.

iOS has no `ssh` binary to exec and answers that no master is running.

The ssh config is still not parsed for `ControlMaster` / `ControlPath`.
`ssh -O check` is the authority, including `%C` expansion, `Host *`
inheritance and whichever OpenSSH the person actually used to open the
master.

`%C` is SHA1 of the local hostname plus the remote tuple. A laptop that
picks up a new FQDN looks for a different socket than the master still
running from this morning. When the default check misses, sibling
sockets hashed under other local names this machine has used are tried
with an explicit `ControlPath`, so the person is not asked for a
verification code they already spent.
