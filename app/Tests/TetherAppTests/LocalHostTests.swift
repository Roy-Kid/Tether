import Foundation
import Tether
import Testing

@testable import TetherApp

// `Foundation` exports a `Host` of its own, and qualifying by module name does
// not help here — the app's `@main` type is also called `TetherApp`. Importing
// the one type by name settles it.
import struct TetherApp.Host

/// The machine the app is running on, as the host list sees it.
///
/// What is being protected here is an absence. There is no kind field, no
/// second list and no branch in the view layer — a local terminal is a host
/// that opens into the same session as any other. These tests fail the moment
/// someone starts to make it a category of its own, because a category would
/// have to be stored, filtered or deleted differently, and each of those is
/// asserted below.
@MainActor
@Suite("The local host")
struct LocalHostTests {
  static func store() -> (HostStore, URL) {
    let location = temporaryFile("config")
    return (HostStore(location: location, secrets: MemorySecrets(), credentials: DeviceCredentialStore(secrets: MemorySecrets())), location)
  }

  static func host(_ label: String = "lab") -> Host {
    Host(label: label, hostname: "10.0.0.4", port: 22, username: "scientist", keyPath: nil)
  }

  @Test("is listed first, above the saved hosts")
  func isListedFirst() {
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    store.save(Self.host())

    #expect(store.listed.first?.isLocal == true)
    #expect(store.listed.count == store.hosts.count + 1)
  }

  @Test("is never written to the host file")
  func isNeverPersisted() {
    // The file is the person's ssh config, which `ssh` reads too. A row this
    // app invented has no business in it: `ssh localhost` is a real thing
    // that means something else, and a stanza claiming otherwise would be
    // this app answering a question nobody asked it.
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    store.save(.local)
    store.save(Self.host())

    #expect(store.hosts.contains { $0.isLocal } == false)

    let written = (try? String(contentsOf: location, encoding: .utf8)) ?? ""
    #expect(!written.contains("localhost"))
    #expect(store.snapshot.records.values.contains { $0.profile.label == "lab" })
    #expect(store.snapshot.records[Host.localID] == nil)
  }

  @Test("cannot be deleted out of the list")
  func cannotBeDeleted() {
    // A person must not be able to make their own computer unreachable from
    // an app running on it, with nothing to bring it back.
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    store.delete(.local)

    #expect(store.listed.contains { $0.isLocal })
  }

  @Test("is recognised by identity, not by its hostname")
  func isRecognisedByIdentity() {
    // `localhost` over SSH is an ordinary thing to want — a forwarded port
    // into a container is reached that way every day. Guessing from the name
    // would take that connection away from whoever set it up.
    let overSSH = Host(
      label: "container", hostname: "localhost", port: 2222, username: "root", keyPath: nil)

    #expect(overSSH.isLocal == false)
    #expect(Host.local.isLocal)
  }

}

/// Opening a terminal on this machine when the app starts.
@MainActor
@Suite("The launch preference")
struct LaunchPreferenceTests {

}

@MainActor
@Suite("The last-tab preference")
struct LastTabPreferenceTests {
}
