# One renderer, native hosts

Windows, macOS and iOS use `tether-render`: wgpu + cosmic-text + glyphon.
Windows keeps its existing backend selection policy (the measured path is
DX12); Apple presents through wgpu's Metal backend. This is one implementation
of terminal drawing, not three renderers sharing a GPU API.

```text
terminal state → ScreenFrame + palette + damage + pointer overlay
                          ↓ binding conversion
                   tether-render::draw_update
           cached row layout → shaping → atlas → GPU pass
                          ↓ native attachment
                  HWND                  CAMetalLayer
                 Windows               macOS / iOS
```

## Ownership and interfaces

- The terminal core owns VT state, damage and input encoding, with no UI/GPU
  dependencies. The render crate owns font measurement, layout, shaping,
  glyph caches, colours, selection, links, decorations and cursor pixels.
- Native views own input/IME, clipboard, accessibility, layout constraints,
  scheduling, visibility and DPI. Swift/C# convert contracts; they do not
  implement terminal shaders, glyph atlases or another grid painter.
- Existing `draw`/`draw_frame` APIs delegate to full updates. `draw_update`
  accepts optional damaged row indices: absent means full, empty means no
  row changes. A new surface still builds all rows. Geometry/font/palette
  changes invalidate caches; pointer/caret updates reuse unchanged text.
- Font size and render dimensions are physical pixels. Native geometry is
  returned to points/DIPs by dividing shared metrics by the same scale.
  Hit testing, terminal resize and IME use those metrics.
- `TerminalView` and legacy `TerminalDrawing` cases remain compatibility
  entry points. They all use wgpu. There is no Canvas/Metal setting or
  independent Swift terminal painter.

## Apple lifetime and threading

`from_metal_layer` synchronously captures a valid CAMetalLayer on the main
thread. Device initialization is a separate async operation. The native host
retains the view/layer until that operation has finished, including cancellation.
Native layer creation, geometry changes and destruction stay on the main actor;
draw/resize/font calls are serialized per surface.

Before detaching, stop scheduling, cancel pending initialization, and call
idempotent `close`. A cancelled initialization drops its result before releasing
the retained host. An epoch prevents completion from an old attachment from
changing a newly attached view. Reattachment waits for cancelled initialization
to finish before reusing the layer. Rust drains outstanding GPU work when closing.

Hidden, backgrounded and zero-sized views do not submit frames. Resume and scale
changes invalidate geometry and request a full frame. A failed surface is
recreated once; further failure reaches the existing dialog path with Retry.
There is no fallback to a second terminal implementation. A compositor skip — surface
timeout or occlusion — is not a presented frame. The host keeps its damage and draws
again; it does not acknowledge that frame.

## Fonts and packaging

The shared font catalogue parses system files and imported TTF/OTF/TTC bytes.
Imported faces have SHA256-content + collection-index identities and private
family aliases, so equal names cannot select the wrong file. System and file
faces publish their PostScript id as a family alias beside the public family,
so a stored face id selects that face. A face id that names one face is shaped with
that face for both a normal and a bold run. A family name that names several faces
still selects the bold face for a bold run. Invalid bytes, and a file that parses
no faces, do not change the catalogue. Scanning and measurement are cached;
renderer contexts refresh when the catalogue changes.

Apple's host discovers system files using CoreText, explicitly including the
system monospaced font. Virtual system faces without file URLs supply their
CoreText tables; fontations `write-fonts` assembles their OpenType containers. This is essential on iOS: fontdb 0.23 does not discover
its system fonts. CoreText supplies font resources, not an independent drawing
path. Zero-space-advance faces with incorrect monospaced metadata are normalized
before cosmic-text's monospace fallback scaling.

Each app stores imported copies under its own local application-support directory
and reloads them on launch. Selection and import are available in platform
settings; the files are not installed into the OS or synchronized to iCloud.
Windows keeps its existing Consolas / Microsoft YaHei UI defaults; Apple uses its
system monospaced face and PingFang fallback. Font changes update measurements
and all open terminal surfaces.

All three XCFramework slices enable the `render` feature. Swift and C# bindings
are generated from the same FFI metadata, including attachment methods that
return an unsupported-platform error outside their target OS. Consumers still
need no Rust toolchain. Headless Rust consumers may leave the feature disabled.

## Validation

Shared pure tests check damage, invalidation, clipping, cursor and pointer marks.
Offscreen GPU tests run the same render pass and read its RGBA pixels, including
first-frame empty damage, text changes, cursor removal, palette and size changes.
Native integration checks cover attachment and cancellation. Source checks reject
native glyph atlases, shader pipelines and independent terminal Canvas painters.

Hardware timing remains a short manual observation, not a CI threshold. Retain
CPU/GPU/font/scale/device provenance and compare against the previous release.
Mac/iPhone/iPad font quality, native lifecycle, memory and power require device
qualification; compilation and simulator results do not establish those claims.
See [ADR 0021](../Decisions/0021-renderer-unification-is-measurement-gated.md).
Build/test evidence and short macOS observations are recorded in the
[Apple implementation report](apple-renderer-evaluation.md).
