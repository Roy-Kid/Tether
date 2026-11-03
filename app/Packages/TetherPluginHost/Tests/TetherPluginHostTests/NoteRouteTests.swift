import Testing
import UserNotifications
@testable import TetherPluginHost

@Test @MainActor
func aNotificationNamesItsPlugin() {
  let content = SystemNote.content(title: "Ready", body: "done", source: "Nerve", pluginID: "nerve")
  #expect(content.title == "Nerve")
  #expect(content.body == "Ready\ndone")
  #expect(PluginNote.pluginID(in: content.userInfo) == "nerve")
}

@Test @MainActor
func aNotificationWithoutAPluginDoesNotRoute() {
  let content = SystemNote.content(title: "Live Activities", body: "Off", source: "", pluginID: "")
  #expect(content.title == "Live Activities")
  #expect(content.body == "Off")
  #expect(PluginNote.pluginID(in: content.userInfo) == nil)
}
