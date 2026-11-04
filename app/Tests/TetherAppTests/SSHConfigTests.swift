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

  /// ssh resolves a setting from the first stanza that matches, wildcard
  /// stanzas included. A client that ignored them would offer to connect as
  /// a different user than `ssh` would, which is a worse answer than none.
  @Test("a wildcard stanza supplies what a host leaves unsaid")
  func wildcardsApply() {
    let entries = SSHConfig(Self.sample).entries

    #expect(entries[0].user == "ada", "lab says nothing, so Host * answers")
    #expect(entries[1].user == "grace", "its own, which it reached first")
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
