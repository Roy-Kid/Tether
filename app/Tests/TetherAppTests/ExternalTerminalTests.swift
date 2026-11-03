#if os(macOS)
import Foundation
import Testing
@testable import TetherApp
import TetherPluginKit

@Suite("Landing on a terminal")
struct ExternalTerminalTests {
  @Test func aNamedTTYIsTheOnlyScriptTerminalAccepts() {
    let script = ExternalTerminal.script(device: "/dev/ttys006")
    #expect(script?.contains("\"/dev/ttys006\"") == true)
    #expect(ExternalTerminal.script(device: "/dev/pts/3") != nil)
    #expect(ExternalTerminal.script(device: "/dev/ttys006; beep") == nil)
    #expect(ExternalTerminal.script(device: "file:///tmp") == nil)
    #expect(ExternalTerminal.script(device: "/tmp/ttys006") == nil)
  }

  @Test func aDirectoryDoesNotLeaveTheApp() {
    #expect(FocusLink.url("file:///Users/roykid/work/Nerve") == nil)
    #expect(FocusLink.url("vscode://file/Users/roykid/work/Nerve")?.scheme == "vscode")
  }

  @Test func thisMacIsItsBonjourNameWhateverNetworkItIsOn() {
    #expect(LocalMachine.resolve(bonjour: "RoydeMacBook-Air", kernel: "roydeair.kemi.uu.se")
      == "roydemacbook-air.local")
    #expect(LocalMachine.resolve(bonjour: nil, kernel: "Studio") == "studio")
    #expect(LocalMachine.resolve(bonjour: " ", kernel: "Studio") == "studio")
    #expect(LocalMachine.name.hasSuffix(".local"))
  }

  @Test func oneComparisonNamesATerminal() {
    let tab = PluginTerminalIdentity(host: "Arrhenius", terminal: "/dev/pts/3")
    #expect(tab.matches(PluginTerminalIdentity(host: "arrhenius", terminal: "pts/3")))
    #expect(!tab.matches(PluginTerminalIdentity(host: "arrhenius1.kemi.uu.se", terminal: "/dev/pts/3")))
    #expect(!tab.matches(PluginTerminalIdentity(host: "arrhenius", terminal: "/dev/pts/4")))
  }
}
#endif
