import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TetherLiveBundle: WidgetBundle {
  var body: some Widget {
    PluginLiveWidget()
  }
}

/// The lock screen and the island for a plugin that is still working.
/// A dot and the plugin's own words. No sentence of ours.
struct PluginLiveWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: PluginLiveAttributes.self) { context in
      HStack(spacing: 8) {
        Circle()
          .fill(Color(liveHex: context.state.tint))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.name).font(.headline).lineLimit(1)
          if showsDetail(context.state) {
            Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Circle().fill(Color(liveHex: context.state.tint)).frame(width: 12, height: 12)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.name).font(.headline).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if showsDetail(context.state) {
            Text(context.state.detail).font(.body).lineLimit(2)
          }
        }
      } compactLeading: {
        Circle().fill(Color(liveHex: context.state.tint)).frame(width: 8, height: 8)
      } compactTrailing: {
        Text(context.state.detail.isEmpty ? context.state.name : context.state.detail)
          .font(.caption2)
          .lineLimit(1)
      } minimal: {
        Circle().fill(Color(liveHex: context.state.tint)).frame(width: 8, height: 8)
      }
    }
  }

  private func showsDetail(_ state: PluginLiveAttributes.ContentState) -> Bool {
    !state.detail.isEmpty && state.detail != state.name
  }
}

private extension Color {
  init(liveHex: UInt32) {
    self.init(
      red: Double((liveHex >> 16) & 0xFF) / 255,
      green: Double((liveHex >> 8) & 0xFF) / 255,
      blue: Double(liveHex & 0xFF) / 255)
  }
}
