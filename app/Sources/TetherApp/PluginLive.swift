import Foundation
import TetherPluginKit
#if os(iOS)
  import ActivityKit
#endif

/// Whether a status report is still in progress. A saturated band breathes;
/// gray, empty and zero-weight bands are idle and do not keep an activity up.
enum PluginPresence: Equatable {
  case idle
  case living(tint: UInt32)
}

enum PluginLiving {
  static func presence(of segments: [PluginStatusSegment]) -> PluginPresence {
    for segment in segments where segment.weight > 0 {
      if StatusMotion.period(for: segment.color) != nil {
        return .living(tint: segment.color)
      }
    }
    return .idle
  }
}

/// The host's Live Activity for a plugin whose status is still moving.
/// The system draws it; this only publishes the plugin's name, label and colour.
@MainActor
enum PluginLive {
  static func note(pluginID: String, name: String, label: String, segments: [PluginStatusSegment]) {
    #if os(iOS)
      switch PluginLiving.presence(of: segments) {
      case .idle:
        desired[pluginID] = .end
      case .living(let tint):
        desired[pluginID] = .show(PluginLiveAttributes.ContentState(
          name: String(name.prefix(40)),
          detail: String(label.prefix(80)),
          tint: tint))
      }
      pump()
    #endif
  }

  static func end(_ pluginID: String) {
    #if os(iOS)
      desired[pluginID] = .end
      pump()
    #endif
  }

  /// Drops activities whose plugin is no longer reporting a lamp.
  static func retain(_ ids: Set<String>) {
    #if os(iOS)
      shown = ids
      pump()
    #endif
  }

  /// Keeps activities the system still has from the last time the app was open,
  /// so the next status replaces them instead of starting a second one.
  static func adopt() {
    #if os(iOS)
      needsAdopt = true
      pump()
    #endif
  }

  #if os(iOS)
    private enum Wish {
      case show(PluginLiveAttributes.ContentState)
      case end
    }

    /// Activity is not Sendable, and its `end`/`update` run off the main actor.
    /// The dictionary is only touched from the functions below, one at a time.
    nonisolated(unsafe) private static var activities: [String: Activity<PluginLiveAttributes>] = [:]
    private static var desired: [String: Wish] = [:]
    private static var shown: Set<String>?
    private static var needsAdopt = false
    private static var applying = false

    private static func pump() {
      guard !applying else { return }
      applying = true
      Task {
        while true {
          if needsAdopt {
            needsAdopt = false
            absorb()
          }
          let visible = shown
          shown = nil
          await dropUnshown(visible)
          if desired.isEmpty && !needsAdopt && shown == nil { break }
          let batch = desired
          desired.removeAll()
          for (id, wish) in batch {
            await apply(pluginID: id, wish: wish)
          }
          if desired.isEmpty && !needsAdopt && shown == nil { break }
        }
        applying = false
        if !desired.isEmpty || needsAdopt || shown != nil { pump() }
      }
    }

    private static func apply(pluginID: String, wish: Wish) async {
      switch wish {
      case .end:
        await stop(pluginID)
      case .show(let state):
        await show(pluginID, state: state)
      }
    }

    nonisolated private static func absorb() {
      for activity in Activity<PluginLiveAttributes>.activities {
        activities[activity.attributes.pluginID] = activity
      }
    }

    nonisolated private static func dropUnshown(_ shown: Set<String>?) async {
      guard let shown else { return }
      let stale = activities.keys.filter { !shown.contains($0) }
      for id in stale {
        guard let activity = activities.removeValue(forKey: id) else { continue }
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }

    nonisolated private static func stop(_ pluginID: String) async {
      guard let activity = activities.removeValue(forKey: pluginID) else { return }
      await activity.end(nil, dismissalPolicy: .immediate)
    }

    nonisolated private static func show(_ pluginID: String, state: PluginLiveAttributes.ContentState) async {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
      guard let activity = activities.removeValue(forKey: pluginID) else {
        let attributes = PluginLiveAttributes(pluginID: pluginID)
        guard let created = try? Activity.request(attributes: attributes, content: content, pushType: nil) else {
          return
        }
        activities[pluginID] = created
        return
      }
      if activity.content.state == state {
        activities[pluginID] = activity
        return
      }
      await activity.update(content)
      activities[pluginID] = Activity<PluginLiveAttributes>.activities.first {
        $0.attributes.pluginID == pluginID
      }
    }
  #endif
}
