# Performance and UI review — 2026-10-05

Scope: terminal Metal rendering, asynchronous file-tree expansion, and existing
native chrome. The tab/host bar heights, gutters, layout, typography and palette
remain unchanged.

## Findings and changes

- Metal assembled all row vertices and allocated a new buffer for every draw,
  including cursor-only updates. The screen buffer is now immutable and reused
  until row geometry changes; the cursor uses its own six inline vertices.
  Changed text, grid size, palette, metrics, backing scale and atlas resets still
  invalidate geometry. Keeping buffers immutable also permits commands already
  submitted to finish safely.
- Folder expansion could issue duplicate listings and apply results after
  collapse, navigation, reconnection or closing the browser. Per-folder request
  identities coalesce repeated expansion and discard obsolete results/errors.
  An earlier request cannot clear a newer request's loading indicator.
- Folder disclosure now uses a native button with a named folder and an explicit
  loading/expanded/collapsed accessibility value, in the same bounds. File-loading
  indicators have a spoken label. The tab selection button exposes selection;
  sync exposes its current state and honors Reduce Motion.
- iOS compilation exposed an existing ambiguous wheel selector (the callback
  and counter share a name). Specifying `wheeled(_:)` restores compilation
  without changing gesture behavior.

## Verification

Regression coverage includes collapse/reopen/close during listing, duplicate
expansion, and offscreen Metal pixel comparisons across cursor, row, palette and
empty-grid updates. Results:

- Frontend: 55 tests passed, including offscreen Metal regression coverage.
- Files plugin: 77 tests passed, including four new asynchronous-tree regressions.
- App: 253 tests passed.
- macOS app packaging passed (`build/Tether.app`).
- arm64 iOS Simulator compilation passed. Follow-up fixes explicitly isolate the
  dialog presentation on the main actor and use trait-change registration for
  keyboard Dynamic Type changes. Related closure/conformance warnings were also
  resolved; follow-up validation is recorded below.
- Changed-file whitespace checks passed.
- FFI artifacts were rebuilt to match the existing bindings; generated Swift
  bindings are byte-for-byte identical to their pre-review contents.

No frame-rate, CPU or power measurement is claimed. No comprehensive VoiceOver,
physical-device or pixel-level application-layout acceptance is claimed.

The supplied AGENTS.md references RTK.md; that file was not found in the workspace
or its ancestor instruction locations.

## Warning cleanup follow-up — 2026-10-05

- `Presentation` is explicitly `@MainActor`, including window teardown and
  restoration of the previous key window.
- The keyboard bar registers for preferred-content-size-category changes instead
  of overriding the deprecated `traitCollectionDidChange`; initial styling and
  subsequent size invalidation are retained.
- Authentication tasks use explicit weak capture in the outer and inner closures.
  File conflict actions explicitly return `Void`; iOS Quick Look drops an
  ineffective `@preconcurrency` annotation. Imported passwords use immutable
  bindings; the existing dynamic Objective-C selector uses its explicit string API.
- Rerun results: frontend 55, Files 77 and App 253 tests passed (385 total).
- arm64 iOS Simulator build passed with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`;
  the build log contains no compiler warnings or errors. macOS app packaging
  passed again. Changed-file whitespace checks passed.
