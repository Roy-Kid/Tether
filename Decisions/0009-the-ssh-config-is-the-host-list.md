# 0009 — `~/.ssh/config` is the host list

Status: accepted
Date: 2026-09-18
Phase: 3 (composition)

## Context

The app kept its hosts in `hosts.json`, in Application Support. Everybody who
uses this app already has the same machines written down in `~/.ssh/config`,
where `ssh`, `scp`, `rsync`, `git` and their editor all read them. So adding a
host meant typing an address that was already on disk, and the two lists then
drifted: a port changed in one place kept working everywhere except here.

A second list of the same facts is a cache, and a cache with no invalidation is
a bug waiting for the day someone moves a server.

## Decision

**`~/.ssh/config` is the store. There is no other one.**

Hosts are read from it, and a host added or edited in the app is a stanza added
or edited in that file. `hosts.json` is no longer written or read.

**The file is edited, not regenerated.** Almost none of a person's config is
ours: `ControlMaster`, `ForwardAgent`, `ProxyJump`, a comment reminding them
which machine is which. Parsing it into a model and writing the model back
would delete all of it. So what is parsed is an *index into the lines*, and an
edit rewrites only the lines it owns — `HostName`, `User`, `Port`,
`IdentityFile` — in place, with their indentation. Everything else survives
because it was never touched.

**ssh's own resolution rules, not an approximation of them.** A setting comes
from the first stanza that matches, wildcards included, which is why a `User`
under `Host *` is the user this app offers — the same one `ssh` would use.
Reading it any other way would show a person a host that behaves differently
here than at their prompt.

**A host's identity is its name.** There is nowhere in an ssh config to keep a
generated identifier, and inventing one per read would hand the keychain a
different host every launch. So the id is a name-based UUID derived from the
stanza's name. Renaming a host is therefore a new identity, and the saved
password is moved to it: a person who renamed a machine did not ask to be asked
for its password again.

## Consequences

**Nothing is written while the file cannot be read.** A config that fails to
decode is left exactly as it is and the failure is shown in the sidebar. The
alternative — starting from an empty file — would mean the next host added
replaces the person's entire ssh configuration, and there is no other copy of
it.

**A key path is stored the way it was written.** `~/.ssh/id_ed25519` survives
the account being moved and the file being copied to another machine, which is
a thing people do with this file. Reading it, expanding it and writing it back
would quietly replace it with a path that does neither; expanding happens at
the moment the key is opened, and a path chosen in a file picker is contracted
back to `~` on the way in.

**An inherited setting is not copied into the host.** If a stanza has no `User`
and `Host *` supplies one, editing the host does not write that user into its
stanza — editing `Host *` afterwards would then silently stop reaching it.

**A name with a space in it is quoted.** "Lab machine" is an ordinary thing to
call a computer and two patterns to `ssh` unless it is written `Host "Lab
machine"`.

**The file is re-read when the app comes back to the front.** The list belongs
to the person, and they may well have added a stanza in an editor while this
was in the background.

**`Host` is no longer `Codable`.** Nothing encodes it any more, and the custom
decoder that existed to survive `hosts.json` gaining a field went with it.

**The local machine is still not in the file.** `ssh localhost` is a real thing
that means something else, and a stanza claiming otherwise would be this app
answering a question nobody asked it. It remains a synthesised row, recognised
by a fixed identifier.

## Not decided here

**Migration from `hosts.json`.** Existing entries are not copied into
`~/.ssh/config`. Writing to a person's ssh config on their behalf, at launch,
without being asked, is not something to do quietly — and the file is still on
disk, so nothing is lost while this is decided.

**The sandbox.** A Mac App Store build cannot reach `~/.ssh` without a
user-granted bookmark, and an iOS build has no `~/.ssh` at all. The store
reports what it cannot read rather than pretending, which is the honest
behaviour but not yet the whole answer.
