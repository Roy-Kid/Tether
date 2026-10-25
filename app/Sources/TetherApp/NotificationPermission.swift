#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif
import TetherUI
import UserNotifications

/// First launch asks for notification permission. After a denial the system
/// will not ask again, so the prompt opens Settings instead.
enum NotificationPermission {
  private static let explainedKey = "explainedNotificationPermission"

  @MainActor
  static func askIfNeeded() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return
    case .notDetermined:
      _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
      UserDefaults.standard.set(true, forKey: explainedKey)
    case .denied:
      guard !UserDefaults.standard.bool(forKey: explainedKey) else { return }
      await offerSettings()
      UserDefaults.standard.set(true, forKey: explainedKey)
    @unknown default:
      return
    }
  }

  @MainActor
  private static func offerSettings() async {
    #if os(macOS)
      NSApp.activate(ignoringOtherApps: true)
      let verb = "Open System Settings"
    #else
      let verb = "Open Settings"
    #endif
    await DialogPresenter.ask(Dialog(title: "Allow Notifications", actions: [
      .cancel("Not Now"),
      Dialog.Action(verb) { _ in openSettings() },
    ]))
  }

  @MainActor
  static func openSettings() {
    #if os(macOS)
      let bundle = Bundle.main.bundleIdentifier ?? "dev.tether.app"
      let candidates = [
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundle)",
        "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundle)",
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
      ]
      for raw in candidates {
        guard let url = URL(string: raw), NSWorkspace.shared.open(url) else { continue }
        return
      }
    #elseif os(iOS)
      guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
      UIApplication.shared.open(url)
    #endif
  }
}

#if os(macOS)
  extension TetherAppDelegate: @MainActor UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      completionHandler([.banner, .sound, .list])
    }
  }
#endif
