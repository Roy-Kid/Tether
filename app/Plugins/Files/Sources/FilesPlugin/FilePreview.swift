import Foundation
import SwiftUI
import Tether
import TetherUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// What a peek at a file draws: a Quick Look thumbnail when the type has
/// one, a text snippet when the bytes are readable text, the type's symbol
/// otherwise.
///
/// Quick Look is still the full preview (space, the eye menu item). This is
/// only the small picture in a hover or long-press — the one place the app
/// itself has to decide what a file looks like before anyone has opened it.
struct FilePreview: View {
  /// How much text is read for a snippet. Enough for a few lines of a
  /// structure file or a log tail, not enough to pull a novel across SFTP.
  static let textLimit = 4 * 1024

  let name: String
  let kind: FileKind
  /// A local copy, when one is already here. Nothing is fetched for this view.
  let url: URL?
  var side: CGFloat = 240

  @State private var image: CGImage?
  @State private var snippet: String?
  @State private var loaded = false

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 2).resizable().scaledToFit()
      } else if let snippet {
        textPreview(snippet)
      } else {
        Image(systemName: Names.symbol(for: name, kind: kind))
          .font(.system(size: min(side / 4, 64)))
          .foregroundStyle(Theme.subtle)
          .padding(UIStyle.Space.section)
      }
    }
    .frame(minWidth: side * 0.7, minHeight: side * 0.7)
    .task(id: url) {
      loaded = false
      image = nil
      snippet = nil
      guard kind == .file, let url else {
        loaded = true
        return
      }
      image = await QuickLook.thumbnail(of: url, side: side)
      if image == nil, Names.isTextLike(name) {
        snippet = Self.textSnippet(at: url)
      }
      loaded = true
    }
  }

  private func textPreview(_ text: String) -> some View {
    ScrollView {
      Text(text)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(UIStyle.Space.group)
    }
    .frame(maxHeight: side)
  }

  /// The head of a text file, with control characters replaced so a remote
  /// name or a log cannot paint the preview.
  static func textSnippet(at url: URL, limit: Int = FilePreview.textLimit) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: limit)) ?? Data()
    guard !data.isEmpty else { return "" }
    var text = String(decoding: data, as: UTF8.self)
    text = Names.displayText(text)
    if data.count == limit {
      text += "\n…"
    }
    return text
  }
}
