import Foundation
import Testing
import TetherPluginKit

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
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
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
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
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
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
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
  let ending = PluginDialog(.confirm("End this session?", verb: "End", destructive: true))
  #expect(ending.dialog.title == "End this session?")
  #expect(ending.dialog.actions.map(\.title) == ["Cancel", "End"])
  #expect(ending.dialog.actions.map(\.role) == [.cancel, .destructive])
}

@Test @MainActor
func aPageAndANativeCallerShareTheHost() async throws {
  let presenter = RecordedPresenter()
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: presenter)
  let record = try host.install(directory: try Fixture.make())
  let session = try await host.activate(id: record.id, runtime: IdleRuntime())
  try await host.api.services(pluginID: record.id, pluginName: record.manifest.name).storageSet("token", "native")
  let stored = await host.perform(
    request("storage.plugin.get", session: session, payload: .object(["key": .string("token")])))
  #expect(stored.payload.key("value")?.string == "native")

  let noted = await host.perform(
    request("host.notify", session: session, payload: .object(["title": .string("Ready"), "body": .string("done")])))
  #expect(noted.ok)
  #expect(presenter.notes.map(\.0) == ["Ready"])
  #expect(presenter.notes.map(\.1) == ["done"])

  presenter.answer = PluginAnswer(action: "keep", value: "")
  let asked = await host.perform(
    request("host.ask", session: session, payload: .object([
      "title": .string("Replace?"),
      "actions": .array([
        .object(["id": .string("replace"), "title": .string("Replace"), "destructive": .bool(true)]),
        .object(["id": .string("keep"), "title": .string("Keep Both")]),
      ]),
    ])))
  #expect(asked.payload.key("action")?.string == "keep")
  #expect(presenter.prompts.map(\.title) == ["Replace?"])
}

@Test @MainActor
func thePageReadsTheTabItWasOpenedAgainst() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let record = try host.install(directory: try Fixture.make())
  let hostID = UUID()
  var reconnected = 0
  let session = try await host.activate(
    id: record.id, runtime: IdleRuntime(),
    environment: PluginEnvironment(hostID: hostID, hostLabel: "lab", shellLabel: "zsh", connected: false),
    reconnect: { reconnected += 1 })
  let context = await host.perform(request("host.context", session: session, payload: .object([:])))
  #expect(context.payload.key("hostID")?.string == hostID.uuidString)
  #expect(context.payload.key("hostLabel")?.string == "lab")
  #expect(context.payload.key("shellLabel")?.string == "zsh")
  #expect(context.payload.key("connected")?.bool == false)
  let again = await host.perform(request("host.reconnect", session: session, payload: .object([:])))
  #expect(again.ok)
  #expect(again.payload.key("connected")?.bool == true)
  #expect(reconnected == 1)
  let missing = await host.perform(request("host.reconnect", session: UUID(), payload: .object([:])))
  #expect(missing.error == "noSession")
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
  let host = PluginHost(consent: consent, presenting: RecordedPresenter())
  let root = try Fixture.make(id: id)
  let record = try host.install(directory: root)
  _ = try await host.activate(id: record.id, runtime: IdleRuntime())
  return (host, root)
}

@Test @MainActor
func tabIndicatorsRequireAContributionAndReplaceOnlyTheirOwnSession() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true))
  let root = try Fixture.make(contributions: "[{\"kind\":\"tabIndicator\",\"id\":\"tabs/status\"}]")
  defer { try? FileManager.default.removeItem(at: root) }
  let record = try host.install(directory: root)
  let first = try await host.activate(id: record.id, runtime: IdleRuntime())
  let second = try await host.activate(id: record.id, runtime: IdleRuntime())
  var reports: [UUID: [PluginTabIndicator]] = [:]
  host.onTabIndicators = { session, id, items in
    #expect(id == record.id)
    reports[session] = items
  }
  let item: JSONValue = .object([
    "target": .object(["host": .string("studio"), "terminal": .string("/dev/ttys001")]),
    "color": .number(0x0A84FF), "label": .string("Compiling")])
  let result = await host.perform(request("host.tabIndicators", session: first, payload: .array([item])))
  #expect(result.ok)
  #expect(reports[first]?.first?.color == 0x0A84FF)
  _ = await host.perform(request("host.tabIndicators", session: second, payload: .array([item])))
  let duplicate = await host.perform(request("host.tabIndicators", session: first, payload: .array([item, item])))
  #expect(duplicate.error == "malformed")
  let bad: JSONValue = .object(["target": item.key("target")!, "color": .number(0x1000000), "label": .string("Bad")])
  let invalid = await host.perform(request("host.tabIndicators", session: first, payload: .array([bad])))
  #expect(invalid.error == "malformed")
  #expect(reports[first]?.count == 1, "malformed updates leave the last valid set intact")
  host.unload(session: first)
  #expect(reports[first] == [])
  #expect(reports[second]?.count == 1, "unloading a panel cannot erase a background session's marks")
  try host.setEnabled(false, id: record.id)
  #expect(reports[second] == [])
  let otherRoot = try Fixture.make(id: "fixture.no-indicators")
  defer { try? FileManager.default.removeItem(at: otherRoot) }
  let other = try host.install(directory: otherRoot)
  let session = try await host.activate(id: other.id, runtime: IdleRuntime())
  defer { host.unload(session: session) }
  let denied = await host.perform(request("host.tabIndicators", session: session, payload: .array([item])))
  #expect(denied.error == "permissionDenied")
}
