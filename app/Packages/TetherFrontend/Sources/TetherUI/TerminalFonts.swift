import CoreText
import CryptoKit
import Foundation
import SwiftUI
import Tether

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Native discovery and app-private storage. Rust owns font parsing and shaping.
@MainActor
public enum TerminalFonts {
  public static let primaryKey = "terminalFontFamily"
  public static let wideKey = "terminalWideFontFamily"
  private static var loaded = false
  private(set) static var systemFaces: [TerminalFontFace] = []
  private(set) static var failure: RenderingError?
  private static var revision = 0
  private static var cachedMetrics: [String: RenderFontMetrics] = [:]

  public static let defaultPrimary = "system"
  private static let systemAlias = "Tether System Monospace"
  public static var primary: String {
    UserDefaults.standard.string(forKey: primaryKey) ?? defaultPrimary
  }
  public static var wide: String {
    UserDefaults.standard.string(forKey: wideKey) ?? "PingFang SC"
  }

  private static var directory: URL {
    // Local to this app; font files and preferences do not enter iCloud.
    URL.applicationSupportDirectory
      .appending(path: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, directoryHint: .isDirectory)
      .appending(path: "TerminalFonts", directoryHint: .isDirectory)
  }

  static func tables(for font: CTFont) -> [RenderFontTable] {
    guard let tags = CTFontCopyAvailableTables(font, []) else { return [] }
    return (0..<CFArrayGetCount(tags)).compactMap { index in
      let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, index)))
      guard let data = CTFontCopyTable(font, tag, []) else { return nil }
      return RenderFontTable(tag: tag, data: data as Data)
    }
  }

  static func resolvedPrimary(_ choice: String) -> String {
    prepare()
    return choice == defaultPrimary ? systemAlias : choice
  }

  /// Clears a catalogue failure so the next `prepare` loads again.
  public static func resetFailure() {
    failure = nil
    loaded = false
  }

  public static func prepare() {
    guard !loaded else { return }
    let announce = revision > 0 || !cachedMetrics.isEmpty
    loaded = true
    failure = nil
    UserDefaults.standard.removeObject(forKey: "terminalDrawing")
    let collection = CTFontCollectionCreateFromAvailableFonts(nil)
    let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
    var paths = Set<String>()
    // Virtual system fonts expose tables but deliberately have no file URL.
    // CoreText supplies resources; fontations composes their container in Rust.
    #if os(macOS)
      let regular = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
      let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold) as CTFont
    #else
      let regular = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
      let bold = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold) as CTFont
    #endif
    for base in [regular, bold] {
      for font in [base, CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitItalic, .traitItalic) ?? base] {
        registerSystem(font, alias: systemAlias, paths: &paths)
      }
    }
    for descriptor in descriptors {
      let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
      if let url = readableFontFile(CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL) {
        paths.insert(url.path)
      } else if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
        registerTables(font, alias: name)
      }
    }
    for path in paths { _ = try? RenderingFonts.registerFile(path) }
    if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      for file in files where file.pathExtension == "font" {
        guard let data = try? Data(contentsOf: file) else { continue }
        do { _ = try RenderingFonts.register(data) }
        catch { try? FileManager.default.removeItem(at: file) }
      }
    }
    if announce {
      revision += 1
      cachedMetrics.removeAll()
      NotificationCenter.default.post(name: .terminalFontsChanged, object: nil)
    }
  }

  private static func registerSystem(_ font: CTFont, alias: String, paths: inout Set<String>) {
    if let url = readableFontFile(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL) {
      paths.insert(url.path)
      do { systemFaces += try RenderingFonts.registerFile(url.path, familyAlias: alias) }
      catch { failure = RenderingError(cause: "Could not load the system terminal font: \(error.localizedDescription)") }
      return
    }
    if registerTables(font, alias: alias) { return }
    failure = RenderingError(cause: "Could not load the system terminal font")
  }

  @discardableResult
  private static func registerTables(_ font: CTFont, alias: String) -> Bool {
    let tables = tables(for: font)
    guard !tables.isEmpty else { return false }
    do {
      systemFaces += try RenderingFonts.register(tables: tables, familyAlias: alias)
      return true
    } catch {
      return false
    }
  }

  private static func readableFontFile(_ url: URL?) -> URL? {
    guard let url, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
    return url
  }

  public static func faces() -> [TerminalFontFace] {
    prepare()
    return RenderingFonts.faces()
  }

  @discardableResult
  public static func importFont(_ url: URL) throws -> [TerminalFontFace] {
    try importFont(url, into: directory)
  }

  static func importFont(_ url: URL, into directory: URL) throws -> [TerminalFontFace] {
    prepare()
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard (values.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw RenderingError(cause: "Font exceeds 128 MiB") }
    let data = try Data(contentsOf: url)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let destination = directory.appending(path: digest + ".font")
    let alreadyStored = FileManager.default.fileExists(atPath: destination.path)
    if !alreadyStored { try data.write(to: destination, options: .atomic) }
    do {
      let faces = try RenderingFonts.register(data)
      guard !faces.isEmpty else { throw RenderingError(cause: "No font faces") }
      revision += 1
      cachedMetrics.removeAll()
      NotificationCenter.default.post(name: .terminalFontsChanged, object: nil)
      return faces
    } catch {
      if !alreadyStored { try? FileManager.default.removeItem(at: destination) }
      throw error
    }
  }

  static func measure(size: CGFloat, scale: CGFloat, primary: String, wide: String) -> RenderFontMetrics {
    prepare()
    let key = "\(size):\(scale):\(primary):\(wide):\(revision)"
    if let cached = cachedMetrics[key] { return cached }
    if failure != nil { return failedMetrics(size * scale) }
    do {
      let metrics = try RenderingFonts.measure(size: Float(size * scale), primary: primary, wide: wide)
      cachedMetrics[key] = metrics
      return metrics
    } catch {
      failure = error as? RenderingError ?? RenderingError(cause: String(describing: error))
      return failedMetrics(size * scale)
    }
  }

  private static func failedMetrics(_ size: CGFloat) -> RenderFontMetrics {
    RenderFontMetrics(size: Float(size), cellWidth: 0, lineHeight: 0, narrowAdvance: 0, wideAdvance: 0)
  }
}

extension Notification.Name {
  static let terminalFontsChanged = Notification.Name("TetherTerminalFontsChanged")
}
