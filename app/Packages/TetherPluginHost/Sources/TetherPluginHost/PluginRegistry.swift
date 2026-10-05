import Foundation

@MainActor
final class PluginRegistry {
  private(set) var records: [PluginRecord] = []
  private(set) var index = ContributionIndex()

  func record(_ id: String) -> PluginRecord? {
    records.first { $0.id == id }
  }

  @discardableResult
  func install(directory: URL) throws -> PluginRecord {
    let manifest: PluginManifest
    do {
      manifest = try PackageValidator.validate(directory: directory)
    } catch let failure as PackageFailure {
      throw PluginHostError.package(failure)
    }
    if records.contains(where: { $0.id == manifest.id }) {
      throw PluginHostError.duplicate(manifest.id)
    }
    let record = PluginRecord(
      manifest: manifest,
      source: PluginSource(local: directory.standardizedFileURL),
      status: .registered,
      enabled: true)
    records.append(record)
    rebuild()
    return record
  }

  func uninstall(id: String) throws {
    guard records.contains(where: { $0.id == id }) else { throw PluginHostError.unknownPlugin(id) }
    records.removeAll { $0.id == id }
    rebuild()
  }

  func setEnabled(_ enabled: Bool, id: String) throws {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw PluginHostError.unknownPlugin(id)
    }
    records[index].enabled = enabled
    rebuild()
  }

  func setStatus(_ status: PluginStatus, id: String) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].status = status
  }

  private func rebuild() {
    var index = ContributionIndex()
    for record in records where record.enabled {
      index.add(record)
    }
    self.index = index
  }
}
