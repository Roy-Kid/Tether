# Tether — an embeddable SSH terminal platform

> The defining specification.
>
> Mirrored byte-for-byte in two repositories: **`Tether`** (where it governs the
> SDK and the app) and **`molab-apple`** (where it tells a consumer what it is
> consuming). Neither copy is a summary and neither is subordinate. Change them
> together, in the same change, or the project has two different north stars and
> does not know it.
>
> Supersedes the Swift-native specification of 2026-09-16 in full. What changed
> and why is in `Decisions/0002-rust-component-platform.md`.

---

# 1. What Tether is

Tether is a set of components an application imports to embed a working SSH
terminal.

The ecosystem already has excellent terminal *applications* (Ghostty, WezTerm,
Alacritty, Rio) and excellent terminal *engine crates* (`alacritty_terminal`,
`vte`). It does not have the layer between them: a componentised, embeddable,
customisable SSH terminal with a stable API, that an app developer drops in and
wires to their own UI.

That layer is Tether. Its value is **composition, boundaries and API** — not
engine internals.

Two products live in this repository:

- **the SDK** — the primary product;
- **the app** — a standalone terminal client, the first consumer of the SDK and
  the proof that its frontend contract is sufficient.

molab is another consumer. It must not influence the core architecture.

A consuming application should be able to embed a terminal, authenticate an SSH
session and style the result without understanding SSH, PTYs, escape sequences,
terminal state, GPU rendering or tmux.

---

# 2. Governing principle

Compose mature upstream components. Own the composition.

Writing a VT parser, a crypto stack or a font shaper ourselves would be slower,
less safe and less reliable than the implementations that already exist and are
exercised by millions of downloads. Every line we do not write is a line we do
not have to secure, fuzz and maintain.

What we own is the part nobody else has done: the boundaries between those
components, the lifecycle that binds them, the errors a consumer sees, and an
API that stays stable while the pieces underneath are replaced.

The system is:

```text
Tether components
        │
        │ stable, embeddable API
        ▼
Consuming applications
```

and never:

```text
Application
        │
        └── its own SSH / terminal implementation
```

---

# 3. Components

```text
tether-terminal    VT engine boundary: bytes → state → damage; input encoding
tether-ssh         transport, authentication, host trust, channels, shell
tether-core        session orchestration + the public API a consumer imports
tether-render      terminal state → GPU draw
tether-view/swift  SwiftUI / UIKit view + Swift bindings
tether-app/apple   the flagship application
```

Dependency direction is one-way and enforced by the build graph:

```text
tether-core   → { tether-terminal, tether-ssh }
tether-render → tether-terminal            (never tether-ssh)
tether-view   → { tether-render, tether-core }
tether-app    → tether-view
```

`tether-terminal` must never link an SSH symbol. That is not a convention — it
is how §8's byte-stream boundary is proved by the compiler rather than asserted
in a document. A consumer who wants to render a local terminal, a recording or
a serial port must be able to take `tether-terminal` and `tether-render`
without SSH coming along.

A consuming application imports **`tether-core`** and **`tether-view/swift`**.
Everything else is an implementation detail it may ignore.

---

# 4. Technology stack

Rust for everything the components are made of; platform-native bindings and
views on top.

| Role | Choice | Why it qualifies |
|---|---|---|
| Async runtime | `tokio` | tokio-rs org · 973M downloads |
| SSH | `russh` | warp-tech org · 7.0M · pure Rust, async, keyboard-interactive |
| Cryptography | `aws-lc-rs` (russh default) | aws org · 226M · `ring` is the fallback feature |
| Terminal engine | `alacritty_terminal` | alacritty org · 1.6M · carries `vte` (75M) |
| Swift bindings | `uniffi` | mozilla org · 12.5M · async fns and async callback interfaces |
| Errors | `thiserror` | 1.47B downloads |
| Logging | `tracing` | tokio-rs org · 852M |
| Serialisation | `serde` | serde-rs org · 1.40B |
| GPU | `wgpu` | gfx-rs org · 35.7M |
| Text shaping | `cosmic-text` | pop-os (System76) · 8.6M |
| GPU text | `glyphon`, or `parley` + `vello` | decided in Phase 4 by measurement |
| Property tests | `proptest` | proptest-rs org · 189M |
| Fuzzing | `cargo-fuzz` + `arbitrary` | rust-fuzz org · 161M |

`uniffi` is MPL-2.0 rather than MIT/Apache. That is file-level copyleft: linking
it into a closed or MIT-licensed application is unencumbered, and only changes
to MPL files themselves carry obligations. Recorded so nobody rediscovers it
during a license review.

Deferred, with the decision recorded when it is made: the GPU text stack
(Phase 4) and SFTP (Phase 6, `russh-sftp` is person-maintained and needs the §5
test applied at the time).

---

# 5. Dependency policy

Every dependency is judged on five criteria, and the judgement is written down:

1. **Governance** — an organisation with multiple maintainers is preferred. A
   personally-maintained project is acceptable **only when it is mainstream**;
   adoption at that scale is the real insurance, because a widely-used crate
   that is abandoned gets forked, and a niche one does not.
2. **Activity** — releases in recent history, not a repository last touched
   years ago.
3. **Adoption** — downloads and named consumers.
4. **No historical baggage** — the design is not contorted to keep faith with
   platforms or APIs we do not care about.
5. **Licence** — permissive, and any deviation recorded.

Two categories, and the distinction matters more than the list:

- **Infrastructure** provides a well-defined primitive. Use it freely.
- **Architectural** dictates how our own code must be shaped. Minimise these.

The question for every proposal is: *does this provide a mature primitive, or
are we outsourcing our architecture to it?* `russh` providing SSH is the former.
An SDK whose public API is `russh` types is the latter.

Rejected under this policy, with the reason on record: `sugarloaf` and `rio-vt`
(91k and 58k downloads, single-project, personally maintained) — capable, but
adopting them would tie our terminal's behaviour to another product's roadmap.

---

# 6. What we own, what we compose

We compose: SSH protocol, cryptography, VT parsing and terminal state, font
shaping, GPU submission, async runtime.

We own, and no dependency may dictate:

- the public API and its stability;
- component boundaries and dependency direction;
- session lifecycle and ownership;
- authentication orchestration, including interactive challenges;
- host-trust policy and its storage boundary;
- the byte-stream abstraction;
- the frontend contract and incremental damage;
- the error model;
- the concurrency model across the language boundary;
- configuration and theming;
- what "compatible" means, and the tests that prove it.

A component boundary exists to keep a dependency's types out of our public
surface — not to re-implement it. A wrapper that merely renames upstream is
complexity without payment, and §22 forbids it.

---

# 7. Layering

```text
A  bindings & runtime     uniffi scaffolding, the Tokio runtime, FFI seam
B  protocol components    tether-terminal, tether-ssh
C  session                tether-core — orchestration and the public API
D  presentation           tether-render, tether-view/swift
```

Layer A deals in implementation detail. Layer B speaks domain concepts, never
backend concepts. Layer C turns protocols into useful application behaviour.
Layer D is the only boundary a UI author needs to understand.

---

# 8. The boundaries that must not rot

Four seams carry the architecture. Each has an explicit contract and its own
tests.

**The byte stream.** Bidirectional, source-agnostic, with EOF, failure,
cancellation and backpressure.

```text
          incoming bytes
remote ──────────────────► consumer
remote ◄────────────────── producer
          outgoing bytes
```

An SSH interactive shell is one producer. tmux panes and recordings are others.
Terminal dimensions do **not** belong on the stream — they belong to the
interactive shell (§11), which keeps the stream usable by non-PTY producers.

**Backend confinement.** `russh` handles, error codes and connection semantics
stop inside `tether-ssh`. `alacritty_terminal` types stop inside
`tether-terminal`. Replacing either must not reach past its component.

**Host-trust storage.** The core owns the trust model and the decision rules;
persistence is a replaceable boundary the consumer supplies. The core ships an
in-memory implementation for tests and nothing more opinionated.

**The frontend contract.** Semantic state, incremental damage, and input events.
No UI toolkit type may appear in it. It must compile and be fully exercised with
no UI framework linked.

---

# 9. SSH

Responsibilities: transport, handshake, host-key retrieval, authentication
negotiation and authentication, channels, PTY allocation, interactive shell
start, terminal dimension propagation, command execution, EOF, shutdown, and
failure classification.

SSH must not know about terminal grids, colours, cursors, frontend controls,
tmux windows or tabs.

---

# 10. Authentication

A standalone domain subsystem supporting password, public key,
keyboard-interactive including multiple rounds and multiple simultaneous
prompts, user cancellation, timeout, and server-dependent negotiation.

Keyboard-interactive must remain generic. Never encode the assumption:

```text
keyboard-interactive == OTP
```

It may carry a password, an OTP, a token, a challenge/response, a factor
selection, or an institution's own wording. The protocol layer reports
challenges — text, echo flag, instruction, round. A higher layer decides how a
person answers them.

This is the reason `russh` was chosen over the alternatives available to a
Swift-native design, and it crosses the FFI seam upward (§13). It is the
hardest shape in the system and gets its own abstraction and its own tests with
a scripted responder, requiring no server.

---

# 11. Host trust and the interactive shell

Host identity verification is separate from user authentication. The model
represents at least: unknown, trusted, changed, rejected, persisted, revoked.
A changed host key fails closed by default; there is no trust-all mode.

After authentication a consumer works with an interactive shell, not a channel:

```text
remote PTY + remote shell + bidirectional byte stream + dimensions + lifecycle
```

Channel setup and PTY negotiation stay internal.

---

# 12. Terminal

`tether-terminal` wraps `alacritty_terminal` behind our own contract:

```text
byte stream → engine → screen state + incremental damage
semantic input → input encoding → byte stream
```

It is entirely headless and owns no widgets. What it adds over the upstream
crate is the damage contract, the input encoding surface, and the guarantee that
upstream types never reach a consumer.

Damage is part of the contract, not an optimisation: a small mutation must never
require a consumer to diff whole screens. The engine communicates cells changed,
rows changed, scroll, cursor, mode, title, and full invalidation. The exact
representation is an implementation decision.

Unicode is modelled properly. Bytes, scalars, graphemes, glyphs and cells are
five different things; combining sequences, wide characters, emoji sequences,
zero-width content and ambiguous widths all have to work.

Compatibility is driven by testing against real workloads — shells, editors,
pagers, monitoring TUIs, fuzzy finders, git interfaces, tmux, and streaming
agent interfaces — not by chasing historical completeness.

---

# 13. Bindings and concurrency across the language boundary

This is the seam a Rust core buys, and the one place where getting it wrong is
expensive.

`uniffi` generates the Swift surface. Rust `async fn` becomes Swift
`async`/`await`; Rust futures are driven by the **foreign** runtime, so Swift's
cooperative executor and a Rust event loop never fight. Errors cross as typed
Swift errors. Callback interfaces carry interaction *upward* — which is how
keyboard-interactive asks a person a question.

Requirements on the seam:

- cancellation propagates in both directions, including mid-authentication;
- timeouts are honoured on the Rust side and observable from Swift;
- remote output reaches a consumer as an async sequence, not a callback;
- a Tokio runtime's ownership and lifetime are explicit, not ambient;
- no dispatch queue, pthread, raw pointer, C callback or backend error number
  appears in the generated surface.

Two of those requirements the generated code does **not** meet on its own, and
neither is discoverable by reading the surface — both were measured in Phase 0
(Decision 0003):

- Swift's structured cancellation does not reach a Rust future. The generated
  `uniffiRustCallAsync` polls to completion and never consults
  `Task.isCancelled`, so a cancelled three-second call returned normally after
  3002ms. Cancellation is therefore **part of the Rust API** — an explicit
  token a caller can signal — and is not left to the binding layer.
- The generated file does not compile under Swift 6 strict concurrency.

Both are absorbed by a thin Swift façade that Tether owns: generated bindings
are an internal Swift 5 module, the façade is the Swift 6 surface a consumer
sees, and it ties `withTaskCancellationHandler` to the token so consumers still
write ordinary structured concurrency. Generated code is an implementation
detail of that façade, never the public surface. Any binding-level behaviour
claimed here is a claim to be measured from Swift, never inferred.

`aws-lc-rs` compiles native code; that it builds cleanly for Apple targets from
`cargo` alone, with no CMake in a consumer's path, is a Phase 0 gate.

---

# 14. Rendering and the frontend

Rendering is **not** in the core. The boundary is:

```text
tether-terminal → state + damage → tether-render → tether-view → application
```

`tether-render` is a component we publish, not an abstract contract with no
implementation — a consumer must not have to write a terminal renderer. But it
sits beside the core, never inside it, so that the same core serves a SwiftUI
view, a web view, a headless test and a renderer that does not exist yet.

The genuinely hard and genuinely generic parts — shaping, font fallback, emoji,
glyph atlases, GPU submission — are composed from `wgpu`, `cosmic-text` and a
GPU text layer chosen in Phase 4. What we write is the terminal-specific part:
grid layout, damage-driven partial redraw, cursor, selection, and the theming
surface that makes it customisable.

The specification deliberately does **not** decide the UI framework, application
architecture, visual design, window model, tabs, splits, settings interface or
animation strategy. Those are designed after the headless core is stable, so
that early UI decisions cannot constrain it.

The frontend contract:

```text
receives  screen state · incremental damage · cursor · selection ·
          title and mode changes · session state · interaction requests
sends     keys · text · pointer · scroll · paste · resize · focus ·
          answers to interaction requests
```

---

# 15. Headless-first

Before any production UI work, the complete core must operate headlessly:

```text
connect → authenticate → verify host → open shell → feed output →
inspect state → send input → resize → disconnect
```

with no GUI framework linked. This is a mandatory acceptance criterion, not an
aspiration.

---

# 16. Session system

`tether-core` orchestrates. It binds a remote byte stream to a terminal engine
and owns their shared lifecycle. It is also where reconnect, connection sharing,
suspend/resume, persistence, telemetry and recording belong later — never pushed
down into `tether-ssh` or `tether-terminal`.

The low-level SSH layer supports multiple channels over one authenticated
connection. Higher-level reuse — one authenticated connection, several logical
consumers, leases, warm-up — is introduced separately and re-derived for this
project's requirements rather than copied from any predecessor.

---

# 17. tmux

tmux must not block the first shell. Initially a person runs tmux inside the
remote shell like any other TUI.

Native integration comes later as its own component consuming the abstract byte
stream and producing pane streams that feed the *same* terminal engine:

```text
remote connection → tmux control protocol → tmux model → pane streams → terminal
```

It must never depend on `russh` directly. Whether the control-mode client is
written here or composed from an upstream crate is decided when it is built,
under §5.

---

# 18. Errors, logging, security

**Errors** belong to this project. Backend error numbers are diagnostic context,
never the public API. Failures are classified semantically: network, handshake,
host verification, authentication, shell/channel, timeout, cancellation, remote
disconnect, terminal protocol, tmux, internal.

**Logging** is `tracing`, structured and per-subsystem: transport, ssh,
authentication, host-trust, session, terminal, render. Passwords, key material,
authentication answers, token values and terminal contents are never logged.
Protocol-level tracing is opt-in.

**Security** defaults are conservative: strict host verification, no silent
acceptance of a changed key, no trust-all, careful handling of authentication
material, no secret logging, defensive parsing of everything remote, fuzzing of
every parser we own, and an explicit policy for terminal capabilities that can
touch the local environment. Remote terminal data is untrusted input.

---

# 19. Testing

| Layer | Mechanism |
|---|---|
| SSH integration | controlled OpenSSH, including a Linux container for the full authentication matrix |
| Terminal | recorded byte streams → asserted state; snapshot regressions |
| Boundaries | `tether-terminal` links no SSH symbol; the contract compiles with no UI framework |
| Bindings | the generated Swift surface exercised from Swift, including cancellation |
| Parsers | `cargo-fuzz` + `arbitrary` on everything that reads remote bytes |
| End-to-end | connect → shell → terminal → input → SSH, headless |

The SSH matrix covers password, public key, keyboard-interactive, multi-round,
multi-prompt, cancellation, unknown host, changed host key, timeout and
mid-session disconnect. Targeting Apple platforms does not constrain the test
server: it is a fixture, and a Linux container gives the full matrix.

---

# 20. Performance

Sensitive areas: network reads, the FFI boundary, VT parsing, screen mutation,
scrollback, Unicode, damage propagation, GPU submission.

Constraints: no per-byte task creation; no needless copying across FFI; no
whole-screen copies per update; bounded scrollback; coalesced high-frequency
updates. Optimise after profiling. Do not reach for unsafe or lock-free
structures without a measurement that demands it.

---

# 21. Build and distribution

Cargo is the source of truth. A Swift consumer experiences Tether as a Swift
package regardless of how the Rust below is produced.

Native artifacts are build outputs, not source dependencies: reproducible, built
by our CI from pinned sources. A consumer must not need Rust, CMake or a network
to build their app — how that is achieved (XCFramework, prebuilt binary target,
build plugin) is a Phase 0 decision recorded as an ADR.

---

# 22. Complexity budget

Every component, boundary and abstraction is paid for by a demonstrated need.

- Never add a layer because it may be useful later.
- Never wrap a dependency only to rename it.
- Never make something configurable merely because it could vary.
- Never introduce an extension point with no extension.
- A conscious exception is debt: record it, bound it, own it. An unrecorded one
  becomes architecture.

---

# 23. Phases

**Phase 0 — validate.** The binding seam end to end: an async Rust call reaching
Swift, a callback interface carrying an interactive prompt upward, cancellation
crossing in both directions, `aws-lc-rs` building for Apple targets from cargo
alone, and the artifact shape a Swift consumer sees. Decisions recorded as ADRs.

**Phase 1 — headless SSH shell.** Transport, host verification, all three
authentication families, PTY, interactive shell, read/write, resize, disconnect.
*Done when* a headless test logs into a server that **requires interactive
authentication**, holds a shell, resizes it and disconnects cleanly.

**Phase 2 — terminal.** `tether-terminal` over `alacritty_terminal`: the damage
contract, input encoding, and the compatibility corpus. *Done when* recorded
streams from §12's workloads produce asserted state and the fuzzers run clean.

**Phase 3 — composition.** `tether-core` binds shell and terminal behind the
public API. *Done when* the whole session works headlessly through that API and
through the generated Swift surface. The core is then ready for frontend work.

**Phase 4 — rendering and view.** `tether-render` and `tether-view/swift`. The
GPU text stack is chosen here, by measurement.

**Phase 5 — the app.** `tether-app/apple`.

**Phase 6 — extended.** tmux, file transfer, forwarding, jump hosts, pooling,
persistence. None is a prerequisite for the architecture.

---

# 24. Non-goals for early development

Frontend appearance, tabs, panes, animation, themes, GPU optimisation, settings
UI, tmux integration, SFTP, forwarding, cloud sync, team features.

The first product is the headless engine.

---

# 25. Agent responsibility

This specification fixes architecture, technology and boundaries. It
deliberately does not fix type names, API signatures, file layout, buffer
design, actor hierarchy, binding details, UI architecture or renderer
architecture.

Those are discovered through upstream documentation, source inspection,
prototypes, benchmarks and compatibility tests. Decisions that would be
expensive to reverse are justified in an ADR under `Decisions/`, never inherited
from a previous project.

---

# 26. Decision priorities

1. correctness
2. security
3. architectural separation
4. protocol compatibility
5. maintainability
6. performance
7. simplicity
8. implementation convenience

Avoid both extremes: binding the architecture to someone else's product, and
rewriting mature primitives for purity. Own the architecture. Reuse the
primitives.

---

# 27. Completion criterion

Tether succeeds when an unrelated application imports two components and obtains
a working, styleable SSH terminal without importing a UI framework to get there,
and without needing to understand:

```text
russh · aws-lc-rs · alacritty_terminal · wgpu · PTY negotiation ·
VT parsing · terminal buffers · the FFI seam · tmux protocol
```

At that point frontend development becomes an independent problem rather than
part of the remote-system architecture.
