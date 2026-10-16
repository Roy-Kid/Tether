import SwiftUI
import TetherPluginHost
import TetherUI

/// Notes a plugin asked the host to show. The host owns them.
struct PluginNoteStack: View {
  let plugins: PluginAPI

  var body: some View {
    if !plugins.notes.isEmpty {
      VStack(alignment: .trailing, spacing: UIStyle.Space.small) {
        ForEach(plugins.notes) { note in
          HStack(alignment: .firstTextBaseline, spacing: UIStyle.Space.inline) {
            VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
              Text(note.title).font(UIStyle.title).lineLimit(1)
              if !note.body.isEmpty {
                Text(note.body).font(UIStyle.detail).foregroundStyle(Theme.subtle).lineLimit(2)
              }
            }
            Button {
              plugins.dismiss(note.id)
            } label: {
              Image(systemName: "xmark").font(UIStyle.symbol)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
          }
          .padding(UIStyle.Space.group)
          .background(Theme.window, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius, style: .continuous))
        }
      }
      .frame(maxWidth: UIStyle.menuWidth, alignment: .trailing)
    }
  }
}
