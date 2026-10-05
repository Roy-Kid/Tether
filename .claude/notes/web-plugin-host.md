# Web plugin host

Runtime plugins are web software. The Mac App Store build loads a manifest
and, only when a plugin is activated, an isolated WebKit page. It does not
load a downloaded executable, dynamic library, or language runtime.

Built-in plugins (compiled Swift packages registered in the app) are a
different mechanism. They stay on `TetherPluginKit`. This host does not
replace them, and it does not name them.

The package is `app/Packages/TetherPluginHost`. It is not part of the Rust
SDK and not part of `remote-platform-spec.md`.

## What a package is

A directory with `manifest.json` and a web root. Install reads the manifest
and updates the contribution index. The page does not run.

```json
{
  "id": "fixture.host",
  "name": "Fixture",
  "publisher": "Fixture",
  "version": "0.1.0",
  "api": 1,
  "runtime": "web",
  "entrypoint": "web/index.html",
  "ageRating": "4+",
  "link": "https://example.com/plugins/fixture",
  "permissions": ["document.read", "storage.plugin"],
  "contributions": [
    {"kind": "viewer", "id": "viewer/fixture", "suffixes": ["fixture"]}
  ]
}
```

`runtime` must be `web`. `api` must be `1`. The entrypoint is a relative
HTML file inside the directory.

Allowed files are HTML, CSS, JavaScript, images, fonts, and `.wasm` that
WebKit compiles as part of the page. There is no WASI and no native WASM
runtime. The validator rejects Mach-O, ELF, PE, `.dylib`, `.so`, `.dll`,
`.framework`, `.node`, Python native modules, executable bits, symlinks
that leave the directory, and install scripts (`package.json` install
hooks, `requirements.txt`, `setup.py`, `Pipfile`).

Records keep the fields a later catalog needs: identity, publisher,
version, source, permissions, entrypoint, status, age rating, and link.
v0.1 does not ship a catalog, an age gate, or a moderation flow.

## Lifecycle

```text
Installed → Discovered → Registered → Activated → Unloaded
```

Install performs the first three steps and stops at `registered`. No web
view exists yet. `Activated` is the first time a runtime is created.
`Unloaded` drops the view and invalidates document handles. The registry
entry and, while the plugin stays enabled, its contributions remain.

Disable and uninstall remove contributions. An active session is unloaded
first. Uninstall also drops that plugin's stored keys.

## Capability API

The page talks JSON. `PluginRPC` is the ABI: `api`, `session`, `id`,
`method`, `payload`. WebKit is one transport. The message handler forwards
bytes to the gateway and does not call through to arbitrary selectors.

The session id in a page message is replaced with the session that owns
the web view before the gateway sees it.

| Method | Permission | Result |
|---|---|---|
| `document.read` | `document.read` | Bytes of one granted handle. No path. |
| `storage.plugin.get` | `storage.plugin` | A string stored for this plugin id, or null |
| `storage.plugin.set` | `storage.plugin` | Stores a string for this plugin id |
| `host.notify` | none | A dialog whose title is the plugin's text |

`network` is a known manifest token. Declaring it does not allow the web
view to navigate off its origin. v0.1 has no network method.

`document.read` without a handle granted to that session fails. A handle
from another activation fails. Granting a document asks for consent each
time. Plugin storage asks once per activation. A refusal stores nothing
and returns no bytes. Plugins do not inherit the app's files, SSH, or
keychain.

Consent and notify go through `DialogPresenter`. The consent dialog's
title is the plugin name, its message is the permission token, and its
verbs are Allow and Cancel.

## Runtime

`PluginRuntime` is the protocol: activate with a package root and an
entrypoint, then unload. `WebKitRuntime` is the Apple adapter (`WKWebView`,
Guideline 2.5.6). Each session gets a non-persistent data store. File
access is limited to the package root. Navigation off that root is
cancelled. `PluginSurface` is the SwiftUI view a later tab can embed.

The protocol and the RPC types do not mention WebKit, so another platform
can add an adapter without changing the plugin model.

## Out of scope

Named product plugins, file-type routing in the built-in file browser, a
marketplace, shell or filesystem capabilities, and any native, Node, or
Python runtime. A later direct-download build may add a privileged
runtime behind this same API. v0.1 does not.
