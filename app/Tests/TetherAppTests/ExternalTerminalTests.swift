#if os(macOS)
import Foundation
import Testing
@testable import TetherApp

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

  @Test func theLocalHostMatchesWithOrWithoutTheLocalSuffix() {
    #expect(TabSet.sameMachine("roydemacbook-air.local", "RoydeMacBook-Air.local"))
    #expect(TabSet.sameMachine("roydemacbook-air", "RoydeMacBook-Air.local"))
    #expect(!TabSet.sameMachine("gpu.example", "RoydeMacBook-Air.local"))
    #expect(!TabSet.sameMachine("", "RoydeMacBook-Air.local"))
    let names = LocalMachine.spellings(kernel: "RoydeAir.kemi.uu.se", bonjour: "roydemacbook-air.local")
    #expect(LocalMachine.same("roydeair.kemi.uu.se", "roydemacbook-air.local", names: names))
    #expect(!LocalMachine.same("gpu.example", "roydemacbook-air.local", names: names))
    #expect(TabSet.sameMachine(LocalMachine.kernelName, ProcessInfo.processInfo.hostName))
  }
}
#endif
