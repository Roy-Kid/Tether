import Foundation
import Testing

@testable import TetherApp

/// Reading `~/.ssh/config`.
///
/// The file is the person's, not the app's, and `ssh` reads it too. What
/// these assert is that the app reads it the way `ssh` does — the same host,
/// the same user, the same key — because an answer that differs from ssh's
/// is worse than no answer.
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
  @Test("a quoted name with a space in it is one host")
  func quotedNames() {
    let config = SSHConfig("Host \"Lab machine\"\n  HostName 10.0.0.4\n")
    #expect(config.entries.map(\.alias) == ["Lab machine"])
  }

  /// `Host *` is settings for other hosts, not a machine anyone can reach.
  @Test("a pattern is not offered as a host")
  func patternsAreNotHosts() {
    #expect(SSHConfig(Self.sample).entries.contains { $0.alias == "*" } == false)
  }

  /// A key path comes back exactly as it was written. `~/.ssh/id_lab`
  /// survives the account being moved and the file being copied to another
  /// machine — which people do with this file.
  @Test("a key path is read exactly as it is written down")
  func keyPathsAreNotRewritten() {
    #expect(SSHConfig(Self.sample).entries[0].identityFile == "~/.ssh/id_lab")
    #expect(expandingTilde("~/.ssh/id_x") == NSHomeDirectory() + "/.ssh/id_x")
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

  /// Settings above the first `Host` line apply to every host, the same as
  /// under `Host *`. Skipping them would offer a user ssh would not use.
  @Test("settings before the first Host apply to every host")
  func preambleApplies() {
    let entries = SSHConfig("User everyone\n\nHost lab\n  HostName 10.0.0.4\n").entries
    #expect(entries.first?.user == "everyone")
  }

  /// OrbStack, Colima and most dotfile managers write `Include` at the top
  /// of the file. Its hosts are hosts, and its settings reach the hosts
  /// below it, because that is what ssh does with it.
  @Test("an Include is read where it stands")
  func includesAreRead() {
    let files = ["orb/*": ["Host orb\n  HostName 127.0.0.1\n  Port 32222\n"], "common": ["User shared\n"]]
    let config = SSHConfig(
      """
      Include orb/*
      Include common

      Host lab
        HostName 10.0.0.4
      """
    ) { argument in (files[argument] ?? []).map { SSHConfig.Source(path: argument, text: $0) } }

    #expect(config.entries.map(\.alias) == ["orb", "lab"])
    #expect(config.entries[0].port == 32222)
    #expect(config.entries[1].user == "shared", "a top-level Include is a top-level setting")
  }

  /// Inside a stanza, an included file is read only for hosts that stanza
  /// matches, and the lines after the `Include` still belong to it.
  @Test("an Include inside a stanza stays inside it")
  func includeInsideAStanza() {
    let config = SSHConfig(
      """
      Host work-*
        Include work
        User worker

      Host home
        HostName 192.168.1.2
      """
    ) { $0 == "work" ? [SSHConfig.Source(path: "work", text: "Port 2200\nHost work-db\n  HostName db.internal\n")] : [] }

    let work = config.entries.first { $0.alias == "work-db" }
    #expect(work?.hostName == "db.internal")
    #expect(work?.port == 2200)
    #expect(work?.user == "worker", "the stanza resumes after the Include")
    #expect(config.entries.first { $0.alias == "home" }?.port == nil, "not a work host")
  }

  /// A file that includes itself is read as deep as ssh would, then stops.
  @Test("a file that includes itself ends")
  func includeCycleEnds() {
    let config = SSHConfig("Include self\nHost lab\n  HostName x\n") { _ in [SSHConfig.Source(path: "self", text: "Include self\n")] }
    #expect(config.entries.map(\.alias) == ["lab"])
  }

  /// Relative paths are relative to the config's directory, globs expand in
  /// sorted order, and Tether's own export is not read back as strangers.
  @Test("files are read from beside the config, without Tether's own")
  func readsFilesFromDisk() throws {
    let config = temporaryFile("config")
    defer { removeDirectory(of: config) }
    let directory = config.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory.appending(path: "config.d"), withIntermediateDirectories: true)
    try "Host b\n  HostName b.example\n".write(to: directory.appending(path: "config.d/2-b"), atomically: true, encoding: .utf8)
    try "Host a\n  HostName a.example\n".write(to: directory.appending(path: "config.d/1-a"), atomically: true, encoding: .utf8)
    let exported = directory.appending(path: "tether_config")
    try "Host managed\n  HostName m.example\n".write(to: exported, atomically: true, encoding: .utf8)
    try "Include \"\(exported.path)\"\nInclude config.d/*\nInclude missing/*\n".write(to: config, atomically: true, encoding: .utf8)

    let entries = try SSHConfig.read(config, skipping: [exported]).entries
    #expect(entries.map(\.alias) == ["a", "b"])
    #expect(entries.map { $0.file.map { URL(fileURLWithPath: $0).lastPathComponent } } == ["1-a", "2-b"], "each knows its file")
  }

  /// The regression that made import impossible: exporting writes an
  /// `Include` into the config, and any `Include` used to refuse every host.
  @Test("an Include does not stop a host being imported")
  func includeDoesNotBlockImport() {
    let config = SSHConfig("Include \"/Users/ada/.ssh/tether_config\"\n\nHost lab\n  HostName 10.0.0.4\n")
    #expect(config.importLimitations(alias: "lab").isEmpty)
  }

  /// A typical Mac config. None of it decides where ssh connects or who logs
  /// in, so none of it is a reason to refuse.
  @Test("settings that only tune ssh do not stop an import")
  func tuningDoesNotBlockImport() {
    let config = SSHConfig(
      """
      Host lab
        HostName 10.0.0.4
        IdentityFile ~/.ssh/id_lab
        LocalForward 8888 localhost:8888

      Host *
        AddKeysToAgent yes
        UseKeychain yes
        ServerAliveInterval 30
        IdentityFile ~/.ssh/id_ed25519
        IdentityAgent "~/Library/Group Containers/agent.sock"
      """)
    #expect(config.importLimitations(alias: "lab").isEmpty)
    #expect(config.entries.first?.identityFile == "~/.ssh/id_lab", "the one ssh tries first")
  }

  /// A jump host, a proxy or a remote command changes which machine answers
  /// or what runs there; a profile without it would be a different host.
  @Test("a route or a command stops only the hosts it applies to")
  func routesBlockTheirOwnHosts() {
    let config = SSHConfig(
      """
      Host inside
        HostName 10.0.0.9
        ProxyJump bastion

      Host lab
        HostName 10.0.0.4

      Match host inside exec "true"
        User nobody
      """)
    #expect(config.importLimitations(alias: "inside") == ["match", "proxyjump"])
    #expect(config.importLimitations(alias: "lab") == ["match"], "a Match that could set the user cannot be ruled out")
    #expect(SSHConfig("Host lab\n  HostName x\nMatch all\n  ServerAliveInterval 5\n").importLimitations(alias: "lab").isEmpty,
      "a Match that only tunes ssh changes nothing")
  }
}
