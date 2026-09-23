#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// `text` as one word to a POSIX shell.
///
/// Left bare when every character is one a shell reads literally, so the
/// common path stays readable at the prompt; single-quoted otherwise, with
/// each `'` closed, escaped and reopened — the one quoting that has no
/// characters special inside it.
func shellQuoted(_ text: String) -> String {
  let plain = text.unicodeScalars.allSatisfy { scalar in
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@", "%": true
    default: false
    }
  }
  if plain && !text.isEmpty { return text }
  return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Puts `text` on the clipboard, as text.
@MainActor
func copyToPasteboard(_ text: String) {
  #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  #else
    UIPasteboard.general.string = text
  #endif
}
