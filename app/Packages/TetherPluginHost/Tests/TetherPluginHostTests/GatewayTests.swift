import Foundation
import Testing

@testable import TetherPluginHost

@Test @MainActor
func readingWithoutAGrantFails() async throws {
  let host = try await activatedHost()
  let response = await host.perform(request("document.read", session: host.liveSessions.first!, payload: .object([:])))
  #expect(response.ok == false)
  #expect(response.error == "noGrant")
}

@Test @MainActor
func aGrantReturnsBytesAndNoPath() async throws {
  let consent = ScriptedConsent(allow: true)
  let (host, root) = try await installedHost(consent: consent)
  let session = try #require(host.liveSessions.first)
  let bytes = Data("fixture-bytes".utf8)
  let handle = try await host.grant(session: session, bytes: bytes)

  #expect(Mirror(reflecting: handle).children.map(\.label) == ["id"])
  #expect(consent.asks.map(\.1) == [.documentRead])
  let response = await host.perform(
    request("document.read", session: session, payload: .object(["handle": .string(handle.id.uuidString)])))
  #expect(response.ok)
  let encoded = try #require(response.payload.key("bytes")?.string)
  #expect(Data(base64Encoded: encoded) == bytes)
  let text = try RPCCodec.encode(response)
  #expect(!text.contains(root.path))
  #expect(!text.contains("\"path\""))
}

@Test @MainActor
func aHandleFromAnotherActivationFails() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), notifying: RecordedNotifier())
  let first = try host.install(directory: try Fixture.make(id: "fixture.one"))
  let second = try host.install(directory: try Fixture.make(id: "fixture.two", suffixes: ["other"]))
  let sessionA = try await host.activate(id: first.id, runtime: IdleRuntime())
  let sessionB = try await host.activate(id: second.id, runtime: IdleRuntime())
  let handle = try await host.grant(session: sessionA, bytes: Data("secret".utf8))

  let response = await host.perform(
    request("document.read", session: sessionB, payload: .object(["handle": .string(handle.id.uuidString)])))
  #expect(response.ok == false)
  #expect(response.error == "invalidHandle")
}

@Test @MainActor
func refusedConsentStoresNothing() async throws {
  let host = try await activatedHost(consent: ScriptedConsent(allow: false))
  let session = try #require(host.liveSessions.first)
  await #expect(throws: PluginHostError.consentDenied) {
    try await host.grant(session: session, bytes: Data("no".utf8))
  }
  let response = await host.perform(request("document.read", session: session, payload: .object([:])))
  #expect(response.error == "noGrant")
}

@Test @MainActor
func pluginStorageDoesNotCrossPlugins() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), notifying: RecordedNotifier())
  let first = try host.install(directory: try Fixture.make(id: "fixture.one"))
  let second = try host.install(directory: try Fixture.make(id: "fixture.two", suffixes: ["other"]))
  let sessionA = try await host.activate(id: first.id, runtime: IdleRuntime())
  let sessionB = try await host.activate(id: second.id, runtime: IdleRuntime())

  let wrote = await host.perform(
    request("storage.plugin.set", session: sessionA, payload: .object(["key": .string("token"), "value": .string("a")])))
  #expect(wrote.ok)
  let own = await host.perform(
    request("storage.plugin.get", session: sessionA, payload: .object(["key": .string("token")])))
  #expect(own.payload.key("value")?.string == "a")
  let other = await host.perform(
    request("storage.plugin.get", session: sessionB, payload: .object(["key": .string("token")])))
  #expect(other.ok)
  #expect(other.payload.key("value") == .null)
}

@Test @MainActor
func anUnknownMethodIsRejected() async throws {
  let host = try await activatedHost()
  let session = try #require(host.liveSessions.first)
  let response = await host.perform(request("spawn", session: session, payload: .object([:])))
  #expect(response.ok == false)
  #expect(response.error == "unknownMethod")
}

@Test @MainActor
func thePageCannotSpeakAsAnotherSession() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), notifying: RecordedNotifier())
  let first = try host.install(directory: try Fixture.make(id: "fixture.one"))
  let second = try host.install(directory: try Fixture.make(id: "fixture.two", suffixes: ["other"]))
  let sessionA = try await host.activate(id: first.id, runtime: IdleRuntime())
  let sessionB = try await host.activate(id: second.id, runtime: IdleRuntime())
  let handle = try await host.grant(session: sessionA, bytes: Data("secret".utf8))
  let forged = try RPCCodec.encode(
    request("document.read", session: sessionA, payload: .object(["handle": .string(handle.id.uuidString)])))

  let raw = await host.deliver(forged, from: sessionB)
  let response = try RPCCodec.decode(RPCResponse.self, from: raw)
  #expect(response.session == sessionB)
  #expect(response.ok == false)
  #expect(response.error == "invalidHandle")
}

@Test
func consentIsATitleAndAVerb() {
  let dialog = ConsentPrompt.dialog(pluginName: "Fixture", permission: .documentRead)
  #expect(dialog.title == "Fixture")
  #expect(dialog.message == "document.read")
  #expect(dialog.actions.map(\.title) == ["Allow", "Cancel"])
  #expect(dialog.actions.map(\.role) == [.confirm, .cancel])
  let notice = NotifyPrompt.dialog(title: "Ready")
  #expect(notice.title == "Ready")
  #expect(notice.message == nil)
  #expect(notice.actions.map(\.title) == ["OK"])
}

@MainActor
private func activatedHost(
  consent: ScriptedConsent = ScriptedConsent(allow: true), id: String = "fixture.host"
) async throws -> PluginHost {
  try await installedHost(consent: consent, id: id).0
}

@MainActor
private func installedHost(
  consent: ScriptedConsent = ScriptedConsent(allow: true), id: String = "fixture.host"
) async throws -> (PluginHost, URL) {
  let host = PluginHost(consent: consent, notifying: RecordedNotifier())
  let root = try Fixture.make(id: id)
  let record = try host.install(directory: root)
  _ = try await host.activate(id: record.id, runtime: IdleRuntime())
  return (host, root)
}
