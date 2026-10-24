import AppKit
import SwiftUI
import WebKit
import Foundation
import Testing
import TetherPluginKit
@testable import TetherPluginHost

private let endpoint = "http://127.0.0.1:17890/v1/stream?surface=fixture"

private func networkFixture(status: Bool = false) throws -> URL {
  let root = try Fixture.make(permissions: ["network"], contributions:
    status ? #"[{"kind":"panel","id":"panel/jobs"},{"kind":"statusBar","id":"status/jobs"}]"# : nil)
  let file = root.appending(path: "manifest.json")
  var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  manifest["networkURLs"] = [endpoint]
  try JSONSerialization.data(withJSONObject: manifest).write(to: file)
  return root
}

@MainActor private final class HoldingStream: PluginStreaming {
  var urls: [URL] = []
  var cancellations = 0
  func stream(url: URL, receive: @escaping @MainActor (JSONValue) async -> Void) async throws {
    urls.append(url)
    defer { cancellations += 1 }
    await receive(.object(["data": .string("任务更新"), "event": .string("message")]))
    try await Task.sleep(for: .seconds(30))
  }
}

@MainActor private final class EventRuntime: PluginRuntime {
  var events: [JSONValue] = []
  var unloads = 0
  func activate(session: UUID, root: URL, entrypoint: URL, bridge: any PluginBridge) async throws {}
  func unload(session: UUID) { unloads += 1 }
  func receive(event: JSONValue, session: UUID) async { events.append(event) }
}

@MainActor private final class PendingNetworkConsent: ConsentAsking {
  var asks = 0
  var reply: CheckedContinuation<Bool, Never>?
  func ask(pluginName: String, permission: Permission) async -> Bool {
    asks += 1
    return await withCheckedContinuation { reply = $0 }
  }
}

@Test @MainActor func reopeningAndReenablingDoNotAskForNetworkAgain() async throws {
  let root = try networkFixture(status: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let consent = ScriptedConsent(allow: true)
  let host = PluginHost(consent: consent, presenting: RecordedPresenter(), streaming: HoldingStream())
  let record = try host.install(directory: root)
  #expect(await host.authorizeNetwork(record.manifest))
  host.grantNetwork(pluginID: record.id, urls: record.manifest.networkURLs)
  let payload = JSONValue.object(["url": .string(endpoint)])
  for _ in 0..<3 {
    let session = try await host.activate(id: record.id, runtime: EventRuntime())
    #expect(await host.perform(request("network.stream", session: session, payload: payload)).ok)
    host.unload(session: session)
    try host.setEnabled(false, id: record.id)
    try host.setEnabled(true, id: record.id)
  }
  #expect(consent.asks.map(\.1) == [.network])
}

@Test func boundedSSEDecoding() throws {
  var decoder = EventStreamDecoder()
  let text = ": heartbeat\r\n\r\nevent: jobs\r\ndata: 任务\r\ndata: update\r\n\r\n"
  let events = try text.utf8.compactMap { try decoder.append($0) }
  #expect(events == [.object(["event": .string("jobs"), "data": .string("任务\nupdate")])])
  var overlong = EventStreamDecoder()
  for _ in 0..<EventStreamDecoder.limit { _ = try overlong.append(65) }
  #expect(throws: StreamFailure.tooLarge) { _ = try overlong.append(65) }
}

@MainActor private final class RecordingPoster: PluginPosting {
  var urls: [URL] = []
  var fails = false
  func post(url: URL) async throws {
    urls.append(url)
    if fails { throw StreamFailure.invalidResponse }
  }
}

@Test func aGrantedLoopbackOriginCoversLaterPathsOnThatPort() {
  let stream = URL(string: "http://127.0.0.1:17890/v1/stream?surface=tether")!
  let refresh = URL(string: "http://127.0.0.1:17890/v1/refresh")!
  let other = URL(string: "http://127.0.0.1:9/v1/refresh")!
  let expanded = NetworkEndpoint.expandGrants(declared: [stream, refresh, other], approved: [stream.absoluteString])
  #expect(expanded.contains(refresh.absoluteString))
  #expect(!expanded.contains(other.absoluteString))
}

@Test @MainActor func postUsesTheSameGrantAsTheStream() async throws {
  let source = try networkFixture()
  defer { try? FileManager.default.removeItem(at: source) }
  let file = source.appending(path: "manifest.json")
  var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  let refresh = "http://127.0.0.1:17890/v1/refresh"
  manifest["networkURLs"] = [endpoint, refresh]
  try JSONSerialization.data(withJSONObject: manifest).write(to: file)
  let poster = RecordingPoster()
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter(), streaming: HoldingStream(), posting: poster)
  let record = try host.install(directory: source)
  let session = try await host.activate(id: record.id, runtime: EventRuntime())
  let payload = JSONValue.object(["url": .string(refresh)])
  #expect(await host.perform(request("network.post", session: session, payload: payload)).error == "consentDenied")
  host.grantNetwork(pluginID: record.id, urls: [URL(string: endpoint)!])
  #expect(await host.perform(request("network.post", session: session, payload: payload)).error == "consentDenied")
  let foreign = await host.perform(request("network.post", session: session,
    payload: .object(["url": .string("http://127.0.0.1:17890/v1/jobs")])))
  #expect(foreign.error == "permissionDenied")
  host.grantNetwork(pluginID: record.id, urls: record.manifest.networkURLs)
  #expect(await host.perform(request("network.post", session: session, payload: payload)).ok)
  #expect(poster.urls.map(\.absoluteString) == [refresh])
  poster.fails = true
  #expect(await host.perform(request("network.post", session: session, payload: payload)).error == "unavailable")
}

@Test func endpointsDoNotGrantArbitraryNetworking() {
  for text in ["file:///etc/passwd", "http://example.com/stream", "https://user:password@example.com/s", "http://127.0.0.1/s#fragment"] {
    #expect(!NetworkEndpoint.valid(URL(string: text)!))
  }
  #expect(NetworkEndpoint.valid(URL(string: endpoint)!))
  #expect(NetworkEndpoint.valid(URL(string: "https://example.com/events")!))
}

@Test @MainActor func streamPermissionAndLifetime() async throws {
  let source = try networkFixture()
  defer { try? FileManager.default.removeItem(at: source) }
  let transport = HoldingStream()
  let consent = ScriptedConsent(allow: true)
  let host = PluginHost(consent: consent, presenting: RecordedPresenter(), streaming: transport)
  let record = try host.install(directory: source)
  let runtime = EventRuntime()
  let session = try await host.activate(id: record.id, runtime: runtime)
  let blocked = await host.perform(request("network.stream", session: session,
    payload: .object(["url": .string("http://127.0.0.1:17890/v1/jobs")])))
  #expect(blocked.error == "permissionDenied")
  #expect(consent.asks.isEmpty)
  #expect(await host.authorizeNetwork(record.manifest))
  host.grantNetwork(pluginID: record.id, urls: record.manifest.networkURLs)
  let opened = await host.perform(request("network.stream", session: session, payload: .object(["url": .string(endpoint)])))
  #expect(opened.ok)
  let duplicate = await host.perform(request("network.stream", session: session, payload: .object(["url": .string(endpoint)])))
  #expect(duplicate.error == "streamLimit")
  for _ in 0..<20 where runtime.events.isEmpty { await Task.yield() }
  #expect(runtime.events.first?.key("payload")?.key("data")?.string == "任务更新")
  #expect(consent.asks.map(\.1) == [.network])
  try host.setEnabled(false, id: record.id)
  for _ in 0..<20 where transport.cancellations == 0 { await Task.yield() }
  #expect(host.liveSessions.isEmpty)
  #expect(runtime.unloads == 1)
  #expect(transport.cancellations == 1)
  let stale = await host.perform(request("network.stream", session: session, payload: .object(["url": .string(endpoint)])))
  #expect(stale.error == "noSession")
}

@Test @MainActor func refusedNetworkConsentDoesNotConnect() async throws {
  let source = try networkFixture()
  defer { try? FileManager.default.removeItem(at: source) }
  let transport = HoldingStream()
  let host = PluginHost(consent: ScriptedConsent(allow: false), presenting: RecordedPresenter(), streaming: transport)
  let record = try host.install(directory: source)
  let session = try await host.activate(id: record.id, runtime: EventRuntime())
  let response = await host.perform(request("network.stream", session: session, payload: .object(["url": .string(endpoint)])))
  #expect(response.error == "consentDenied")
  #expect(transport.urls.isEmpty)
  host.unload(session: session)
}

@Test @MainActor func managedInstallSurvivesRelaunchAndUninstall() async throws {
  let source = try Fixture.make()
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let suite = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suite)
  }
  let registry = TetherPluginKit.PluginRegistry(defaults: defaults)
  let library = InstalledPlugins(directory: directory, registry: registry,
    host: PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter()))
  let installed = try await library.install(directory: source)
  #expect(installed.source.root != source)
  #expect(registry.plugins.count == 1)
  await #expect(throws: PluginHostError.duplicate(installed.id)) { try await library.install(directory: source) }
  registry.setEnabled(false, id: installed.id)
  let relaunchedRegistry = TetherPluginKit.PluginRegistry(defaults: defaults)
  let relaunched = InstalledPlugins(directory: directory, registry: relaunchedRegistry,
    host: PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter()))
  relaunched.discover()
  #expect(relaunched.problems.isEmpty)
  #expect(relaunchedRegistry.plugins.count == 1)
  #expect(!relaunchedRegistry.isEnabled(installed.id))
  try relaunched.uninstall(id: installed.id)
  #expect(relaunchedRegistry.plugins.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: installed.source.root.path))
  relaunched.discover()
  #expect(relaunched.pluginIDs.isEmpty)
}

@Test @MainActor func changedManifestCannotRunWithOldPermissions() async throws {
  let source = try Fixture.make()
  defer { try? FileManager.default.removeItem(at: source) }
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let record = try host.install(directory: source)
  let manifest = source.appending(path: "manifest.json")
  let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: "0.1.0", with: "0.2.0")
  try Data(text.utf8).write(to: manifest)
  await #expect(throws: PluginHostError.package(.malformed)) {
    try await host.activate(id: record.id, runtime: IdleRuntime())
  }
  #expect(host.liveSessions.isEmpty)
}

@Test @MainActor func aBrokenManifestIsToldInsideThePlugin() async throws {
  let source = try Fixture.make(contributions: #"[{"kind":"statusBar","id":"status/main"}]"#)
  defer { try? FileManager.default.removeItem(at: source) }
  let presenter = RecordedPresenter()
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: presenter)
  let record = try host.install(directory: source)
  let manifest = source.appending(path: "manifest.json")
  let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: "0.1.0", with: "9.9.9")
  try Data(text.utf8).write(to: manifest)
  let plugin = WebPlugin(record: record, host: host)
  plugin.activate()
  let workspace = try #require(plugin.statusBarWorkspace())
  defer { workspace.close(); plugin.deactivate() }

  // The panel body is this sentence. SwiftUI Text is not an AppKit field.
  var message: String?
  for _ in 0..<50 {
    message = plugin.activationFailure(in: workspace)
    if message != nil { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(message == "The plugin manifest is invalid or has changed since installation.")
  #expect(presenter.notes.isEmpty)
}

@Test @MainActor func webPageReceivesUTF8StreamAndReportsStatus() async throws {
  let source = try networkFixture(status: true)
  defer { try? FileManager.default.removeItem(at: source) }
  let page = #"""
  <!doctype html><html><body><script>
  tether.onEvent = event => {
    if (event.type === 'data') tether.call('host.status', {label: event.payload.data, segments: [{color: 0x5783D8, weight: 1}]});
  };
  tether.call('network.stream', {url:'http://127.0.0.1:17890/v1/stream?surface=fixture'});
  </script></body></html>
  """#
  try Data(page.utf8).write(to: source.appending(path: "web/index.html"))
  let transport = HoldingStream()
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter(), streaming: transport)
  let record = try host.install(directory: source)
  #expect(await host.authorizeNetwork(record.manifest))
  host.grantNetwork(pluginID: record.id, urls: record.manifest.networkURLs)
  var reported: JSONValue?
  host.onStatus = { id, payload in
    #expect(id == record.id)
    reported = payload
  }
  let runtime = WebKitRuntime(background: true)
  let session = try await host.activate(id: record.id, runtime: runtime)
  defer { host.unload(session: session) }
  // A background WebKit process can defer JavaScript callbacks past one second.
  // Wait for the bridge's result, with a deadline that also catches lost events.
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(10))
  while reported == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  #expect(reported?.key("label")?.string == "任务更新", "UTF-8 survives the native → JavaScript event bridge")
}

@MainActor private final class PausedRuntime: PluginRuntime {
  var started = false
  var unloads = 0
  private var waiting: CheckedContinuation<Void, Error>?
  func activate(session: UUID, root: URL, entrypoint: URL, bridge: any PluginBridge) async throws {
    started = true
    try await withCheckedThrowingContinuation { waiting = $0 }
  }
  func unload(session: UUID) {
    unloads += 1
    waiting?.resume(throwing: CancellationError())
    waiting = nil
  }
}

@Test @MainActor func disableDuringActivationDoesNotLeaveAHiddenPage() async throws {
  let root = try Fixture.make()
  defer { try? FileManager.default.removeItem(at: root) }
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let record = try host.install(directory: root)
  let runtime = PausedRuntime()
  let opening = Task { try await host.activate(id: record.id, runtime: runtime) }
  for _ in 0..<20 where !runtime.started { await Task.yield() }
  #expect(runtime.started)
  try host.setEnabled(false, id: record.id)
  await #expect(throws: CancellationError.self) { try await opening.value }
  #expect(host.liveSessions.isEmpty)
  #expect(runtime.unloads == 1)
}

@Test @MainActor func cancellingActivationUnloadsBeforeThePageFinishes() async throws {
  let root = try Fixture.make()
  defer { try? FileManager.default.removeItem(at: root) }
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let record = try host.install(directory: root)
  let runtime = PausedRuntime()
  let opening = Task { try await host.activate(id: record.id, runtime: runtime) }
  for _ in 0..<20 where !runtime.started { await Task.yield() }
  opening.cancel()
  await #expect(throws: CancellationError.self) { try await opening.value }
  #expect(host.liveSessions.isEmpty)
  #expect(runtime.unloads == 1)
}


@Test @MainActor func installedNetworkConsentSurvivesAppRelaunch() async throws {
  let source = try networkFixture()
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let suite = "network-test-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
  let consent = ScriptedConsent(allow: true)
  let host = PluginHost(consent: consent, presenting: RecordedPresenter(), streaming: HoldingStream())
  let registry = TetherPluginKit.PluginRegistry(defaults: defaults)
  let library = InstalledPlugins(directory: directory, registry: registry, host: host)
  let record = try await library.install(directory: source)
  #expect(consent.asks.map(\.1) == [.network])
  let session = try await host.activate(id: record.id, runtime: EventRuntime())
  #expect(await host.perform(request("network.stream", session: session, payload: .object(["url": .string(endpoint)]))).ok)
  host.unload(session: session)
  let relaunchConsent = ScriptedConsent(allow: false)
  let relaunchedHost = PluginHost(consent: relaunchConsent, presenting: RecordedPresenter(), streaming: HoldingStream())
  let relaunched = InstalledPlugins(directory: directory, registry: TetherPluginKit.PluginRegistry(defaults: defaults), host: relaunchedHost)
  relaunched.discover()
  let fresh = try await relaunchedHost.activate(id: record.id, runtime: EventRuntime())
  #expect(await relaunchedHost.perform(request("network.stream", session: fresh, payload: .object(["url": .string(endpoint)]))).ok)
  #expect(relaunchConsent.asks.isEmpty)
  relaunchedHost.unload(session: fresh)
  try relaunched.uninstall(id: record.id)
  let denied = ScriptedConsent(allow: false)
  let deniedHost = PluginHost(consent: denied, presenting: RecordedPresenter(), streaming: HoldingStream())
  let deniedLibrary = InstalledPlugins(directory: directory, registry: TetherPluginKit.PluginRegistry(defaults: defaults), host: deniedHost)
  await #expect(throws: PluginHostError.consentDenied) { try await deniedLibrary.install(directory: source) }
  #expect(denied.asks.map(\.1) == [.network])
  #expect(deniedLibrary.pluginIDs.isEmpty)
  #expect(deniedHost.records.isEmpty)
}

@Test func networkConsentClearlyDescribesLocalScopeAndPersistence() {
  let dialog = ConsentPrompt.dialog(pluginName: "Nerve", permission: .network, resources: [endpoint])
  #expect(dialog.title == "Install Nerve?")
  #expect(dialog.message?.contains("on this device") == true)
  #expect(dialog.message?.contains("will not ask again") == true)
  #expect(dialog.actions.first?.title == "Allow and Install")
}

@Test @MainActor func statusPanelReplacesLoadingViewWhenActivationFinishes() async throws {
  let root = try Fixture.make()
  defer { try? FileManager.default.removeItem(at: root) }
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let record = try host.install(directory: root)
  let plugin = WebPlugin(record: record, host: host)
  plugin.activate()
  let workspace = try #require(plugin.statusBarWorkspace())
  let view = NSHostingView(rootView: workspace.content())
  let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 450),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = view
  window.makeKeyAndOrderFront(nil)
  defer { workspace.close(); plugin.deactivate(); window.orderOut(nil) }
  func webView(in view: NSView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    for child in view.subviews { if let web = webView(in: child) { return web } }
    return nil
  }
  for _ in 0..<200 where webView(in: view) == nil { try await Task.sleep(for: .milliseconds(10)) }
  _ = try #require(webView(in: view), "the existing hosting view must leave loading without reopening the panel")
}

@Test @MainActor
func aTabIndicatorOnlyPluginOwnsABackgroundPageWithoutARibbon() async throws {
  let root = try Fixture.make(contributions: "[{\"kind\":\"tabIndicator\",\"id\":\"tabs/status\"}]")
  defer { try? FileManager.default.removeItem(at: root) }
  let host = PluginHost(consent: ScriptedConsent(allow: true))
  let record = try host.install(directory: root)
  #expect(host.index.tabIndicators.count == 1)
  let plugin = WebPlugin(record: record, host: host)
  plugin.activate()
  defer { plugin.deactivate() }
  for _ in 0..<100 where host.liveSessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
  #expect(host.liveSessions.count == 1)
  #expect(plugin.statusBarItem == nil)
  plugin.deactivate()
  #expect(host.liveSessions.isEmpty)
  #expect(plugin.tabIndicators.isEmpty)
}
