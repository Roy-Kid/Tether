import Foundation
import Testing
import TetherPluginKit

@testable import TetherPluginHost

@MainActor
final class ScriptedConsent: ConsentAsking {
  var allow: Bool
  var asks: [(String, Permission)] = []

  init(allow: Bool) { self.allow = allow }

  func ask(pluginName: String, permission: Permission) async -> Bool {
    asks.append((pluginName, permission))
    return allow
  }
}

@MainActor
final class RecordedPresenter: PluginPresenting {
  var notes: [(String, String)] = []
  var prompts: [PluginPrompt] = []
  var answer = PluginAnswer(action: "confirm", value: "")

  func notify(title: String, body: String) async { notes.append((title, body)) }
  func ask(_ prompt: PluginPrompt) async -> PluginAnswer {
    prompts.append(prompt)
    return answer
  }
}

@MainActor
final class IdleRuntime: PluginRuntime {
  var activations = 0
  var unloads = 0

  func activate(session: UUID, root: URL, entrypoint: URL, bridge: any PluginBridge) async throws {
    activations += 1
  }

  func unload(session: UUID) { unloads += 1 }
}

enum Fixture {
  static func make(
    id: String = "fixture.host",
    suffixes: [String] = ["fixture"],
    runtime: String = "web",
    permissions: [String] = ["document.read", "storage.plugin"],
    contributions: String? = nil,
    settingsURL: String? = nil,
    files: [String: Data] = [:]
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "TetherPluginHost-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appending(path: "web"), withIntermediateDirectories: true)
    let page = Data("<!DOCTYPE html><html><body>fixture</body></html>".utf8)
    try page.write(to: root.appending(path: "web").appending(path: "index.html"))
    let body = contributions ?? """
      [{"kind":"viewer","id":"viewer/fixture","suffixes":[\(suffixes.map { "\"\($0)\"" }.joined(separator: ","))]},{"kind":"command","id":"command/fixture"},{"kind":"panel","id":"panel/fixture"}]
      """
    let settings = settingsURL.map { ",\"settingsURL\":\"\($0)\"" } ?? ""
    let manifest = """
      {"id":"\(id)","name":"Fixture","publisher":"Fixture","version":"0.1.0","api":1,"runtime":"\(runtime)","entrypoint":"web/index.html","ageRating":"4+","link":"https://example.com/plugins/\(id)","permissions":[\(permissions.map { "\"\($0)\"" }.joined(separator: ","))],"contributions":\(body)\(settings)}
      """
    try Data(manifest.utf8).write(to: root.appending(path: "manifest.json"))
    for (name, data) in files {
      let url = root.appending(path: name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
    return root
  }
}

func request(_ method: String, session: UUID, payload: JSONValue, id: String = "1") -> RPCRequest {
  RPCRequest(session: session, id: id, method: method, payload: payload)
}
