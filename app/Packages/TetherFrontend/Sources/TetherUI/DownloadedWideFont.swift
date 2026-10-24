#if os(iOS)
  import CoreText
  import Foundation
  import Tether

  /// The face iOS draws Chinese with, fetched from Apple once per device.
  ///
  /// iOS's own PingFang carries `hvgl` outlines only, which the renderer
  /// cannot paint. Hiragino Sans is built in and drawable but lacks about a
  /// third of everyday simplified characters (这, 过, 说, 们). Heiti SC has
  /// all of GB2312 as TrueType outlines and is one of Apple's downloadable
  /// fonts, so CoreText fetches it — once, about 56 MB — and the terminal
  /// redraws when it lands. Until then, and offline, Hiragino Sans draws
  /// what it has.
  @MainActor
  enum DownloadedWideFont {
    /// Selected by PostScript name, which the catalogue files every face
    /// under: its file also holds the Traditional face, and a family alias
    /// would land on both.
    static let postScriptName = "STHeitiSC-Light"
    static let builtIn = "Hiragino Sans"
    private(set) static var ready = false
    private static var requested = false

    /// The face to draw wide characters with now.
    static var face: String { ready ? postScriptName : builtIn }

    /// Registers the face if this device has it, and asks CoreText for it
    /// if not. Already on the device, CoreText's answer is immediate.
    static func prepare() {
      if register() { return }
      guard !requested else { return }
      requested = true
      let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: postScriptName] as CFDictionary)
      // CoreText calls back on a queue of its own. Inferred as main-actor
      // code, this closure would trap there; it hops over instead.
      CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { @Sendable state, _ in
        guard state == .didFinish else { return true }
        Task { @MainActor in
          // A download that failed is asked for again the next time the
          // catalogue is prepared.
          requested = false
          guard register() else { return }
          TerminalFonts.resetFailure()
          TerminalFonts.prepare()
        }
        return true
      }
    }

    @discardableResult
    private static func register() -> Bool {
      if ready { return true }
      let font = CTFontCreateWithName(postScriptName as CFString, 0, nil)
      // A font that is not on the device comes back as a substitute.
      guard CTFontCopyPostScriptName(font) as String == postScriptName,
        let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
        FileManager.default.isReadableFile(atPath: url.path),
        (try? RenderingFonts.registerFile(url.path)) != nil,
        RenderingFonts.faces().contains(where: { $0.id == postScriptName })
      else { return false }
      ready = true
      return true
    }
  }
#endif
