#if os(macOS)
  import AppKit

  /// A Mac's dialog: an alert sheet on whatever is frontmost.
  ///
  /// On the sheet already open, if there is one — a sheet on a window that is
  /// showing a sheet waits behind it, which for a handshake means waiting on
  /// a person who cannot see the question.
  @MainActor
  final class PlatformDialogSurface: DialogSurface {
    private final class Presentation {
      let alert: NSAlert
      weak var host: NSWindow?
      var withdrawn = false
      var answering = false
      var shortcuts: [(Dialog.Action.Shortcut, NSButton)] = []
      var cancelButton: NSButton?
      var keyMonitor: Any?
      /// Called once, however the dialog ends.
      var ended: ((NSApplication.ModalResponse) -> Void)?
      init(alert: NSAlert) { self.alert = alert }

      func end(_ response: NSApplication.ModalResponse) {
        guard let ended else { return }
        self.ended = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        ended(response)
      }
    }

    private var current: Presentation?

    func show(
      _ dialog: Dialog, in anchor: DialogAnchor?,
      answer: @escaping (Int, [String]) -> Void, gone: @escaping () -> Void
    ) -> Bool {
      let alert = NSAlert()
      alert.messageText = dialog.title
      alert.informativeText = dialog.message ?? ""
      let order = Self.buttonOrder(dialog)
      let presentation = Presentation(alert: alert)
      for index in order {
        let action = dialog.actions[index]
        let button = alert.addButton(withTitle: action.title)
        switch action.role {
        case .destructive:
          button.hasDestructiveAction = true
          // AppKit clears Return from destructive buttons when presenting
          // the sheet. Explicit Enter shortcuts use the scoped monitor below.
          button.keyEquivalent = ""
        case .cancel:
          // Escape always; Return too when there is nothing else to press.
          button.keyEquivalent = dialog.actions.count == 1 ? "\r" : "\u{1b}"
        case .confirm:
          button.keyEquivalent = index == dialog.defaultAction ? "\r" : ""
        }
        button.keyEquivalentModifierMask = []
        presentation.shortcuts += action.shortcuts.map { ($0, button) }
        // Route both Return and keypad Enter even while a field editor owns
        // focus. Destructive buttons still require an explicit Enter opt-in.
        if button.keyEquivalent == "\r", !action.shortcuts.contains(.enter) {
          presentation.shortcuts.append((.enter, button))
        }
        if index == dialog.cancelAction { presentation.cancelButton = button }
        if !action.shortcuts.isEmpty {
          button.toolTip = action.shortcuts.map {
            switch $0 {
            case .enter: "Enter"
            case .command(let key): "⌘" + key.uppercased()
            }
          }.joined(separator: " / ")
        }
      }
      let boxes = dialog.fields.map(Self.box)
      if let diff = dialog.detail.map(Self.diffScroll) {
        let stack = NSStackView(views: [diff] + boxes)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = UIStyle.Space.inline
        let fieldWidth = boxes.map { $0.widthAnchor.constraint(equalToConstant: UIStyle.panelWidth) }
        let fieldHeight = CGFloat(boxes.count) * (UIStyle.controlHeight + stack.spacing)
        let gap = boxes.isEmpty ? 0 : stack.spacing
        let height = diff.frame.height + fieldHeight + gap
        stack.frame = NSRect(x: 0, y: 0, width: UIStyle.panelWidth, height: height)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(fieldWidth + [
          stack.widthAnchor.constraint(equalToConstant: UIStyle.panelWidth),
          stack.heightAnchor.constraint(equalToConstant: height),
        ])
        alert.accessoryView = stack
        alert.window.initialFirstResponder = boxes.first
      } else if !boxes.isEmpty {
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = UIStyle.Space.inline
        // An empty field's intrinsic width is the caret. The alert sizes the
        // accessory from fittingSize, so pin the field or it draws as a ring.
        let width = boxes.map { $0.widthAnchor.constraint(equalToConstant: UIStyle.treeWidth) }
        NSLayoutConstraint.activate(width)
        stack.frame = NSRect(
          x: 0, y: 0, width: UIStyle.treeWidth,
          height: CGFloat(boxes.count) * UIStyle.controlHeight + CGFloat(boxes.count - 1) * UIStyle.Space.inline)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = boxes.first
      }

      current = presentation
      presentation.ended = { [weak self] response in
        let position = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if !presentation.withdrawn, order.indices.contains(position) {
          answer(order[position], boxes.map(\.stringValue))
        }
        if self?.current === presentation { self?.current = nil }
        gone()
      }
      if !presentation.shortcuts.isEmpty || presentation.cancelButton != nil {
        presentation.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          guard let self else { return event }
          return self.route(event)
        }
      }
      if let window = Self.sheetHost(anchor?.window) {
        presentation.host = window
        alert.beginSheetModal(for: window) { presentation.end($0) }
      } else {
        // No window to hang it on. `runModal` blocks, so not from inside
        // whatever called this — and not at all if it was taken back first.
        DispatchQueue.main.async {
          guard !presentation.withdrawn else { return }
          presentation.end(alert.runModal())
        }
      }
      return true
    }

    /// Only the visible, frontmost dialog owns these shortcuts. Consuming
    /// repeats prevents held keys from confirming or cancelling a new dialog.
    func route(_ event: NSEvent) -> NSEvent? {
      guard event.type == .keyDown, let current, !current.withdrawn, current.ended != nil,
        event.window === current.alert.window, current.alert.window.isVisible,
        current.alert.window.attachedSheet == nil else { return event }
      if let editor = current.alert.window.firstResponder as? NSTextInputClient,
        editor.hasMarkedText() { return event }
      let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
      let button: NSButton?
      if modifiers.isEmpty && event.keyCode == 53 {
        button = current.cancelButton
      } else {
        button = current.shortcuts.first { shortcut, _ in
          switch shortcut {
          case .enter: modifiers.isEmpty && (event.keyCode == 36 || event.keyCode == 76)
          case .command(let key):
            modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == key.lowercased()
          }
        }?.1
      }
      guard let button else { return event }
      if !event.isARepeat, !current.answering, button.isEnabled {
        current.answering = true
        button.performClick(nil)
      }
      return nil
    }

    /// Ends the sheet, and the dialog with it even when AppKit does not —
    /// a sheet still queued behind another, or a parent already gone —
    /// because the queue waits on this dialog's ending before any other.
    func withdraw() {
      guard let current else { return }
      self.current = nil
      current.withdrawn = true
      let sheet = current.alert.window
      if let host = current.host, sheet.sheetParent != nil {
        host.endSheet(sheet, returnCode: .abort)
      } else if NSApp.modalWindow == sheet {
        NSApp.abortModal()
      } else {
        sheet.orderOut(nil)
      }
      current.end(.abort)
    }

    /// NSAlert's first button is the rightmost. The default verb goes there;
    /// Cancel sits beside it, and anything else further left.
    private static func buttonOrder(_ dialog: Dialog) -> [Int] {
      let primary = dialog.defaultAction ?? dialog.actions.firstIndex { $0.role == .destructive }
      let cancel = dialog.cancelAction
      let rest = dialog.actions.indices.filter { $0 != primary && $0 != cancel }
      return [primary, cancel].compactMap { $0 } + rest
    }

    /// A diff, in a monospaced face. Added lines are green, removed lines red.
    /// Tall enough for a short change, and scrolling once it is not.
    private static func diffScroll(_ text: String) -> NSScrollView {
      let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: UIStyle.panelWidth, height: 0))
      textView.isEditable = false
      textView.isSelectable = true
      textView.isRichText = true
      textView.drawsBackground = false
      textView.textContainerInset = NSSize(width: UIStyle.Space.small, height: UIStyle.Space.small)
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.textContainer?.widthTracksTextView = true
      textView.isHorizontallyResizable = false
      textView.isVerticallyResizable = true
      textView.textContainer?.containerSize = NSSize(width: UIStyle.panelWidth, height: .greatestFiniteMagnitude)
      textView.textStorage?.setAttributedString(coloredDiff(text, font: font))
      if let container = textView.textContainer {
        textView.layoutManager?.ensureLayout(for: container)
      }
      let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
      let inset = textView.textContainerInset.height * 2
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
      let fallback = (textView.layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height)
        * CGFloat(lines) + inset
      let height = min(max(used + inset, fallback, UIStyle.controlHeight * 2), 220)

      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: UIStyle.panelWidth, height: height))
      scroll.drawsBackground = false
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      scroll.documentView = textView
      scroll.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        scroll.widthAnchor.constraint(equalToConstant: UIStyle.panelWidth),
        scroll.heightAnchor.constraint(equalToConstant: height),
      ])
      return scroll
    }

    private static func coloredDiff(_ text: String, font: NSFont) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() {
        let color: NSColor =
          if line.hasPrefix("+") { .systemGreen }
          else if line.hasPrefix("-") { .systemRed }
          else if line.hasPrefix(" ") { .labelColor }
          else { .secondaryLabelColor }
        var piece = String(line)
        if index < lines.count - 1 { piece.append("\n") }
        result.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: color]))
      }
      return result
    }

    private static func box(_ field: Dialog.Field) -> NSTextField {
      let box: NSTextField = field.isSecure ? NSSecureTextField(string: field.initial) : NSTextField(string: field.initial)
      box.placeholderString = field.placeholder
      box.font = .systemFont(ofSize: NSFont.systemFontSize)
      box.cell?.usesSingleLineMode = true
      box.cell?.isScrollable = true
      box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      return box
    }

    /// The anchor's window, or the one a person is looking at — down to
    /// whatever sheet is open on it.
    private static func sheetHost(_ anchor: NSWindow?) -> NSWindow? {
      let visible = anchor.flatMap { $0.isVisible ? $0 : nil }
      guard var window = visible ?? NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.orderedWindows.first(where: \.isVisible)
      else { return nil }
      while let sheet = window.attachedSheet { window = sheet }
      return window
    }
  }
#endif
