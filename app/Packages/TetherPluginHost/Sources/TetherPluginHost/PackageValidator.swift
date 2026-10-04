import Foundation

public enum PackageFailure: Error, Equatable {
  case unreadable
  case malformed
  case unsupportedRuntime(String)
  case unsupportedAPI(Int)
  case entrypointEscapes
  case entrypointMissing
  case forbiddenPayload(String)
  case installScript(String)
  case emptyIdentity
  case invalidLink
  case unknownPermission(String)
  case unknownContribution(String)
  case duplicateContribution(String)
}

enum PackagePaths {
  static func resolve(_ relative: String, in root: URL) -> URL? {
    if relative.hasPrefix("/") || relative.isEmpty { return nil }
    var url = root
    for part in relative.split(separator: "/", omittingEmptySubsequences: false) {
      if part.isEmpty || part == "." || part == ".." { return nil }
      url.append(path: String(part))
    }
    return url.standardizedFileURL
  }
}

enum PackageRoot {
  static func contains(_ url: URL, root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path == rootPath || path.hasPrefix(rootPath + "/")
  }
}

enum PackageValidator {
  private static let forbiddenExtensions: Set<String> = [
    "dylib", "so", "dll", "node", "pyd", "pyc", "pyo", "exe", "bin", "framework",
  ]
  private static let installerNames: Set<String> = [
    "requirements.txt", "setup.py", "pipfile", "pipfile.lock",
  ]
  private static let installHooks = ["install", "preinstall", "postinstall"]

  static func validate(directory: URL) throws -> PluginManifest {
    let root = directory.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw PackageFailure.unreadable }

    try rejectForbiddenPayload(in: root)
    let manifest = try readManifest(in: root)
    let entry = try entrypoint(manifest.entrypoint, in: root)
    guard FileManager.default.fileExists(atPath: entry.path) else {
      throw PackageFailure.entrypointMissing
    }
    let ext = entry.pathExtension.lowercased()
    guard ext == "html" || ext == "htm" else { throw PackageFailure.entrypointMissing }
    return manifest
  }

  private static func readManifest(in root: URL) throws -> PluginManifest {
    let url = root.appending(path: "manifest.json")
    guard let data = try? Data(contentsOf: url) else { throw PackageFailure.unreadable }
    let raw: RawManifest
    do {
      raw = try JSONDecoder().decode(RawManifest.self, from: data)
    } catch {
      throw PackageFailure.malformed
    }
    guard raw.runtime == PluginRuntimeKind.web.rawValue else {
      throw PackageFailure.unsupportedRuntime(raw.runtime)
    }
    guard raw.api == PluginManifest.api else { throw PackageFailure.unsupportedAPI(raw.api) }
    guard !raw.id.isEmpty, !raw.name.isEmpty, !raw.publisher.isEmpty, !raw.version.isEmpty,
      !raw.ageRating.isEmpty
    else { throw PackageFailure.emptyIdentity }
    guard let link = URL(string: raw.link), let scheme = link.scheme?.lowercased(),
      scheme == "https" || scheme == "http", link.host != nil
    else { throw PackageFailure.invalidLink }

    var permissions: [Permission] = []
    for token in raw.permissions {
      guard let permission = Permission(rawValue: token) else {
        throw PackageFailure.unknownPermission(token)
      }
      permissions.append(permission)
    }

    var seen: Set<String> = []
    var contributions: [Contribution] = []
    for rawContribution in raw.contributions {
      guard let kind = ContributionKind(rawValue: rawContribution.kind) else {
        throw PackageFailure.unknownContribution(rawContribution.kind)
      }
      guard !rawContribution.id.isEmpty else { throw PackageFailure.emptyIdentity }
      guard seen.insert(rawContribution.id).inserted else {
        throw PackageFailure.duplicateContribution(rawContribution.id)
      }
      let suffixes = (rawContribution.suffixes ?? []).map(ContributionIndex.normalize).filter { !$0.isEmpty }
      contributions.append(Contribution(id: rawContribution.id, kind: kind, suffixes: suffixes))
    }

    return PluginManifest(
      id: raw.id, name: raw.name, publisher: raw.publisher, version: raw.version, api: raw.api,
      runtime: .web, entrypoint: raw.entrypoint, ageRating: raw.ageRating, link: link,
      permissions: permissions, contributions: contributions)
  }

  private static func entrypoint(_ relative: String, in root: URL) throws -> URL {
    guard let entry = PackagePaths.resolve(relative, in: root), PackageRoot.contains(entry, root: root) else {
      throw PackageFailure.entrypointEscapes
    }
    return entry
  }

  private static func rejectForbiddenPayload(in root: URL) throws {
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isExecutableKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [])
    else { throw PackageFailure.unreadable }

    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true {
        let destination = url.resolvingSymlinksInPath()
        guard PackageRoot.contains(destination, root: root) else {
          throw PackageFailure.forbiddenPayload(url.lastPathComponent)
        }
      }
      let name = url.lastPathComponent
      let resolved = values.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
      let installer = installerNames.contains(name.lowercased())
        || installerNames.contains(resolved.lastPathComponent.lowercased())
      if installer { throw PackageFailure.installScript(name) }
      if forbiddenExtensions.contains(url.pathExtension.lowercased())
        || forbiddenExtensions.contains(resolved.pathExtension.lowercased())
      {
        throw PackageFailure.forbiddenPayload(name)
      }
      if name.lowercased() == "package.json" || resolved.lastPathComponent.lowercased() == "package.json" {
        try rejectInstallHooks(at: resolved)
      }
      let resolvedValues = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
      guard resolvedValues.isRegularFile == true else { continue }
      if resolvedValues.isExecutable == true {
        throw PackageFailure.forbiddenPayload(name)
      }
      if try looksNative(resolved) {
        throw PackageFailure.forbiddenPayload(name)
      }
    }
  }

  private static func rejectInstallHooks(at url: URL) throws {
    struct Scripts: Decodable { var install, preinstall, postinstall: String? }
    struct Document: Decodable { var scripts: Scripts? }
    guard let data = try? Data(contentsOf: url),
      let document = try? JSONDecoder().decode(Document.self, from: data),
      let scripts = document.scripts
    else { return }
    for hook in installHooks {
      let value: String? =
        switch hook {
        case "install": scripts.install
        case "preinstall": scripts.preinstall
        case "postinstall": scripts.postinstall
        default: nil
        }
      if value != nil { throw PackageFailure.installScript(hook) }
    }
  }

  /// Mach-O, ELF, or PE. `.wasm` is a web asset and is not one of these.
  private static func looksNative(_ url: URL) throws -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let header = [UInt8](try handle.read(upToCount: 4) ?? Data())
    if header.starts(with: [0x4d, 0x5a]) { return true }
    let native: [[UInt8]] = [
      [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
      [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
      [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
      [0x7f, 0x45, 0x4c, 0x46],
    ]
    return native.contains(header)
  }
}
