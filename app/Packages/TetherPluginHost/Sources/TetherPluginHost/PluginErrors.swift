import Foundation

extension PluginHostError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .package(let failure): failure.errorDescription
    case .duplicate(let id): "\(id) is already installed."
    case .unknownPlugin(let id): "\(id) is not installed."
    case .disabled(let id): "\(id) is disabled."
    case .consentDenied: "Permission was declined."
    case .noSession: "The plugin session has closed."
    case .permissionDenied: "The plugin has not declared this permission."
    case .notARepository: "The address is not a GitHub repository."
    case .noRelease: "This repository has no release."
    case .remoteUnavailable: "GitHub did not return the latest release."
    case .archiveUnreadable: "The release archive could not be read."
    case .archiveTooLarge: "The release archive is too large."
    }
  }
}

extension PackageFailure: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unreadable: "The plugin package could not be read."
    case .manifestMissing(let path): "No manifest.json was found in \(path). Choose the plugin package folder containing manifest.json."
    case .manifestUnreadable(let path, let reason): "Could not read \(path): \(reason)"
    case .malformed: "The plugin manifest is invalid or has changed since installation."
    case .unsupportedRuntime(let kind): "Unsupported plugin runtime: \(kind)."
    case .unsupportedAPI(let version): "Unsupported plugin API: \(version)."
    case .entrypointEscapes: "The plugin entrypoint must stay inside its package."
    case .entrypointMissing: "The plugin HTML entrypoint is missing."
    case .forbiddenPayload(let file): "The plugin contains a forbidden file: \(file)."
    case .installScript(let file): "Plugin install scripts are not supported: \(file)."
    case .emptyIdentity: "The plugin manifest is missing its identity."
    case .invalidLink: "The plugin publisher link is invalid."
    case .unknownPermission(let token): "Unknown plugin permission: \(token)."
    case .unknownContribution(let kind): "Unknown plugin contribution: \(kind)."
    case .duplicateContribution(let id): "Duplicate plugin contribution: \(id)."
    case .invalidNetworkURL(let url): "Unsupported network endpoint: \(url)."
    }
  }
}
