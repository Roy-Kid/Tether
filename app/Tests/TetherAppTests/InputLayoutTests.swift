#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TetherUI
@testable import TetherApp

// SwiftUI windows share AppKit focus and keyboard shortcuts. Keep layout
// fixtures from taking focus away from the keyboard interaction tests.
@MainActor
@Suite("macOS UI", .serialized)
struct MacUITests {}

extension MacUITests {
@MainActor
@Suite("Input layout at supported window widths", .serialized)
struct InputLayoutTests {
  private func fields(in view: NSView) -> [NSTextField] {
    guard !view.isHidden else { return [] }
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap { fields(in: $0) }
  }

  @Test("search and form inputs remain usable when empty and after resizing",
    arguments: ["sidebar", "hostPicker", "palette", "hostEditor", "managedHostEditor", "identity", "keyBindings", "authorization"])
  func inputs(surface: String) async throws {
    _ = NSApplication.shared
    let file = temporaryFile("hosts")
    defer { removeDirectory(of: file) }
    let secrets = MemorySecrets()
    let store = HostStore(location: file, secrets: secrets)
    let tabs = TabSet()
    let view: AnyView
    let width: CGFloat
    switch surface {
    case "sidebar":
      view = AnyView(Sidebar(store: store, onOpen: { _ in }, onEdit: { _ in }, onNew: {}, onSettings: {}))
      width = 210
    case "hostPicker":
      view = AnyView(HostPicker(tabs: tabs, store: store))
      width = UIStyle.pickerWidth + 20
    case "palette":
      view = AnyView(PalettePanel(kind: .command, query: .constant(""), items: [], listHeight: 200, onCancel: {}))
      width = UIStyle.panelWidth
    case "hostEditor":
      view = AnyView(HostEditor(host: .blank()) { _, _ in true })
      width = Chrome.editorWidth
    case "managedHostEditor", "identity":
      let identity = AccountIdentity(name: "Test identity")
      let profile = HostProfile(id: UUID(), label: "Test", hostname: "example.invalid", port: 22, username: "test",
        authentication: AuthenticationProfile(identity: identity,
          primary: CredentialDescriptor(identityID: identity.id, purpose: .password),
          otp: CredentialDescriptor(identityID: identity.id, purpose: .totp)))
      let host = Host(id: profile.id, label: profile.label, hostname: profile.hostname, port: profile.port,
        username: profile.username, profile: profile)
      if surface == "managedHostEditor" {
        view = AnyView(HostEditor(host: host) { _, _ in true })
        width = Chrome.editorWidth
      } else {
        try #require(store.save(host))
        view = AnyView(HostIdentitySettings(store: store, id: host.id))
        width = UIStyle.sheetWidth
      }
    case "keyBindings":
      view = AnyView(KeyBindingSettings(store: tabs.keyBindings, commands: WorkspaceAction.available.map(\.command)))
      width = 560
    default:
      view = AnyView(Form { AuthorizationSettings(store: store, host: .blank(), connections: nil) }
        .formStyle(.grouped))
      width = UIStyle.sheetWidth
    }
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: view)
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    for size in [width, width + 200, width] {
      window.setContentSize(NSSize(width: size, height: 600))
      try await Task.sleep(for: .milliseconds(200))
      let content = try #require(window.contentView)
      content.layoutSubtreeIfNeeded()
      let inputs = fields(in: content)
      try #require(!inputs.isEmpty)
      for field in inputs {
        #expect(field.bounds.width >= 40, "\(surface): \(field.placeholderString ?? "input") width")
        #expect(field.bounds.height >= 14, "\(surface): input height")
      }
    }
  }
}
}
#endif
