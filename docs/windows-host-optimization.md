# Windows host scheduling and allocation observations

The shared Rust renderer and its public contracts are unchanged by this pass.
Windows continues to use the same native-material/transparent-terminal composition
as macOS. Top tabs, control placement and layout measurements remain unchanged.

Changes address concrete work in the native host:

- TerminalControl caches its rendered palette and skips unchanged palette/style
  requests. Resolving an already-resolved palette returns the same object. System
  appearance reads and palette cloning are outside the per-frame path.
- Named frame handlers unsubscribe on rebind and dispose, preventing old models
  from retaining controls or scheduling redraws for a replacement model.
- Native appearance messages and workspace state notifications keep at most one
  pending UI refresh. Window closure detaches subscriptions and suppresses queued
  callbacks. Appearance broadcasting remains a Win32 desktop adapter.
- Workspace background brushes and split-focus brushes are reused. The titlebar
  is reattached only when the actual drag target changes.

## Reproduction and limits

```powershell
dotnet run --project tests/terminal-experience -c Release -- --measure-appearance
dotnet build tests/windows-layout -c Debug -p:Platform=x64 -warnaserror
# Run the resulting WindowsLayout.exe --check for non-activating functional checks.
```

The optional CPU microbenchmark reports five observations of 250,000 palette
operations. Its baseline reproduces the previous per-draw record clone; its reuse
case measures steady-state resolved-palette reuse. It does not measure the full
TerminalControl draw loop, FFI, shaping, GPU execution or presentation latency.
No runtime or allocation percentage is a CI performance threshold.

Observed on the local Windows/.NET 10 host on 2026-10-20: baseline allocations
were 20,000,000 bytes per sample, versus zero for reuse. Baseline elapsed times
were approximately 3.56–8.24 ms, versus 0.89–1.09 ms for reuse. These very small
samples are informational and are not an application FPS claim. Raw JSON is
written locally to `app-win/bin/appearance-cost.json`.

The standalone layout fixture links the production XAML, resources and native
appearance observer without opening a shell or loading user settings. A burst of
100 native setting messages produced one refresh. At 150% DPI, the top strip
remained 32 DIPs and the host bar 24 DIPs, with no geometry/check failures. Its
result is in `tests/windows-layout/bin/.../layout-check.json`; `--check` avoids
activating the window and closes after the first measurement. This checks
functional behavior, not hardware performance.

Full-frame GPU/presentation performance and long-term resource growth still need
separate representative hardware observations. Apple sources were not changed;
no macOS/iOS hardware performance conclusion is implied.
