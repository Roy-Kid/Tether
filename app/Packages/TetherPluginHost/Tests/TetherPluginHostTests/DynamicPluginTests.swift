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

@MainActor
private final class OccupyingPlugin: TetherPlugin {
  let metadata: PluginMetadata
  init(id: String) {
    metadata = PluginMetadata(id: id, name: "Native", symbol: "circle", summary: "Already registered")
  }
  func launch(in context: PluginContext) {}
}
