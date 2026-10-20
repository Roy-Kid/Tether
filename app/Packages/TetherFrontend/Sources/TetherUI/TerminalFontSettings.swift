import SwiftUI
import Tether
import UniformTypeIdentifiers

/// Shared by the Mac and phone settings. The pickers select exact catalogue
/// faces; no operating-system font installation or iCloud write is performed.
public struct TerminalFontSettings: View {
  @AppStorage(TerminalFonts.primaryKey) private var primary = TerminalFonts.defaultPrimary
  @AppStorage(TerminalFonts.wideKey) private var wide = "PingFang SC"
  @State private var faces: [TerminalFontFace] = []
  @State private var importing = false
  @State private var problem: Dialog?

  public init() {}
  public var body: some View {
    Picker("Terminal Font", selection: $primary) {
      Text("System Default").tag(TerminalFonts.defaultPrimary)
      if !faces.contains(where: { $0.id == primary }), primary != TerminalFonts.defaultPrimary {
        Text(primary).tag(primary)
      }
      ForEach(faces.filter { $0.id != TerminalFonts.defaultPrimary }, id: \.id) { face in
        Text(face.name).tag(face.id)
      }
    }
    Picker("Wide Character Font", selection: $wide) {
      Text("System Default").tag("PingFang SC")
      if !faces.contains(where: { $0.id == wide }), wide != "PingFang SC" { Text(wide).tag(wide) }
      ForEach(faces, id: \.id) { face in Text(face.name).tag(face.id) }
    }
    SettingsAction("Import Font", systemImage: "square.and.arrow.down") { importing = true }
      .fileImporter(isPresented: $importing,
        allowedContentTypes: ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }) { result in
          switch result {
          case .success(let url):
            do {
              let imported = try TerminalFonts.importFont(url)
              faces = TerminalFonts.faces()
              if let face = imported.first { primary = face.id }
            } catch { problem = .notice("Font Import Failed", message: error.localizedDescription) { problem = nil } }
          case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
              problem = .notice("Font Import Failed", message: error.localizedDescription) { problem = nil }
            }
          }
      }
      .dialog(for: problem?.id) { _ in problem! }
      .task { faces = TerminalFonts.faces() }
  }
}
