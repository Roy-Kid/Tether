import SwiftUI
import TetherPluginHost
import TetherUI

/// Notes a plugin asked the host to show. The host owns them.
struct PluginNoteStack: View {
  let plugins: PluginAPI
  /// Long enough to read a line, short enough that it does not stay over the terminal.
  private static let stays: Duration = .seconds(6)

  var body: some View {
    if !plugins.notes.isEmpty {
      VStack(alignment: .leading, spacing: UIStyle.Space.small) {
        ForEach(plugins.notes) { note in
          HStack(alignment: .firstTextBaseline, spacing: UIStyle.Space.inline) {
            VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
              if !note.source.isEmpty {
                Text(note.source).font(UIStyle.detail).foregroundStyle(Theme.subtle).lineLimit(1)
              }
              Text(note.title).font(UIStyle.title).lineLimit(1)
              if !note.body.isEmpty {
                Text(note.body).font(UIStyle.detail).foregroundStyle(Theme.subtle).lineLimit(2)
              }
            }
            Spacer(minLength: UIStyle.Space.inline)
            Button {
              plugins.dismiss(note.id)
            } label: {
              Image(systemName: "xmark").font(UIStyle.symbol)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
          }
          .padding(UIStyle.Space.group)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Theme.window, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius, style: .continuous))
          .task(id: note.id) {
            try? await Task.sleep(for: Self.stays)
            plugins.dismiss(note.id)
          }
        }
      }
      #if os(iOS)
        .frame(maxWidth: .infinity, alignment: .leading)
      #else
        .frame(maxWidth: UIStyle.menuWidth, alignment: .trailing)
      #endif
    }
  }
}
