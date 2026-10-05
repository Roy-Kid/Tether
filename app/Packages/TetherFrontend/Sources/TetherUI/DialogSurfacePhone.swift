#if os(iOS)
  import UIKit

  /// A phone's dialog, in a window of its own.
  ///
  /// Presented from one of the app's view controllers, a dialog belongs to
  /// it: a controller already presenting a sheet cannot present anything
  /// else, and a sheet that closes takes whatever it presented along with it
  /// — unanswered, with the handshake behind it still waiting. A window above
  /// the app's is somewhere nothing else presents and nothing else dismisses.
  @MainActor
  final class PlatformDialogSurface: DialogSurface {
    /// One dialog's window and ending. Its own, so an action handler that
    /// runs late — after its dialog was withdrawn and the next one shown —
    /// can only ever end the dialog it belongs to.
    @MainActor
    private final class Presentation {
      var window: UIWindow?
      /// The app's window, handed the keyboard back when the dialog goes.
      weak var returnTo: UIWindow?
      var gone: (() -> Void)?

      func finish() {
        guard let gone else { return }
        self.gone = nil
        window?.endEditing(true)
        window?.isHidden = true
        window = nil
        returnTo?.makeKey()
        gone()
      }
    }

    private var current: Presentation?

    func show(
      _ dialog: Dialog, in anchor: DialogAnchor?,
      answer: @escaping (Int, [String]) -> Void, gone: @escaping () -> Void
    ) -> Bool {
      guard let scene = anchor?.window?.windowScene ?? Self.scene() else { return false }
      let source = anchor?.window ?? scene.keyWindow ?? scene.windows.first
      let window = UIWindow(windowScene: scene)
      window.windowLevel = .alert
      window.backgroundColor = .clear
      window.tintColor = source?.tintColor
      // The app may have chosen light or dark for itself; the dialog follows.
      if let style = source?.rootViewController?.traitCollection.userInterfaceStyle {
        window.overrideUserInterfaceStyle = style
      }
      let root = UIViewController()
      root.view.backgroundColor = .clear
      window.rootViewController = root

      let presentation = Presentation()
      presentation.window = window
      presentation.returnTo = source
      presentation.gone = gone

      let alert = UIAlertController(title: dialog.title, message: Self.message(dialog), preferredStyle: .alert)
      for field in dialog.fields {
        alert.addTextField { Self.configure($0, for: field) }
      }
      let cancel = dialog.cancelAction
      for (index, action) in dialog.actions.enumerated() {
        // UIKit allows one cancel; any other is an ordinary button.
        let style: UIAlertAction.Style =
          switch action.role {
          case .confirm: .default
          case .destructive: .destructive
          case .cancel: index == cancel ? .cancel : .default
          }
        let button = UIAlertAction(title: action.title, style: style) { [weak alert] _ in
          // Without its fields there is no answer to give; ending it
          // unanswered declines rather than sending empty strings.
          if let alert { answer(index, alert.textFields?.map { $0.text ?? "" } ?? []) }
          presentation.finish()
        }
        alert.addAction(button)
        if index == dialog.defaultAction, action.role == .confirm { alert.preferredAction = button }
      }

      current = presentation
      window.makeKeyAndVisible()
      root.present(alert, animated: true)
      return true
    }

    /// Without the animation: a question taken back — a tab closed, an
    /// answer that took too long — has nothing to say on its way out.
    func withdraw() {
      guard let presentation = current else { return }
      current = nil
      presentation.window?.rootViewController?.dismiss(animated: false)
      presentation.finish()
    }

    private static func configure(_ text: UITextField, for field: Dialog.Field) {
      text.placeholder = field.placeholder.isEmpty ? nil : field.placeholder
      text.text = field.initial
      text.isSecureTextEntry = field.isSecure
      text.autocapitalizationType = .none
      text.autocorrectionType = .no
      text.spellCheckingType = .no
      text.clearButtonMode = .whileEditing
      switch field.kind {
      case .text: break
      case .password: text.textContentType = .password
      case .code: text.textContentType = .oneTimeCode
      }
    }

    /// The date line, and a diff under it. A phone alert has no accessory.
    private static func message(_ dialog: Dialog) -> String? {
      let lines = [dialog.message, dialog.detail].compactMap { $0 }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The scene a person is looking at, or any there is: a question that
    /// arrives while the app is in the background is waiting when they return.
    private static func scene() -> UIWindowScene? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      return scenes.first { $0.activationState == .foregroundActive }
        ?? scenes.first { $0.activationState == .foregroundInactive }
        ?? scenes.first
    }
  }
#endif
