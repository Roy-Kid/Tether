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
| `host.notify` | none | Posts a notification the host shows. `{title, body}` |
| `host.ask` | none | A dialog the host shows. Returns `{action, value}` |
| `host.context` | none | `{hostID, hostLabel, shellLabel, connected}` for this activation |
| `host.reconnect` | none | Asks the host to reconnect this tab. Returns the context |

`network` requires an exact `networkURLs` list. `network.stream` opens one
GET SSE subscription per activation after consent; `network.closeStream` closes
it. HTTPS is allowed; HTTP only to literal loopback. Redirects, cookies, cached
credentials and direct WebKit network requests are blocked. SSE events are
bounded at 2 MiB and parsed off the main actor. Events reach `tether.onEvent`;
closing a session cancels its stream. Network consent is collected once during managed installation and persisted outside
the plugin package in `.network-grants.json`, keyed by plugin identity and exact
approved endpoint. Background pages and panels share the grant across activation,
disable/enable and app relaunch. Runtime requests never ask for consent. Uninstall
removes the grant. Legacy managed installations migrate their declared scope once.

`document.read` without a handle granted to that session fails. A handle
from another activation fails. Granting a document asks for consent each
time. Plugin storage asks once per activation. A refusal stores nothing
and returns no bytes. Plugins do not inherit the app's files, SSH, or
keychain.

Consent goes through `DialogPresenter`. `host.notify` is a notification the
host posts, and returns without waiting. Network installation prompts name the
plugin, distinguish local and external services, show approved endpoint
addresses, and explain the saved decision. Their verbs are Allow and Install and
Cancel. Document consent is per grant. Storage consent is once for that plugin.

## Runtime

`PluginRuntime` is the protocol: activate with a package root and an
entrypoint, then unload. `WebKitRuntime` is the Apple adapter (`WKWebView`,
Guideline 2.5.6). Each session gets a non-persistent data store. File
access is limited to the package root. Navigation off that root is
cancelled. `PluginSurface` is embedded by the `WebPlugin` workspace adapter. Status-bar
contributions own a background page for their enabled lifetime. WebKit RPC
replies and stream events decode UTF-8 before JSON parsing.

The protocol and the RPC types do not mention WebKit, so another platform
can add an adapter without changing the plugin model.

## Out of scope

File-type routing in the built-in file browser, a
marketplace, shell or filesystem capabilities, and any native, Node, or
Python runtime. A later direct-download build may add a privileged
runtime behind this same API. v0.1 does not.

## Application integration

`InstalledPlugins` copies validated packages into Application Support, then
registers `WebPlugin` adapters in the existing TetherPluginKit registry. It
rediscovers manifests at launch on Mac and iOS; enabled state uses the
registry's existing preferences. No native plugin dependency is added to the
app. Settings owns Install and Uninstall on both platforms.
`--install-plugin <directory>` uses the same operation on Mac.

A GitHub repository address installs that repository's latest release. The
address is `github.com/owner/name`, with no branch, tag, or asset name. The
host asks GitHub for the latest release, downloads that release's source
archive, and runs the same validation as a local folder. A repository with
no release is declined. The archive is not executed, and a redirect off
GitHub is not followed.

Native plugins and web pages call one contract. `PluginContext.services` is
that contract for compiled plugins. The page reaches it through `tether.call`
and the same names on `window.tether` (`notify`, `ask`, `storage`, `reconnect`).
`tether.context` is the tab the page was opened against. The host posts
notifications and shows dialogs; a plugin does not.

Disable/uninstall closes workspaces, cancels in-flight activation and unloads
background pages before dropping files. Activation revalidates both package
contents and the manifest to prevent stale permissions being reused.

The Nerve example lives in Nerve's `surfaces/tether`, independently of the
host, with SSE-driven jobs, structured status and ribbon contributions. Its hub
is an independently running service, not code loaded or launched by the plugin.

## Tab indicator contribution (2026-10-19)

`tabIndicator` grants `host.tabIndicators`: a complete replacement array of
`{target:{host,terminal},color,label}`. The target is a lowercase actual hostname
and controlling TTY path, not a user-facing host alias or tab title. The generic
TetherPluginKit types are `PluginTerminalIdentity` and `PluginTabIndicator`;
native plugins expose their set through `TetherPlugin.tabIndicators`.

The gateway validates the complete set before publishing it: at most 512 unique
targets, colors in 0...0xFFFFFF, host/TTY lengths 255/256 and nonempty labels up to
256 characters. Marks belong to activations. Unload clears that session only;
disable/uninstall clears the background too. A tabIndicator-only plugin starts a
background page without creating a ribbon. Competing enabled plugins use registry
order; task priority remains the provider's business.

The app draws one 6pt circle before the tab title, in both Mac tab layouts, for
the focused terminal of a workspace. Local identity reuses the producer TTY and
ProcessInfo.hostName; remote identity reuses ShellTTY and executes hostname over
the current authenticated lease. An unknown/disconnected identity yields no mark.
This slot conveys data only and adds no terminal-input capability.
