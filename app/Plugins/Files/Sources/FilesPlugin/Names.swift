import Foundation
import Tether
import UniformTypeIdentifiers

/// What a name from the far side may be turned into.
///
/// A file name is the far side's data (spec §18). It may hold escape
/// sequences, line breaks and direction overrides that make `fdp.exe` read
/// as `exe.pdf`; shown as-is it can lie, and used as-is as a local name it
/// can be a path. Everything that puts a name on screen or on disk goes
/// through here.
enum Names {
  /// A name fit to show a person: control characters become a visible
  /// replacement, and bidirectional formatting characters are dropped.
  static func display(_ name: String) -> String {
    String(
      String.UnicodeScalarView(
        name.unicodeScalars.compactMap { scalar in
          if bidiControls.contains(scalar.value) { return nil }
          if scalar.properties.generalCategory == .control { return "\u{FFFD}" }
          return scalar
        }))
  }

  /// A name fit to be one file name on this machine: displayable, with the
  /// separators this system reads in a name replaced, and never `.` or `..`.
  static func local(_ name: String) -> String {
    let cleaned = display(name)
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
  }

  /// `name`, or the first of `name 2`, `name 3`… that is not taken.
  static func free(_ name: String, taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let (stem, suffix) = split(name)
    var number = 2
    while taken.contains("\(stem) \(number)\(suffix)") { number += 1 }
    return "\(stem) \(number)\(suffix)"
  }

  /// Whether opening this would run it. Such a file is previewed or saved,
  /// never handed to whatever this machine opens it with.
  static func isRisky(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    if riskyExtensions.contains(ext) { return true }
    guard let type = UTType(filenameExtension: ext) else { return false }
    return [UTType.executable, .application, .applicationBundle, .script, .unixExecutable]
      .contains { type.conforms(to: $0) }
  }

  /// The SF Symbol for an entry.
  static func symbol(for name: String, kind: FileKind) -> String {
    switch kind {
    case .directory: return "folder"
    case .link: return "arrow.up.right.square"
    case .other: return "questionmark.square.dashed"
    case .file: break
    }
    let ext = (name as NSString).pathExtension.lowercased()
    // Source that this system has no registered type for is still text.
    if sourceExtensions.contains(ext) { return "doc.text" }
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
    let symbols: [(UTType, String)] = [
      (.pdf, "doc.richtext"), (.image, "photo"), (.movie, "film"), (.audio, "waveform"),
      (.archive, "archivebox"), (.sourceCode, "doc.text"), (.text, "doc.text"),
      (.executable, "terminal"),
    ]
    return symbols.first { type.conforms(to: $0.0) }?.1 ?? "doc"
  }

  /// `text` as one word to a POSIX shell: bare when nothing in it is
  /// special, single-quoted otherwise.
  static func shellQuoted(_ text: String) -> String {
    let plain = text.unicodeScalars.allSatisfy { scalar in
      switch scalar {
      case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@", "%": true
      default: false
      }
    }
    if plain && !text.isEmpty { return text }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// `plot.png` → (`plot`, `.png`). A leading dot is part of the stem, so
  /// `.env` has no extension.
  private static func split(_ name: String) -> (String, String) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
    return (String(name[..<dot]), String(name[dot...]))
  }

  /// U+200E/F marks, U+202A–E embeddings and overrides, U+2066–9 isolates.
  private static let bidiControls: Set<UInt32> = [
    0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
  ]

  /// Plain text a system without the language's tools installed does not
  /// know is text.
  private static let sourceExtensions: Set<String> = [
    "rs", "go", "py", "rb", "jl", "r", "swift", "kt", "java", "scala", "c", "h", "cc", "cpp",
    "hpp", "cu", "f90", "js", "ts", "tsx", "jsx", "lua", "toml", "yaml", "yml", "ini", "cfg",
    "md", "rst", "tex", "log", "csv", "tsv", "lock",
  ]

  /// Types that run when opened but that UTType does not call executable.
  private static let riskyExtensions: Set<String> = [
    "app", "command", "tool", "pkg", "mpkg", "terminal", "workflow", "action", "sh", "bash",
    "zsh", "csh", "fish", "scpt", "applescript", "jar", "webloc", "inetloc", "fileloc",
  ]
}

/// Paths on the far side. POSIX strings, whatever this machine uses.
enum Paths {
  static func join(_ directory: String, _ name: String) -> String {
    directory.hasSuffix("/") ? directory + name : directory + "/" + name
  }

  static func parent(_ path: String) -> String {
    let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
    return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
  }

  static func name(_ path: String) -> String {
    let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed == "/" ? "/" : String(trimmed.split(separator: "/").last ?? "/")
  }

  static func ancestors(_ path: String) -> [String] {
    var result = ["/"]
    var current = ""
    for component in path.split(separator: "/") {
      current += "/" + component
      result.append(current)
    }
    return result
  }
}
