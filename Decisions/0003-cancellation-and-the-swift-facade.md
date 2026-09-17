# 0003 — Cancellation is part of the Rust API, behind a façade we own

Status: accepted
Date: 2026-09-17
Phase: 0 (bindings gate)

## Context

Spec §13 requires that cancellation propagate in both directions, including
mid-authentication. That requirement is not decorative: dismissing an OTP
prompt is an ordinary user action, and a keyboard-interactive exchange that
cannot be abandoned holds a live SSH channel open against the person's wishes.

UniFFI's Swift bindings present Rust `async fn` as Swift `async`, which makes it
look as though Swift's structured concurrency already spans the seam. It does
not. Measured, not assumed:

    let task = Task { try await probeDelay(millis: 3000, budgetMillis: 10_000) }
    task.cancel()
    // returned "waited 3000ms" after 3002ms — cancellation was ignored

The cause is in the generated `uniffiRustCallAsync`: it polls the Rust future in
a `repeat`/`while` over `withUnsafeContinuation`, never checks
`Task.isCancelled`, and never calls the `ffi_tether_ffi_rust_future_cancel_*`
entry point that UniFFI itself exports. The ABI for cancellation exists; the
Swift side does not use it.

A second, independent problem surfaced in the same gate: the generated file does
not compile under `-swift-version 6` (`sending` closure diagnostics in the
callback-interface vtable). Our deployment targets are iOS 26 / macOS 26 with
Swift 6.4, so this is not a future concern.

## Decision

**Cancellation is modelled explicitly in the Rust API.** A `CancellationToken`
object — wrapping `tokio_util::sync::CancellationToken`, not one we wrote —
crosses the boundary, and long-running operations select on it. What can be
cancelled is visible in the signature rather than assumed from the calling
convention.

**Consumers never see generated code.** Generated bindings are an internal
module compiled in Swift 5 language mode; the public surface is a thin Swift
façade Tether owns, compiled in Swift 6 mode. The façade ties
`withTaskCancellationHandler` to the token, so a consumer writes ordinary
`Task`/`await` and cancellation works.

This keeps the promise the spec makes to consumers while placing the knowledge
of *why* it takes work in exactly one place — §8's boundary rule, applied to the
binding generator itself.

## Consequences

- Every cancellable Rust entry point takes `Option<Arc<CancellationToken>>`.
  `None` means the caller has no way to cancel, which is a legitimate choice for
  short operations and an explicit one.
- The façade is not optional and not cosmetic. It is where the Swift 5/6 split
  lives; removing it re-exposes both defects at once.
- Binding-level behaviour is verified from Swift, not inferred from the Rust
  side. The Phase 0 probe asserts cancellation *with timing* — an untimed check
  would have passed against the broken build, because the call did return, just
  three seconds late.
- Should a later UniFFI wire `Task` cancellation to the existing cancel ABI, the
  token stays. It is a better public contract than an invisible one, and the
  façade would simply have less to do.

## Evidence

- `crates/tether-ffi/src/lib.rs` — token, and four Rust tests covering
  interruption, timeout-is-not-cancellation, absent token, pre-cancelled token.
- Phase 0 Swift probe, 9/9 under `-swift-version 6`, including
  `Task.cancel() reaches the Rust future in 54ms` (was 3002ms) and
  `pre-cancelled task short-circuits before Rust`.
