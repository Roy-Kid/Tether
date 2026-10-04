import Foundation
import Testing

@testable import TetherPluginHost

@Test @MainActor
func activateThenUnloadKeepsTheRecordAndDropsTheSession() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), notifying: RecordedNotifier())
  let record = try host.install(directory: try Fixture.make())
  let runtime = IdleRuntime()
  let session = try await host.activate(id: record.id, runtime: runtime)

  #expect(runtime.activations == 1)
  #expect(host.liveSessions == [session])
  #expect(host.record(record.id)?.status == .activated)

  host.unload(session: session)
  #expect(runtime.unloads == 1)
  #expect(host.liveSessions.isEmpty)
  #expect(host.record(record.id)?.status == .unloaded)
  #expect(host.index.matches(suffix: "fixture").map(\.pluginID) == [record.id])

  let after = await host.perform(request("document.read", session: session, payload: .object([:])))
  #expect(after.error == "noSession")
}

@Test
func navigationStaysInsideThePackage() throws {
  let root = URL(fileURLWithPath: "/tmp/plugin-root")
  #expect(WebOrigin.allows(root.appending(path: "web").appending(path: "index.html"), root: root))
  #expect(WebOrigin.allows(URL(string: "about:blank")!, root: root))
  #expect(!WebOrigin.allows(URL(string: "https://example.com/app.js")!, root: root))
  #expect(!WebOrigin.allows(URL(fileURLWithPath: "/tmp/plugin-root-other/payload.js"), root: root))
  #expect(!WebOrigin.allows(URL(fileURLWithPath: "/etc/passwd"), root: root))
}

@Test @MainActor
func theBridgeScriptNamesOnlyThePluginChannel() {
  let session = UUID()
  let source = WebKitRuntime.bridgeScript(session: session)
  #expect(source.contains(session.uuidString))
  #expect(source.contains("webkit.messageHandlers.plugin"))
  #expect(!source.contains("dlopen"))
  #expect(!source.contains("spawn"))
}

@Test @MainActor
func webKitActivateThenUnloadReleasesTheView() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), notifying: RecordedNotifier())
  let record = try host.install(directory: try Fixture.make(id: "fixture.webkit"))
  let runtime = WebKitRuntime()
  let session = try await host.activate(id: record.id, runtime: runtime)
  #expect(runtime.webView(for: session) != nil)

  host.unload(session: session)
  #expect(runtime.webView(for: session) == nil)
  #expect(host.liveSessions.isEmpty)
  #expect(host.record(record.id)?.status == .unloaded)
}
