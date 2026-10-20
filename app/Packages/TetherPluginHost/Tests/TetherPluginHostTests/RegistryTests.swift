import Foundation
import Testing

@testable import TetherPluginHost

@Test func missingManifestIdentifiesTheSelectedFolder() throws {
  let root = try Fixture.make()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.removeItem(at: root.appending(path: "manifest.json"))
  #expect(throws: PackageFailure.manifestMissing(root.path)) {
    try PackageValidator.validate(directory: root)
  }
}

@Test func unreadableManifestPreservesTheFileAndReason() throws {
  let root = try Fixture.make()
  defer { try? FileManager.default.removeItem(at: root) }
  let manifest = root.appending(path: "manifest.json")
  try FileManager.default.removeItem(at: manifest)
  try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
  do {
    _ = try PackageValidator.validate(directory: root)
    Issue.record("a directory cannot be read as a manifest")
  } catch PackageFailure.manifestUnreadable(let path, let reason) {
    #expect(path == manifest.path)
    #expect(!reason.isEmpty)
  }
}

@Test @MainActor
func installRegistersContributionsWithoutASession() async throws {
  let consent = ScriptedConsent(allow: true)
  let host = PluginHost(consent: consent, presenting: RecordedPresenter())
  let root = try Fixture.make()
  let record = try host.install(directory: root)

  #expect(record.status == .registered)
  #expect(host.liveSessions.isEmpty)
  #expect(consent.asks.isEmpty)
  #expect(host.index.matches(suffix: "FIXTURE").map(\.contributionID) == ["viewer/fixture"])
  #expect(host.index.commands.map(\.contributionID) == ["command/fixture"])
  #expect(host.index.panels.map(\.contributionID) == ["panel/fixture"])
  #expect(record.manifest.link.scheme == "https")
  #expect(record.manifest.ageRating == "4+")
  #expect(record.source.kind == "local")
}

@Test @MainActor
func aNativeRuntimeIsRejected() throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let root = try Fixture.make(runtime: "native")
  #expect(throws: PluginHostError.package(.unsupportedRuntime("native"))) {
    try host.install(directory: root)
  }
  #expect(host.records.isEmpty)
}

@Test @MainActor
func aDynamicLibraryIsRejected() throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let root = try Fixture.make(files: ["payload.dylib": Data("not a library".utf8)])
  #expect(throws: PluginHostError.package(.forbiddenPayload("payload.dylib"))) {
    try host.install(directory: root)
  }
}

@Test @MainActor
func machOBytesAreRejected() throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let root = try Fixture.make(files: ["payload": Data([0xcf, 0xfa, 0xed, 0xfe])])
  #expect(throws: PluginHostError.package(.forbiddenPayload("payload"))) {
    try host.install(directory: root)
  }
}

@Test @MainActor
func anInstallScriptIsRejected() throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let script = Data(#"{"scripts":{"postinstall":"echo no"}}"#.utf8)
  let root = try Fixture.make(files: ["package.json": script])
  #expect(throws: PluginHostError.package(.installScript("postinstall"))) {
    try host.install(directory: root)
  }
}

@Test @MainActor
func disableAndUninstallRemoveContributions() async throws {
  let host = PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter())
  let record = try host.install(directory: try Fixture.make())
  let runtime = IdleRuntime()
  let session = try await host.activate(id: record.id, runtime: runtime)

  try host.setEnabled(false, id: record.id)
  #expect(host.index.matches(suffix: "fixture").isEmpty)
  #expect(host.index.commands.isEmpty)
  #expect(host.liveSessions.isEmpty)
  #expect(runtime.unloads == 1)
  #expect(host.record(record.id)?.enabled == false)
  _ = session

  try host.setEnabled(true, id: record.id)
  #expect(host.index.matches(suffix: "fixture").count == 1)
  try host.uninstall(id: record.id)
  #expect(host.records.isEmpty)
  #expect(host.index.panels.isEmpty)
}
