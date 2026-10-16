import AuthenticationServices
import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

/// What a password manager's export becomes: the secrets a host can use,
/// paired with the host they name, and nothing else.
@Suite("Credential Exchange import")
struct CredentialExchangeTests {
  static let seed = Data((1...20).map(UInt8.init))

  static func item(_ title: String, urls: [String] = [], _ credentials: [ASImportableCredential]) -> ASImportableItem {
    ASImportableItem(id: Data(title.utf8), created: Date(), lastModified: Date(), title: title,
      scope: urls.isEmpty ? nil : ASImportableCredentialScope(urls: urls.compactMap(URL.init(string:))),
      credentials: credentials)
  }

  static func login(_ user: String, _ password: String) -> ASImportableCredential {
    .basicAuthentication(.init(userName: .init(id: nil, fieldType: .string, value: user),
      password: .init(id: nil, fieldType: .concealedString, value: password)))
  }

  static func code(_ user: String?, secret: Data = seed, digits: UInt16 = 6) -> ASImportableCredential {
    .totp(.init(secret: secret, period: 30, digits: digits, userName: user, algorithm: .sha1))
  }

  static func export(_ items: [ASImportableItem]) -> ASExportedCredentialData {
    ASExportedCredentialData(
      accounts: [ASImportableAccount(id: Data("me".utf8), userName: "", email: "", collections: [], items: items)],
      formatVersion: .v1, exporterRelyingPartyIdentifier: "apple.com", exporterDisplayName: "Passwords",
      timestamp: Date())
  }

  static func host(_ label: String, _ hostname: String, _ user: String) -> Host {
    Host(label: label, hostname: hostname, port: 22, username: user)
  }

  /// The shape Passwords exported in the field: a code under the stanza's
  /// name with no URL, beside a website's login, beside a passkey.
  @Test func onlyWhatAHostCanUseIsKept() throws {
    let passkey = ASImportableCredential.passkey(.init(credentialID: Data([1]), relyingPartyIdentifier: "example.com",
      userName: "ada", userDisplayName: "Ada", userHandle: Data([2]), key: Data([3])))
    let items = CredentialExchange.items(in: Self.export([
      Self.item("Arrhenius", [Self.code("jicli594")]),
      Self.item("github.com", urls: ["https://github.com"], [Self.login("ada", "pw"), Self.code("ada")]),
      Self.item("example.com", [passkey]),
    ]))
    #expect(items.map(\.title) == ["Arrhenius", "github.com"])
    let arrhenius = try #require(items.first)
    #expect(arrhenius.userName == "jicli594")
    #expect(arrhenius.secrets.code == (try TOTP(secret: Self.seed)))
    #expect(arrhenius.secrets.password == nil)
    #expect(items[1].names == ["github.com"])
    #expect(items[1].secrets.password == "pw")
  }

  @Test func aSeedOutsideTheLimitsIsDropped() {
    let items = CredentialExchange.items(in: Self.export([
      Self.item("short", [Self.code("ada", secret: Data([1, 2, 3]))]),
      Self.item("seven", [Self.code("ada", digits: 7)]),
    ]))
    #expect(items.isEmpty)
  }

  /// A host is named by its title or a URL's host, and only for its own
  /// account. A name shared by two hosts, or a host named twice, is left to
  /// the person.
  @Test func itemsGoToTheOneHostTheyName() throws {
    let lab = Self.host("Arrhenius", "arrhenius3.hpc.arrhenius.naiss.se", "jicli594")
    let other = Self.host("build", "build.example.org", "ci")
    let twins = [Self.host("twin", "a.example.org", "ada"), Self.host("twin", "b.example.org", "ada")]
    let items = CredentialExchange.items(in: Self.export([
      Self.item("arrhenius", [Self.code("jicli594")]),
      Self.item("Login", urls: ["https://build.example.org/login"], [Self.login("ci", "pw")]),
      Self.item("build", [Self.login("somebody-else", "pw")]),
      Self.item("twin", [Self.login("ada", "pw")]),
    ]))
    let choices = CredentialExchange.choices(for: items, hosts: [lab, other] + twins)
    #expect(choices.map(\.host) == [lab.id, other.id, nil, nil])
    #expect(choices[0].code && !choices[0].password && !choices[0].privateKey)
    #expect(choices[1].password)

    let twice = CredentialExchange.items(in: Self.export([
      Self.item("Arrhenius", [Self.code("jicli594")]),
      Self.item("arrhenius3.hpc.arrhenius.naiss.se", [Self.login("jicli594", "pw")]),
    ]))
    #expect(CredentialExchange.choices(for: twice, hosts: [lab]).map(\.host) == [nil, nil])
  }

  /// What a host already has is not replaced unless the person says so.
  @Test func whatAHostHasIsNotChosenForIt() throws {
    var lab = Self.host("lab", "lab.example.org", "ada")
    lab.remembersPassword = true
    lab.otpSecretID = UUID()
    let items = CredentialExchange.items(in: Self.export([Self.item("lab", [Self.login("ada", "pw"), Self.code("ada")])]))
    let choice = try #require(CredentialExchange.choices(for: items, hosts: [lab]).first)
    #expect(choice.host == lab.id)
    #expect(!choice.password && !choice.code)
    #expect(!choice.takesAnything)
  }

  /// A host picked by hand is chosen for the same way: what it has stays.
  @Test func aHostPickedByHandKeepsWhatItHas() {
    var lab = Self.host("lab", "lab.example.org", "ada")
    lab.credentialSecretID = UUID()
    let pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"
    let item = CredentialExchange.Item(id: Data([1]), title: "elsewhere", userName: nil, names: ["elsewhere"],
      secrets: .init(password: "pw", privateKey: pem))
    let picked = CredentialExchange.choice(item, for: lab)
    #expect(picked.host == lab.id)
    #expect(picked.password && !picked.privateKey)
  }

  /// PKCS#8 DER becomes PEM; the text of a key file stays as it is.
  @Test func aPrivateKeyIsKeptAsPEM() throws {
    let der = Data([0x30, 0x2e, 0x02, 0x01, 0x00]) + Data(repeating: 7, count: 43)
    let pem = try #require(CredentialExchange.privateKey(der))
    #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
    #expect(pem.hasSuffix("\n-----END PRIVATE KEY-----\n"))
    #expect(HostStore.looksLikePrivateKey(pem))
    let file = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
    #expect(CredentialExchange.privateKey(Data(file.utf8)) == file + "\n")
    #expect(CredentialExchange.privateKey(Data("not a key".utf8)) == nil)
  }
}
