#if os(iOS)

  import SwiftUI
  import Tether
  import UIKit

  /// The same job as the AppKit capture, against a different set of facts.
  ///
  /// A phone has two keyboards and they arrive by different routes. The
  /// software one comes through `UIKeyInput` as text and a backspace, already
  /// composed by whatever input method is on screen. A hardware one comes
  /// through `pressesBegan` as a `UIKey`, which is where arrows, Escape and
  /// control chords live — none of which `UIKeyInput` can express.
  ///
  /// Which is why there is a row of keys above the software keyboard. A
  /// terminal without Escape, Tab, the arrows and a Control chord is a
  /// terminal you can type sentences into and nothing else: tmux is reached
  /// by Ctrl-B, a pager by the arrows, a full-screen program by Escape. iOS
  /// will never put those on the keyboard, so this view brings them.
  ///
  /// Reading `UIKey.keyCode` rather than a virtual keycode table is the one
  /// place this implementation is plainly better than the Mac's: the HID
  /// usage is the key's identity, so `.keyboardUpArrow` is the arrow on every
  /// layout rather than the number 126 being the arrow on this one.
  struct PhoneKeyCapture: UIViewRepresentable {
    let onInput: (TerminalInput) -> Void
    var active = true
    var lineHeight: CGFloat = 17
    var onFocus: () -> Void = {}
    /// Lines to move the viewport; positive goes back into history.
    var onScroll: (Int32) -> Void = { _ in }
    var links: TerminalLinks = .none
    var geometry: CellGeometry = .empty
    var latch = Latch()

    func makeUIView(context: Context) -> KeyCaptureView {
      let view = KeyCaptureView()
      apply(to: view)
      return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
      let wasActive = view.wantsFocus
      apply(to: view)
      // Output updates must not reopen a keyboard the person dismissed or
      // steal it from a sheet. Only a newly selected terminal requests focus.
      if active && !wasActive {
        view.becomeFirstResponder()
      } else if !active && view.isFirstResponder {
        view.resignFirstResponder()
      }
    }

    private func apply(to view: KeyCaptureView) {
      view.onInput = onInput
      view.onFocus = onFocus
      view.onScroll = onScroll
      view.lineHeight = lineHeight
      view.wantsFocus = active
      view.links = links
      view.geometry = geometry
      view.latch = latch
    }
  }

  final class KeyCaptureView: UIView, UIKeyInput, UITextInputTraits {
    var wantsFocus = false
    var onFocus: (() -> Void)?
    var onInput: ((TerminalInput) -> Void)?
    var onScroll: ((Int32) -> Void)?
    var lineHeight: CGFloat = 17
    var links: TerminalLinks = .none
    var geometry: CellGeometry = .empty
    var latch = Latch()
    /// A terminal is not prose. The software keyboard's replacements —
    /// capitals, smart quotes, the predictive bar — rewrite what was typed
    /// and change the keyboard's height while they do it.
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    /// The link the context menu in progress is about.
    fileprivate var pressed: TerminalLink?

    /// Lines already sent for the drag in progress, so each update asks for
    /// the difference rather than the total.
    private var carried: Int32 = 0

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = true
      addGestureRecognizer(
        UITapGestureRecognizer(target: self, action: #selector(takeFocus)))
      // The drag belongs to this view rather than to a transparent layer
      // over it: a SwiftUI gesture above a `UIView` takes the touches the
      // view needs to become first responder, and a terminal you cannot
      // focus is a terminal you cannot type into.
      let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
      pan.maximumNumberOfTouches = 1
      addGestureRecognizer(pan)
      // A long-press on a path is a context menu with the file above it —
      // the gesture the rest of the system uses for "show me this".
      addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard wantsFocus else { return }
      // During the SwiftUI update that inserts this view, becoming first
      // responder does not present the keyboard. The next turn does.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.wantsFocus, self.window != nil else { return }
        self.becomeFirstResponder()
      }
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
      let accepted = super.becomeFirstResponder()
      if accepted { reloadInputViews() }
      return accepted
    }

    @objc private func takeFocus() {
      becomeFirstResponder()
      onFocus?()
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
      switch gesture.state {
      case .changed:
        // Whole lines only: a terminal's history has no half-rows to stop
        // between, and each update asks for the difference rather than the
        // total so the two do not compound.
        let lines = Int32((gesture.translation(in: self).y / lineHeight).rounded())
        guard lines != carried else { return }
        onScroll?(lines - carried)
        carried = lines
      case .ended, .cancelled, .failed:
        carried = 0
      default:
        break
      }
    }

    // MARK: - The software keyboard

    /// Always true. A terminal's content is the remote screen, not this
    /// view's, so "has text" cannot be answered from here — and answering
    /// `false` makes the keyboard suppress its delete key.
    var hasText: Bool { true }

    /// Already composed: an input method resolves marked text before it
    /// reaches this, which is why there is no `setMarkedText` dance here as
    /// there is on the Mac.
    func insertText(_ text: String) {
      // The return key arrives as a newline rather than as a key press, and a
      // terminal wants the carriage return its line editor is waiting for.
      if text == "\n" {
        onInput?(.key(.enter, latch.spend()))
        return
      }
      guard !text.isEmpty else { return }
      // Whatever the key bar armed is spent here: this is where Ctrl-B
      // becomes Ctrl-B rather than a `b`.
      onInput?(.key(.text(text), latch.spend()))
    }

    func deleteBackward() {
      onInput?(.key(.backspace, latch.spend()))
    }

    // MARK: - A hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      var handled = false

      for press in presses {
        guard let key = press.key else { continue }
        // Command chords belong to the system: ⌘V and the rest must keep
        // working, and a terminal has nothing to send for them.
        guard !key.modifierFlags.contains(.command) else { continue }
        guard let input = Self.input(for: key) else { continue }
        onInput?(input)
        handled = true
      }

      // Unhandled presses go on down the chain rather than being swallowed,
      // so the system keeps its own shortcuts.
      if !handled { super.pressesBegan(presses, with: event) }
    }

    static func input(for key: UIKey) -> TerminalInput? {
      let modifiers = KeyModifiers(
        shift: key.modifierFlags.contains(.shift),
        alt: key.modifierFlags.contains(.alternate),
        control: key.modifierFlags.contains(.control))

      if let named = namedKey(for: key.keyCode) {
        return .key(named, modifiers)
      }

      // Plain text with no chord is already on its way through `insertText`;
      // sending it here as well would double every character typed on a
      // hardware keyboard.
      guard modifiers.control || modifiers.alt else { return nil }

      // The base letter, not what the modifier produced: the engine applies
      // the chord itself, against the modes the remote program set.
      let base = key.charactersIgnoringModifiers
      guard !base.isEmpty else { return nil }
      return .key(.text(base), modifiers)
    }

    /// The keys that are not text.
    ///
    /// A HID usage is the key's identity, so this table says what it means
    /// rather than where it sits on one particular keyboard.
    /// Internal rather than private so the table can be checked from a test.
    /// It is exactly the kind of code that fails silently: nothing downstream
    /// can tell `Home` from `End` once the wrong one has been chosen.
    static func namedKey(for code: UIKeyboardHIDUsage) -> Key? {
      switch code {
      case .keyboardReturnOrEnter, .keypadEnter: .enter
      case .keyboardTab: .tab
      case .keyboardDeleteOrBackspace: .backspace
      case .keyboardEscape: .escape
      case .keyboardDeleteForward: .delete
      case .keyboardInsert: .insert
      case .keyboardUpArrow: .up
      case .keyboardDownArrow: .down
      case .keyboardLeftArrow: .left
      case .keyboardRightArrow: .right
      case .keyboardHome: .home
      case .keyboardEnd: .end
      case .keyboardPageUp: .pageUp
      case .keyboardPageDown: .pageDown
      case .keyboardF1: .function(1)
      case .keyboardF2: .function(2)
      case .keyboardF3: .function(3)
      case .keyboardF4: .function(4)
      case .keyboardF5: .function(5)
      case .keyboardF6: .function(6)
      case .keyboardF7: .function(7)
      case .keyboardF8: .function(8)
      case .keyboardF9: .function(9)
      case .keyboardF10: .function(10)
      case .keyboardF11: .function(11)
      case .keyboardF12: .function(12)
      default: nil
      }
    }
  }


  /// The shortcut row, in the layout under the terminal rather than floating
  /// over its last line. An input accessory is positioned by the keyboard,
  /// and with no keyboard on screen it was drawn on top of the prompt.
  struct TerminalKeyBar: UIViewRepresentable {
    var latch: Latch
    var onInput: (TerminalInput) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> KeyBar {
      context.coordinator.latch = latch
      context.coordinator.onInput = onInput
      let bar = KeyBar(
        onKey: { [weak coordinator = context.coordinator] key in
          guard let coordinator else { return }
          coordinator.onInput(.key(key, coordinator.latch.spend()))
        },
        onModifier: { [weak coordinator = context.coordinator] modifier in
          guard let coordinator else { return }
          switch modifier {
          case .control: coordinator.latch.toggle(control: true)
          case .option: coordinator.latch.toggle(control: false)
          }
        },
        onDismiss: {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
      latch.onChange = { [weak bar] modifiers in bar?.show(modifiers) }
      bar.show(latch.armed)
      bar.setContentHuggingPriority(.required, for: .vertical)
      bar.setContentCompressionResistancePriority(.required, for: .vertical)
      return bar
    }

    func updateUIView(_ bar: KeyBar, context: Context) {
      context.coordinator.latch = latch
      context.coordinator.onInput = onInput
      latch.onChange = { [weak bar] modifiers in bar?.show(modifiers) }
      bar.show(latch.armed)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyBar, context: Context) -> CGSize? {
      CGSize(width: proposal.width ?? uiView.bounds.width, height: uiView.fittingHeight)
    }

    final class Coordinator {
      var latch = Latch()
      var onInput: (TerminalInput) -> Void = { _ in }
    }
  }

  /// The keys iOS will not put on a keyboard.
  ///
  /// Glyphs and three-letter names, not words: this is one row above a
  /// software keyboard, and it has to stay one row on the narrowest phone.
  /// Ctrl and Opt are latches rather than chords — two taps cannot be held
  /// at once — and they light up while they are armed so that a person can
  /// see what the next key will be.
  final class KeyBar: UIInputView {
    enum Modifier { case control, option }
    /// The control height for this platform, scaled by the device's text size.

    private let onKey: (Key) -> Void
    private let onModifier: (Modifier) -> Void
    private let onDismiss: () -> Void
    private var control: UIButton?
    private var option: UIButton?
    private var keys: [UIButton] = []
    private var titles: [ObjectIdentifier: String] = [:]
    private var symbols: [ObjectIdentifier: String] = [:]
    private var widths: [NSLayoutConstraint] = []
    private var stackSpacing: UIStackView?
    private var sideInset: NSLayoutConstraint?
    private var verticalInsets: [NSLayoutConstraint] = []

    /// Height of one row on this device, from the text size it is using.
    var fittingHeight: CGFloat { touch + gap * 2 }
    private var touch: CGFloat {
      UIFontMetrics(forTextStyle: .body).scaledValue(
        for: UIStyle.controlHeight, compatibleWith: traitCollection)
    }
    private var gap: CGFloat {
      UIFontMetrics(forTextStyle: .body).scaledValue(
        for: UIStyle.Space.small, compatibleWith: traitCollection)
    }
    private var font: UIFont {
      UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection)
    }

    init(
      onKey: @escaping (Key) -> Void, onModifier: @escaping (Modifier) -> Void,
      onDismiss: @escaping () -> Void
    ) {
      self.onKey = onKey
      self.onModifier = onModifier
      self.onDismiss = onDismiss
      super.init(frame: .zero, inputViewStyle: .keyboard)
      autoresizingMask = .flexibleWidth

      let control = latch("ctrl", .control)
      let option = latch("opt", .option)
      self.control = control
      self.option = option

      let stack = UIStackView(arrangedSubviews: [
        key(title: "esc", named: "Escape") { [weak self] in self?.onKey(.escape) },
        control,
        option,
        key(title: "tab", named: "Tab") { [weak self] in self?.onKey(.tab) },
        key(symbol: "arrow.left", named: "Left") { [weak self] in self?.onKey(.left) },
        key(symbol: "arrow.down", named: "Down") { [weak self] in self?.onKey(.down) },
        key(symbol: "arrow.up", named: "Up") { [weak self] in self?.onKey(.up) },
        key(symbol: "arrow.right", named: "Right") { [weak self] in self?.onKey(.right) },
        key(symbol: "keyboard.chevron.compact.down", named: "Hide keyboard") {
          [weak self] in self?.onDismiss()
        },
      ])
      let scroll = UIScrollView()
      scroll.showsHorizontalScrollIndicator = false
      scroll.alwaysBounceHorizontal = false
      scroll.translatesAutoresizingMaskIntoConstraints = false
      addSubview(scroll)
      stack.axis = .horizontal
      stack.distribution = .fillEqually
      stack.spacing = gap
      stack.translatesAutoresizingMaskIntoConstraints = false
      scroll.addSubview(stack)
      stackSpacing = stack
      keys = stack.arrangedSubviews.compactMap { $0 as? UIButton }
      widths = keys.map { button in
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: touch)
        width.isActive = true
        return width
      }
      let fill = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
      fill.priority = .defaultHigh
      let availableWidth = scroll.widthAnchor.constraint(
        equalTo: safeAreaLayoutGuide.widthAnchor, constant: -gap * 2)
      availableWidth.priority = .defaultHigh
      let top = scroll.topAnchor.constraint(equalTo: topAnchor, constant: gap)
      let bottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap)
      sideInset = availableWidth
      verticalInsets = [top, bottom]
      NSLayoutConstraint.activate([
        scroll.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
        scroll.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor),
        scroll.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor),
        top,
        bottom,
        stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
        stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        fill,
        availableWidth,
      ])
      restyle()
    }

    override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: fittingHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      guard traitCollection.preferredContentSizeCategory
        != previousTraitCollection?.preferredContentSizeCategory
      else { return }
      restyle()
      invalidateIntrinsicContentSize()
    }

    private func restyle() {
      stackSpacing?.spacing = gap
      for constraint in widths { constraint.constant = touch }
      sideInset?.constant = -gap * 2
      for (index, constraint) in verticalInsets.enumerated() {
        constraint.constant = index == 0 ? gap : -gap
      }
      let symbol = UIImage.SymbolConfiguration(font: font, scale: .medium)
      for button in keys {
        var configuration = button.configuration ?? .gray()
        configuration.contentInsets = .init(top: gap, leading: gap, bottom: gap, trailing: gap)
        let id = ObjectIdentifier(button)
        if let title = titles[id] {
          configuration.attributedTitle = AttributedString(
            title, attributes: AttributeContainer([.font: font]))
          configuration.image = nil
        }
        if let name = symbols[id] {
          configuration.image = UIImage(systemName: name, withConfiguration: symbol)
          configuration.attributedTitle = nil
        }
        button.configuration = configuration
      }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Lights the latches that are armed.
    func show(_ modifiers: KeyModifiers) {
      tint(control, on: modifiers.control)
      tint(option, on: modifiers.alt)
    }

    private func tint(_ button: UIButton?, on: Bool) {
      button?.configuration?.baseBackgroundColor = on ? .tintColor : nil
      button?.configuration?.baseForegroundColor = on ? .white : nil
      button?.isSelected = on
      button?.accessibilityTraits = on ? [.button, .selected] : [.button]
    }

    private func key(
      title: String? = nil, symbol: String? = nil, named name: String,
      action: @escaping () -> Void
    ) -> UIButton {
      var configuration = UIButton.Configuration.gray()
      configuration.cornerStyle = .medium
      let button = UIButton(
        configuration: configuration,
        primaryAction: UIAction { _ in action() })
      button.accessibilityLabel = name
      if let title { titles[ObjectIdentifier(button)] = title }
      if let symbol { symbols[ObjectIdentifier(button)] = symbol }
      return button
    }

    private func latch(_ title: String, _ modifier: Modifier) -> UIButton {
      key(title: title, named: title) { [weak self] in self?.onModifier(modifier) }
    }
  }

  extension KeyCaptureView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard let cell = geometry.cell(at: location), let link = links.find(cell.row, cell.column),
        let menu = links.menu(link), !menu.items.isEmpty
      else { return nil }
      pressed = link
      let preview = menu.preview.map { make in
        { () -> UIViewController? in UIHostingController(rootView: make()) }
      }
      return UIContextMenuConfiguration(
        identifier: nil, previewProvider: preview,
        actionProvider: { _ in
          UIMenu(
            children: menu.items.map { item in
              UIAction(
                title: item.title, image: UIImage(systemName: item.symbol),
                attributes: item.destructive ? .destructive : []
              ) { _ in item.action() }
            })
        })
    }

    /// Lifts the link's own cells, not the whole terminal: a snapshot of
    /// the drawn text where it is, so the person sees what they pressed.
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configuration: UIContextMenuConfiguration,
      highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
      guard let link = pressed, let window else { return nil }
      let rect = geometry.rect(for: link).insetBy(dx: -2, dy: -1)
      let lifted =
        window.resizableSnapshotView(
          from: convert(rect, to: window), afterScreenUpdates: false, withCapInsets: .zero)
        ?? UIView(frame: CGRect(origin: .zero, size: rect.size))
      lifted.frame = CGRect(origin: .zero, size: rect.size)
      let parameters = UIPreviewParameters()
      parameters.visiblePath = UIBezierPath(
        roundedRect: lifted.bounds, cornerRadius: UIStyle.rowRadius)
      return UITargetedPreview(
        view: lifted, parameters: parameters,
        target: UIPreviewTarget(container: self, center: CGPoint(x: rect.midX, y: rect.midY)))
    }

    /// Tapping the preview opens what it shows.
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
      animator: any UIContextMenuInteractionCommitAnimating
    ) {
      guard let link = pressed else { return }
      animator.addCompletion { [weak self] in self?.links.open(link) }
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      willEndFor configuration: UIContextMenuConfiguration,
      animator: (any UIContextMenuInteractionAnimating)?
    ) {
      animator?.addCompletion { [weak self] in self?.pressed = nil }
    }
  }

#endif
