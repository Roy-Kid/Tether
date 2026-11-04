import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Touch workspace")
struct TouchWorkspaceTests {
  private let known = KnownHosts(location: URL(fileURLWithPath: "/dev/null"))

  private func tab(_ name: String, host: Host = .local) -> SessionTab {
    SessionTab(preview: host, known: known, name: name, live: false)
  }

  private func host(_ label: String) -> Host {
    var host = Host.blank()
    host.label = label
    host.hostname = "\(label).example"
    return host
  }

  @Test("a phone keeps the portrait stack, including when landscape reports a regular width")
  func phoneStaysStacked() {
    #expect(!TouchLayout.wide(phone: true, regularWidth: true, regularHeight: false))
    #expect(!TouchLayout.wide(phone: true, regularWidth: false, regularHeight: true))
    #expect(!TouchLayout.wide(phone: true, regularWidth: true, regularHeight: true))
    #expect(!TouchLayout.wide(phone: false, regularWidth: true, regularHeight: false))
    #expect(!TouchLayout.wide(phone: false, regularWidth: false, regularHeight: true))
    #expect(TouchLayout.wide(phone: false, regularWidth: true, regularHeight: true))
    #expect(TouchLayout.popsToHostList(phone: true, compactWidth: false))
    #expect(TouchLayout.popsToHostList(phone: false, compactWidth: true))
    #expect(!TouchLayout.popsToHostList(phone: false, compactWidth: false))
  }

}
