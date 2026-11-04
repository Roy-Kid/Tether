import Foundation
import Testing
import TetherPluginKit

@testable import TetherPluginHost

@Test @MainActor
func activateThenUnloadKeepsTheRecordAndDropsTheSession() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
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
