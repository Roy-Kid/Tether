import Foundation
import Testing
@testable import TetherApp

@Test
func aPluginLinkNamesThePlugin() throws {
  let url = try #require(PluginReturn.url(pluginID: "nerve.jobs"))
  #expect(url.absoluteString == "tether://plugin/nerve.jobs")
  #expect(PluginReturn.pluginID(from: url) == "nerve.jobs")
}

@Test
func aPluginLinkKeepsAnOddID() throws {
  let url = try #require(PluginReturn.url(pluginID: "a b/c"))
  #expect(PluginReturn.pluginID(from: url) == "a b/c")
}

@Test
func anotherAddressIsNotAPlugin() throws {
  let url = try #require(URL(string: "https://plugin/nerve"))
  #expect(PluginReturn.pluginID(from: url) == nil)
  #expect(PluginReturn.url(pluginID: "") == nil)
}
