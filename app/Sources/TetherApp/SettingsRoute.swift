import SwiftUI

/// Hosts are managed in one place: Settings ▸ Identities. Every way in — the
/// host picker's list and add buttons, Edit… and Identity… on a host, Manage
/// Hosts, a password manager's export — opens that window at that page, and
/// pushes what it asked for over the host list. None of them is a window of
/// its own, which would be a second copy of the same page.
@MainActor
@Observable
final class SettingsRoute {
  static let shared = SettingsRoute()

  /// What is pushed over the host list.
  enum Page: Hashable {
    /// A host's identity and authentication.
    case host(UUID)
    /// Its address, account and secret.
    case edit(UUID)
    case newHost
    /// The export a password manager sent (`CredentialImport`).
    case importing
  }

  /// A phone pushes the section too, from the list Settings opens on.
  enum Destination: Hashable {
    case section(AppSettings.Section)
    case page(Page)
  }

  /// The pages over the host list, deepest last.
  var pages: [Page] = []
  /// The section a phone has pushed. A Mac keeps its own (`SettingsSectionPreference`).
  var phoneSection: AppSettings.Section?
  /// Bumped to ask whoever presents Settings on this platform to present it.
  private(set) var requests = 0

  /// Opens Settings at the host list, with `page` over it.
  func show(_ page: Page? = nil) {
    SettingsSectionPreference.show(.identities)
    phoneSection = .identities
    pages = page.map { [$0] } ?? []
    requests += 1
  }

  /// Back to whatever was under the page that finished.
  func pop() {
    if !pages.isEmpty { pages.removeLast() }
  }

  /// A phone's whole stack, section first.
  var phonePath: [Destination] {
    get { (phoneSection.map { [Destination.section($0)] } ?? []) + pages.map(Destination.page) }
    set {
      guard case .section(let section)? = newValue.first else {
        phoneSection = nil
        pages = []
        return
      }
      phoneSection = section
      pages = newValue.dropFirst().compactMap {
        if case .page(let page) = $0 { return page }
        return nil
      }
    }
  }
}
