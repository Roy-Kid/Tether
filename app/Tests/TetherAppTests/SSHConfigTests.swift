import Foundation
import Testing

@testable import TetherApp

/// Reading and editing `~/.ssh/config`.
///
/// The file is the person's, not the app's. Most of what these assert is
/// therefore about what *stays*: a setting this app has never heard of, a
/// comment, an indentation style, the order the stanzas were written in.
/// Losing any of those is worse than not offering the feature, because the
/// file is the only copy and `ssh` reads it too.
@Suite("SSH config")
struct SSHConfigTests {
  static let sample = """
    Host lab
      HostName 10.0.0.4
      Port 2222
      IdentityFile ~/.ssh/id_lab
      ControlMaster auto

    Host cluster gateway
      HostName hpc.example.org
      User grace

    # Everything, everywhere
    Host *
      ForwardAgent no
      User ada
    """

  @Test("reads the hosts a file names")
  func readsHosts() {
    let entries = SSHConfig(Self.sample).entries

    #expect(entries.map(\.alias) == ["lab", "cluster"])
    #expect(entries[0].hostName == "10.0.0.4")
    #expect(entries[0].port == 2222)
    #expect(entries[1].hostName == "hpc.example.org")
    #expect(entries[1].port == nil)
  }

  /// ssh resolves a setting from the first stanza that matches, wildcard
  /// stanzas included. A client that ignored them would offer to connect as
  /// a different user than `ssh` would, which is a worse answer than none.
  @Test("a wildcard stanza supplies what a host leaves unsaid")
  func wildcardsApply() {
    let entries = SSHConfig(Self.sample).entries

    #expect(entries[0].user == "ada", "lab says nothing, so Host * answers")
    #expect(entries[1].user == "grace", "its own, which it reached first")
  }

  /// IdentityFile is inherited the same way User is. A `Host *` that names a
  /// key is how a person says "every machine uses this", and ignoring it
  /// would prompt them for a password `ssh` would never ask for.
  @Test("IdentityFile is inherited from a matching wildcard")
  func inheritedIdentityFile() {
    let entries = SSHConfig(
      """
      Host lab
        HostName 10.0.0.4

      Host *
        IdentityFile ~/.ssh/id_ed25519
      """
    ).entries

    #expect(entries.first?.identityFile == "~/.ssh/id_ed25519")
  }

  /// A blank line in the stanza is still the same host. Configs people write
  /// by hand look like this; treating the gap as the end of the host would
  /// drop the key sitting below it.
  @Test("a blank line does not drop IdentityFile")
  func identityFileAfterABlankLine() {
    let entries = SSHConfig(
      """
      Host Arrhenius
          HostName login.example
          User ada

          IdentityFile ~/.ssh/id_arrhenius_mac
          IdentitiesOnly yes
      """
    ).entries

    #expect(entries.first?.identityFile == "~/.ssh/id_arrhenius_mac")
  }

  /// *First* obtained, not most specific — which is why a person's `Host *`
  /// lives at the bottom of their file. Reading it the other way round would
  /// show a user here that `ssh` would not use.
  @Test("the first stanza to answer wins, wherever it is")
  func firstValueWins() {
    let entries = SSHConfig(
      """
      Host *
        User everyone

      Host lab
        HostName 10.0.0.4
        User ada
      """
    ).entries

    #expect(entries.first?.user == "everyone", "ssh would use this one too")
  }

  /// A name with a space in it is two patterns to ssh unless it is quoted,
  /// and "Lab machine" is a perfectly ordinary thing to call a computer.
  @Test("a name with a space in it survives being written and read")
  func quotedNames() {
    var config = SSHConfig("")
    config.write(
      SSHConfig.Entry(
        alias: "Lab machine", hostName: "10.0.0.4", user: "ada", port: 22, identityFile: nil))

    #expect(SSHConfig(config.text).entries.map(\.alias) == ["Lab machine"])
  }

  /// `Host *` is settings for other hosts, not a machine anyone can reach.
  @Test("a pattern is not offered as a host")
  func patternsAreNotHosts() {
    #expect(SSHConfig(Self.sample).entries.contains { $0.alias == "*" } == false)
  }

  /// A key path comes back exactly as it was written. `~/.ssh/id_lab`
  /// survives the account being moved and the file being copied to another
  /// machine — which people do with this file — and reading it, expanding it
  /// and writing it back would replace it with one that does neither.
  @Test("a key path is read and written exactly as it is written down")
  func keyPathsAreNotRewritten() {
    var config = SSHConfig(Self.sample)
    let key = config.entries[0].identityFile
    #expect(key == "~/.ssh/id_lab")

    config.write(config.entries[0])
    #expect(config.text == Self.sample + "\n")
  }

  /// The other direction: a path chosen in a file picker is absolute, and
  /// written down the way a person would have written it.
  @Test("a path inside the home directory is written with a tilde")
  func contractsTheHomeDirectory() {
    #expect(contractingHome(NSHomeDirectory() + "/.ssh/id_x") == "~/.ssh/id_x")
    #expect(contractingHome("/etc/ssh/id_x") == "/etc/ssh/id_x")
    #expect(expandingTilde("~/.ssh/id_x") == NSHomeDirectory() + "/.ssh/id_x")
  }

  /// The one that matters. Everything this app does not understand has to
  /// come back out of the file exactly as it went in.
  @Test("editing a host leaves the rest of the file alone")
  func editingPreservesEverything() {
    var config = SSHConfig(Self.sample)
    config.write(
      SSHConfig.Entry(
        alias: "lab", hostName: "10.0.0.9", user: "ada", port: 22, identityFile: nil))

    let text = config.text
    #expect(text.contains("# Everything, everywhere"))
    #expect(text.contains("ForwardAgent no"))
    #expect(text.contains("ControlMaster auto"))
    #expect(text.contains("Host cluster gateway"))
    #expect(text.contains("HostName 10.0.0.9"))
    // The port went back to the default and the key was cleared, so the lines
    // that said otherwise are gone rather than left to contradict the app.
    #expect(!text.contains("Port 2222"))
    #expect(!text.contains("IdentityFile"))
  }

  @Test("a setting is changed where it already sits")
  func editingKeepsTheLayout() {
    var config = SSHConfig(Self.sample)
    config.write(
      SSHConfig.Entry(
        alias: "lab", hostName: "10.0.0.9", user: "ada", port: 2222,
        identityFile: "/keys/id_lab"))

    let lines = config.text.components(separatedBy: "\n")
    let hostName = try? #require(lines.first { $0.contains("HostName 10.0.0.9") })
    #expect(hostName?.hasPrefix("  ") == true, "indentation follows the stanza it is in")
    #expect(lines.filter { $0.contains("HostName") }.count == 2, "changed, not added beside")
  }

  @Test("a new host is appended as a stanza of its own")
  func appending() {
    var config = SSHConfig(Self.sample)
    config.write(
      SSHConfig.Entry(
        alias: "newbox", hostName: "192.168.1.2", user: "root", port: 2022,
        identityFile: nil))

    let entries = config.entries
    #expect(entries.map(\.alias) == ["lab", "cluster", "newbox"])
    #expect(entries.last?.port == 2022)
    #expect(config.text.contains("Host newbox"))
  }

  /// A default port is not written. `Port 22` in a file that never had one is
  /// this app leaving fingerprints on something it does not own.
  @Test("the default port is not written down")
  func defaultPortIsSilent() {
    var config = SSHConfig("")
    config.write(
      SSHConfig.Entry(alias: "plain", hostName: "example.org", user: "ada", port: 22,
        identityFile: nil))

    #expect(!config.text.contains("Port"))
    #expect(config.entries.first?.port == nil)
  }

  @Test("renaming a host renames only its own name")
  func renaming() {
    var config = SSHConfig(Self.sample)
    config.write(
      SSHConfig.Entry(
        alias: "cluster-a", hostName: "hpc.example.org", user: "grace", port: 22,
        identityFile: nil),
      replacing: "cluster")

    #expect(config.text.contains("Host cluster-a gateway"), "the other name was not ours to take")
    #expect(config.entries.map(\.alias) == ["lab", "cluster-a"])
  }

  @Test("deleting a host takes its stanza and nothing after it")
  func deleting() {
    var config = SSHConfig(Self.sample)
    config.remove(alias: "lab")

    #expect(config.entries.map(\.alias) == ["cluster"])
    #expect(!config.text.contains("ControlMaster auto"))
    #expect(config.text.contains("Host cluster gateway"))
    #expect(config.text.contains("ForwardAgent no"))
  }

  @Test("a file is not grown by being read and written")
  func roundTripIsStable() {
    let once = SSHConfig(Self.sample).text
    let twice = SSHConfig(once).text

    #expect(once == twice)
  }

  /// ssh reads `Key=value` and `Key value` the same way, so both have to be
  /// understood or a host would silently lose its address.
  @Test("a setting written with an equals sign reads the same")
  func equalsSeparator() {
    let entries = SSHConfig("Host eq\n  HostName=10.1.1.1\n  Port = 2200\n").entries

    #expect(entries.first?.hostName == "10.1.1.1")
    #expect(entries.first?.port == 2200)
  }

  /// A `Match` block's settings belong to whatever it matched, not to the
  /// host above it.
  @Test("a Match block ends the stanza above it")
  func matchEndsAStanza() {
    let entries = SSHConfig(
      """
      Host lab
        HostName 10.0.0.4

      Match host nothing
        User nobody
      """
    ).entries

    #expect(entries.count == 1)
    #expect(entries.first?.user == nil, "the Match block's user is not the lab's")
  }
}
