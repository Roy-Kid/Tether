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

  /// A run of file text fit to show in a preview: like `display`, but
  /// newlines and tabs stay, because a snippet that cannot wrap is not a
  /// snippet of a text file.
  static func displayText(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.compactMap { scalar in
          if bidiControls.contains(scalar.value) { return nil }
          if scalar == "\n" || scalar == "\t" { return scalar }
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

  /// Whether the bytes are almost certainly text a person can read as a
  /// preview: source, config, logs, and the plain-text scientific tables a
  /// lab writes (`xyz`, `cif`, `pdb`, …). Used when Quick Look has no
  /// generator for the type and a snippet is the next best thing.
  static func isTextLike(_ name: String) -> Bool {
    let base = name.lowercased()
    if textFileNames.contains(base) { return true }
    let ext = (name as NSString).pathExtension.lowercased()
    if textExtensions.contains(ext) { return true }
    if ext.isEmpty { return false }
    guard let type = UTType(filenameExtension: ext) else { return false }
    return type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
      || type.conforms(to: .xml) || type.conforms(to: .yaml) || type.conforms(to: .propertyList)
  }

  /// The SF Symbol for an entry.
  static func symbol(for name: String, kind: FileKind) -> String {
    switch kind {
    case .directory: return "folder"
    case .link: return "arrow.up.right.square"
    case .other: return "questionmark.square.dashed"
    case .file: break
    }
    let base = name.lowercased()
    if textFileNames.contains(base) { return "doc.text" }
    let ext = (name as NSString).pathExtension.lowercased()
    // A dedicated symbol first — `json` is text and also has its own mark.
    if let symbol = symbolByExtension[ext] { return symbol }
    // Source and tables this system has no registered type for are still text.
    if textExtensions.contains(ext) { return "doc.text" }
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
    let symbols: [(UTType, String)] = [
      (.pdf, "doc.richtext"), (.image, "photo"), (.movie, "film"), (.audio, "waveform"),
      (.archive, "archivebox"), (.spreadsheet, "tablecells"),
      (.presentation, "rectangle.on.rectangle"), (.epub, "book"),
      (.diskImage, "externaldrive"), (.font, "textformat"),
      (.usd, "cube"), (.sourceCode, "doc.text"), (.text, "doc.text"),
      (.json, "curlybrackets"), (.xml, "chevron.left.forwardslash.chevron.right"),
      (.html, "chevron.left.forwardslash.chevron.right"),
      (.executable, "terminal"),
    ]
    return symbols.first { type.conforms(to: $0.0) }?.1 ?? "doc"
  }

  /// The absolute paths Copy Path puts on the clipboard: one path a line,
  /// exactly as stored, with nothing added around them.
  static func copiedPaths(_ paths: [String]) -> String {
    paths.joined(separator: "\n")
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

  /// Names with no extension that are still plain text (and often the most
  /// important file in a tree).
  private static let textFileNames: Set<String> = [
    "makefile", "gnumakefile", "dockerfile", "containerfile", "cmakelists.txt",
    "license", "licence", "copying", "readme", "changelog", "codeowners",
    "gemfile", "rakefile", "procfile", "brewfile", "justfile", "vagrantfile",
    "jenkinsfile", "gradle", "cargo.toml", "package.swift", "package.json",
    ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".env",
    ".envrc", ".zshrc", ".bashrc", ".bash_profile", ".profile", ".vimrc",
    ".npmrc", ".nvmrc", ".python-version", ".ruby-version", ".tool-versions",
  ]

  /// Plain text a system without the language's tools installed does not
  /// know is text — source, config, logs, and lab tables.
  private static let textExtensions: Set<String> = [
    // Programming languages
    "rs", "go", "py", "pyi", "pyw", "rb", "jl", "r", "swift", "kt", "kts",
    "java", "scala", "sc", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx",
    "cu", "cuh", "m", "mm", "f", "f90", "f95", "for", "f03",
    "js", "mjs", "cjs", "ts", "mts", "cts", "tsx", "jsx", "lua", "pl", "pm",
    "php", "ex", "exs", "erl", "hrl", "hs", "lhs", "ml", "mli", "fs", "fsx",
    "clj", "cljs", "edn", "rkt", "scm", "ss", "lisp", "el", "vim", "zig",
    "nim", "v", "sv", "vhdl", "vhd", "d", "pas", "ada", "adb", "ads", "cob",
    "dart", "vue", "svelte", "astro", "elm", "purs", "coffee", "groovy",
    // Web and config
    "toml", "yaml", "yml", "ini", "cfg", "conf", "config", "env", "properties",
    "json", "jsonc", "ndjson", "json5", "xml", "plist", "html", "htm", "css",
    "scss", "sass", "less", "sql", "graphql", "gql", "proto", "thrift",
    "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "awk", "sed", "vimrc",
    "editorconfig", "gitignore", "gitattributes", "gitmodules", "npmrc",
    "cmake", "gradle", "mk", "mkd", "dockerfile", "tf", "tfvars", "hcl",
    // Documents and data
    "md", "markdown", "mdx", "rst", "tex", "ltx", "bib", "txt", "text",
    "log", "out", "csv", "tsv", "tab", "lock", "sum", "diff", "patch",
    // Scientific / lab tables written as plain text
    "xyz", "pdb", "ent", "mol", "mol2", "sdf", "cif", "mmcif", "mcif",
    "gro", "top", "itp", "ndx", "tpr", "lammpstrj", "lmp", "data", "in",
    "cube", "xsf", "axsf", "poscar", "contcar", "incar", "kpoints", "potcar",
    "outcar", "oszicar", "xdatcar", "chgcar", "locpot", "band", "dos",
    "cp2k", "pwi", "pwo", "gjf", "com", "inp", "out", "chk", "fchk",
    "xvg", "agr", "gp", "gnu", "plt", "py", "ipynb", "rmd", "qmd",
  ]

  /// SF Symbols for extensions `UTType` often leaves unregistered.
  private static let symbolByExtension: [String: String] = [
    "pdf": "doc.richtext",
    "epub": "book",
    "ipynb": "list.bullet.rectangle",
    "json": "curlybrackets",
    "jsonc": "curlybrackets",
    "ndjson": "curlybrackets",
    "xml": "chevron.left.forwardslash.chevron.right",
    "html": "chevron.left.forwardslash.chevron.right",
    "htm": "chevron.left.forwardslash.chevron.right",
    "css": "paintbrush",
    "scss": "paintbrush",
    "sass": "paintbrush",
    "less": "paintbrush",
    "sql": "cylinder.split.1x2",
    "graphql": "point.3.connected.trianglepath",
    "proto": "square.stack.3d.up",
    "dmg": "externaldrive",
    "iso": "externaldrive",
    "img": "externaldrive",
    "ttf": "textformat",
    "otf": "textformat",
    "ttc": "textformat",
    "woff": "textformat",
    "woff2": "textformat",
    "usdz": "cube",
    "usd": "cube",
    "usda": "cube",
    "usdc": "cube",
    "obj": "cube",
    "stl": "cube",
    "ply": "cube",
    "fbx": "cube",
    "gltf": "cube",
    "glb": "cube",
    "xyz": "atom",
    "pdb": "atom",
    "mol": "atom",
    "mol2": "atom",
    "sdf": "atom",
    "cif": "atom",
    "mmcif": "atom",
    "gro": "atom",
    "cube": "atom",
    "xsf": "atom",
    "smiles": "atom",
    "inchi": "atom",
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

/// The path menu. The current directory is the menu's title, so it is not
/// listed again. Home and Shell are their own rows only when that directory
/// is not already one of the directories above — otherwise `home` and Home
/// are the same place twice, and `/` is named Root so it is not a stray slash.
struct PathPlaces: Equatable {
  var directory: String?
  var home: String?
  var shell: String?

  /// Enclosing directories, nearest first.
  var places: [String] {
    guard let directory, directory != "/" else { return [] }
    return Array(Paths.ancestors(directory).dropLast().reversed())
  }

  var showsHome: Bool {
    guard let home else { return directory != nil }
    return home != directory && !places.contains(home)
  }

  var showsShell: Bool {
    guard let shell, shell != directory else { return false }
    return !places.contains(shell)
  }

  func title(_ path: String) -> String {
    path == "/" ? "Root" : Names.display(Paths.name(path))
  }

  func symbol(_ path: String) -> String {
    if path == shell, path != home { return "terminal" }
    if path == home { return "house" }
    if path == "/" { return "externaldrive" }
    return "folder"
  }
}
