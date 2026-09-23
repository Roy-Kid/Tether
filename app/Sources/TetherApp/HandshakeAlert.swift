import SwiftUI
import Tether

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// System alert for host-key trust and keyboard-interactive prompts.
///
/// Shown one at a time from the key window's root, after any previous alert
/// has finished dismissing. Presenting Verification code *on top of*
/// Unrecognised host is how Continue became Cancelled: dismissing Trust
/// cancelled the child alert.
enum HandshakeAlert {
  @MainActor
  static func present(_ question: Question) {
    Task { @MainActor in
      await waitForClearPresentation()
      switch question.kind {
      case .trust(let host, let why, let answer):
        let changed: KnownHost? = if case .changed(let from) = why { from } else { nil }
        let title = changed == nil ? "Unrecognised host" : "This host's key has changed"
        let message: String
        if let changed {
          message =
            "It does not match the key previously trusted.\n\nOffered now:\n\(host.fingerprint)\n\nAccepted before:\n\(changed.fingerprint)"
        } else {
          message = host.fingerprint
        }
        await show(
          title: title, message: message, fields: [], cancel: "Reject", confirm: "Trust"
        ) { values in
          answer(values != nil)
        }
      case .prompts(let instruction, let prompts, let answer):
        let title = prompts.first.map(promptDialogTitle) ?? "Continue"
        let message = instruction.isEmpty || instruction == title ? "" : instruction
        await show(
          title: title, message: message, fields: prompts, cancel: "Cancel", confirm: "Continue"
        ) { values in
          answer(values ?? [])
        }
      }
    }
  }

  @MainActor
  private static func waitForClearPresentation() async {
    #if os(iOS)
      for _ in 0..<40 {
        if rootViewController()?.presentedViewController == nil { return }
        try? await Task.sleep(for: .milliseconds(50))
      }
    #endif
  }

  @MainActor
  private static func show(
    title: String,
    message: String,
    fields: [AuthPrompt],
    cancel: String,
    confirm: String,
    finish: @escaping ([String]?) -> Void
  ) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      var finished = false
      let once: ([String]?) -> Void = { values in
        guard !finished else { return }
        finished = true
        finish(values)
        continuation.resume()
      }

      #if os(iOS)
        guard let presenter = rootViewController() else {
          once(nil)
          return
        }
        let alert = UIAlertController(
          title: title, message: message.isEmpty ? nil : message, preferredStyle: .alert)
        for prompt in fields {
          alert.addTextField { field in
            field.placeholder = promptDialogTitle(prompt)
            field.isSecureTextEntry = !prompt.echo
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .numberPad
            field.textContentType = .oneTimeCode
          }
        }
        // Both buttons are `.default`. `.cancel` runs when the alert is
        // dismissed because a parent disappeared — which is not a person
        // tapping Cancel.
        alert.addAction(
          UIAlertAction(title: cancel, style: .default) { _ in
            once(nil)
          })
        alert.addAction(
          UIAlertAction(title: confirm, style: .default) { _ in
            let typed = (alert.textFields ?? []).map { $0.text ?? "" }
            if fields.isEmpty {
              once([])
            } else {
              once(typed.isEmpty ? Array(repeating: "", count: fields.count) : typed)
            }
          })
        presenter.present(alert, animated: true)
      #else
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        var boxes: [NSTextField] = []
        if !fields.isEmpty {
          let stack = NSStackView()
          stack.orientation = .vertical
          stack.spacing = 8
          for prompt in fields {
            let field: NSTextField =
              prompt.echo ? NSTextField(string: "") : NSSecureTextField(string: "")
            field.placeholderString = promptDialogTitle(prompt)
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            boxes.append(field)
            stack.addArrangedSubview(field)
          }
          stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(fields.count) * 28)
          alert.accessoryView = stack
        }
        let complete: (NSApplication.ModalResponse) -> Void = { response in
          if response == .alertFirstButtonReturn {
            once(fields.isEmpty ? [] : boxes.map(\.stringValue))
          } else {
            once(nil)
          }
        }
        if let window = NSApp.keyWindow {
          alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
          complete(alert.runModal())
        }
      #endif
    }
  }

  #if os(iOS)
    @MainActor
    private static func rootViewController() -> UIViewController? {
      let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
      let window = windows.first { $0.isKeyWindow } ?? windows.first
      return window?.rootViewController
    }
  #endif
}
