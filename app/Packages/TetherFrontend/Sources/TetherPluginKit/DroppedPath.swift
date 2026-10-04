import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Absolute paths a plugin dragged. The terminal pastes `text` as it stands.
///
/// A file dragged from Finder does not carry this type, so a terminal can
/// still take that drop as a file.
public struct DroppedPath: Transferable, Sendable, Equatable {
  public let text: String

  public init(text: String) {
    self.text = text
  }

  public static let contentType = UTType(
    exportedAs: "dev.tether.app.dropped-path", conformingTo: .data)

  public static func data(for text: String) -> Data { Data(text.utf8) }

  public static func text(in data: Data) -> String? {
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
    return text
  }

  public static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(contentType: contentType) { item in
      data(for: item.text)
    } importing: { data in
      guard let text = text(in: data) else { throw CocoaError(.coderReadCorrupt) }
      return DroppedPath(text: text)
    }
  }
}
