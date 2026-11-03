#if os(iOS)

  import SwiftUI
  import Tether
  import UIKit

  extension Notification.Name {
    /// `PhoneKeyboard.staysDown` changed. The capture view reloads its input
    /// view, and the key bar updates the button that asked.
    static let tetherSoftwareKeyboard = Notification.Name("tether.softwareKeyboard")
  }

  /// The software keyboard stays down when the app comes forward. A tap on
  /// the terminal asks for it; opening the app, or switching back to it,
  /// does not. The key at the end of the shortcut row toggles the same flag.
  /// An iPad starts with it up.
  ///
  /// Down does not resign first responder. The capture keeps an empty input
  /// view instead, so a hardware keyboard and the edit menu still have a
  /// responder while the software keyboard is hidden.
  @MainActor
  enum PhoneKeyboard {
    static var staysDown = UIDevice.current.userInterfaceIdiom == .phone {
      didSet {
        guard staysDown != oldValue else { return }
        NotificationCenter.default.post(name: .tetherSoftwareKeyboard, object: nil)
      }
    }

    static func allowsAutomaticFocus(phone: Bool) -> Bool {
      !(phone && staysDown)
    }

    static func noteLeftForeground(phone: Bool) {
      if phone { staysDown = true }
    }

    static func noteTapped(phone: Bool) {
      if phone { staysDown = false }
    }

    static func toggle() { staysDown.toggle() }
  }

  /// Whether the keyboard is still choosing a character, and whether a double
  /// tap may copy the word under it.
  ///
  /// English (and any direct layout) commits each letter as it is typed, so
  /// a double tap is free to copy. Pinyin, kana and hangul are still the
  /// input method's: a double tap there would take the word they have not
  /// chosen yet.
  enum PhoneInput {
    static func multistage(_ language: String?) -> Bool {
      guard let language = language?.lowercased() else { return false }
      return language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")
    }

    static func quickCopy(language: String?, composing: Bool) -> Bool {
      !composing && !multistage(language)
    }

    static func correction(for language: String?) -> UITextAutocorrectionType {
      multistage(language) ? .default : .no
    }
  }

  /// Workspace actions, split on the separators the Mac menu uses.
  enum PhoneMenu {
    static func workspaceSections(_ items: [TerminalMenuItem]) -> [[TerminalMenuItem]] {
      var sections: [[TerminalMenuItem]] = [[]]
      for item in items {
        if item.title.isEmpty {
          if !sections[sections.count - 1].isEmpty { sections.append([]) }
        } else {
          sections[sections.count - 1].append(item)
        }
      }
      return sections.filter { !$0.isEmpty }
    }
  }

  /// The same job as the AppKit capture, against a different set of facts.
  ///
  /// A phone has two keyboards and they arrive by different routes. The
  /// software one comes through `UITextInput` as text and a backspace.
  /// Composing characters arrive as marked text and are drawn at the caret;
  /// only the chosen candidate is sent on. A hardware one comes
  /// through `pressesBegan` as a `UIKey`, which is where arrows, Escape and
  /// control chords live — none of which marked text can express.
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
    var claimsWheel: (Int32, UInt16, UInt16) -> WheelClaim = { _, _, _ in .pass }
    var links: TerminalLinks = .none
    var geometry: CellGeometry = .empty
    var cursorRect: CGRect = .zero
    var latch = Latch()
    var mouse: MouseTracking = .off
    var onSelection: (SelectionUpdate) -> Void = { _ in }
    var selection: GridSelection?
    var menuItems: [TerminalMenuItem] = []

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
      view.claimsWheel = claimsWheel
      view.lineHeight = lineHeight
      view.wantsFocus = active
      view.links = links
      view.geometry = geometry
      view.cursorRect = cursorRect
      view.latch = latch
      view.mouse = mouse
      view.onSelection = onSelection
      view.selection = selection
      view.menuItems = menuItems
    }
  }

  final class KeyCaptureView: UIView, UITextInput, UITextInputTraits {
    var wantsFocus = false
    var onFocus: (() -> Void)?
    var onInput: ((TerminalInput) -> Void)?
    var onScroll: ((Int32) -> Void)?
    var claimsWheel: (Int32, UInt16, UInt16) -> WheelClaim = { _, _, _ in .pass }
    var lineHeight: CGFloat = 17
    var links: TerminalLinks = .none
    var geometry: CellGeometry = .empty
    var latch = Latch()
    var mouse: MouseTracking = .off
    var onSelection: (SelectionUpdate) -> Void = { _ in }
    var selection: GridSelection?
    var menuItems: [TerminalMenuItem] = []
    /// The cell a drag last reported, so a finger that stays put is quiet.
    private var reported: (row: UInt16, column: UInt16)?
    /// The caret, in this view's top-left coordinates, so composing text
    /// and the candidate window sit on the cell the terminal is drawing.
    var cursorRect: CGRect = .zero {
      didSet {
        guard cursorRect != oldValue, !marked.isEmpty else { return }
        setNeedsDisplay()
      }
    }
    /// Pinyin (or whatever the input method has not committed). Empty once
    /// a candidate is chosen and sent.
    private var composition = PhoneComposition()
    private var marked: String { composition.marked }
    var composing: String { marked }
    /// Where the input method's caret sits inside `marked`, in UTF-16.
    /// Empty when nothing is being composed. The caret itself is never nil:
    /// a multistage keyboard will not mark text without one.
    private var markedSelection: NSRange {
      get { composition.caret }
      set { composition.caret = newValue }
    }
    var markedTextStyle: [NSAttributedString.Key: Any]?
    weak var inputDelegate: UITextInputDelegate?
    private var storedTokenizer: UITextInputStringTokenizer?
    /// How many fingers this drag has seen. A second one makes it a wheel
    /// even after the first has already moved.
    private var touchPeak = 0
    /// A terminal is not prose. The software keyboard's replacements —
    /// capitals, smart quotes, the predictive bar — rewrite what was typed
    /// and change the keyboard's height while they do it.
    ///
    /// Correction stays off for a direct layout. Turning it off for every
    /// layout also turns off the candidate bar, and pinyin then has nowhere
    /// to put a character. Stored, and updated when the input mode changes:
    /// a computed value the setter throws away makes UIKit reload the
    /// keyboard until the keystrokes are gone.
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
    private var selectionAnchor: GridPoint?
    /// Gestures this view installed. They do not run alongside each other.
    /// The system's context menu is not one of them: it is later than the
    /// selection press, and agreeing to run together shows two menus.
    private var ownedGestures: [UIGestureRecognizer] = []
    private var selectionPress: UILongPressGestureRecognizer?
    private var editMenu: UIEditMenuInteraction?
    /// Set while a press is a selection or a menu, so the tap that ends it
    /// is not also a click.
    private var consumedPress = false
    private var editPoint: CGPoint = .zero
    /// Double tap. It fails immediately on a multistage keyboard, so the
    /// single tap does not wait out a copy that will not happen.
    private var quickTap: UITapGestureRecognizer?
    /// An empty input view keeps this view first responder while the software
    /// keyboard is down. Resigning would take the edit menu with it.
    private let blankKeyboard: UIView = {
      let view = UIView(frame: .zero)
      view.backgroundColor = .clear
      view.isUserInteractionEnabled = false
      return view
    }()
    /// Gestures the edit menu installed. The context menu's press has to
    /// wait; these must not, or the menu shown on release never appears.
    private var editMenuGestureIDs: Set<ObjectIdentifier> = []
    private var deferredMenuGestures: [ObjectIdentifier] = []
    /// The last input-mode class `reloadInputViews` was asked for, so a
    /// switch to pinyin reloads once and does not loop.
    private var traitsMultistage = false
    private var reloadingTraits = false

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = true
      // Drawing the preedit must not paint an opaque plate over the grid.
      isOpaque = false
      backgroundColor = .clear
      // The drag belongs to this view rather than to a transparent layer
      // over it: a SwiftUI gesture above a `UIView` takes the touches the
      // view needs to become first responder, and a terminal you cannot
      // focus is a terminal you cannot type into.
      // One recognizer for one and two fingers. A separate two-finger pan
      // never begins: the one-finger pan has already claimed the first touch.
      let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
      pan.maximumNumberOfTouches = 2
      pan.delegate = self
      addGestureRecognizer(pan)
      // A still finger is a selection, not a scroll. The pan waits until
      // that press fails, which a moving finger does within a few points.
      // 0.45s is inside the system's context-menu press (about 0.55s), so
      // on ordinary text this press wins and the menu is shown when it ends.
      let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdSelecting(_:)))
      hold.minimumPressDuration = 0.45
      hold.allowableMovement = 12
      hold.cancelsTouchesInView = false
      hold.delegate = self
      addGestureRecognizer(hold)
      selectionPress = hold
      pan.require(toFail: hold)
      // A tap waits out the drag, so a click is not also the start of a scroll.
      let tap = UITapGestureRecognizer(target: self, action: #selector(takeFocus(_:)))
      tap.require(toFail: pan)
      // A recognized press is a selection. The tap that would clear it has
      // to wait that press out, and fail when the press wins.
      tap.require(toFail: hold)
      // English (any direct layout) copies the word on a double tap. The
      // single tap waits so the first tap of that pair is not also a click.
      let quick = UITapGestureRecognizer(target: self, action: #selector(quickCopied(_:)))
      quick.numberOfTapsRequired = 2
      quick.delegate = self
      addGestureRecognizer(quick)
      quickTap = quick
      tap.require(toFail: quick)
      addGestureRecognizer(tap)
      ownedGestures = [pan, hold, tap, quick]
      // A long-press on a path is the system's context menu, with the file
      // above it. Ordinary text loses that race — this view's press is
      // shorter — and shows the same actions from an edit menu on release.
      let editing = UIEditMenuInteraction(delegate: self)
      editMenu = editing
      addInteraction(editing)
      editMenuGestureIDs = Set((gestureRecognizers ?? []).map { ObjectIdentifier($0) })
      addInteraction(UIContextMenuInteraction(delegate: self))
      deferSystemMenu(to: hold)
      let center = NotificationCenter.default
      center.addObserver(self, selector: #selector(leftForeground(_:)),
        name: UIScene.didEnterBackgroundNotification, object: nil)
      center.addObserver(self, selector: #selector(enteredForeground(_:)),
        name: UIScene.willEnterForegroundNotification, object: nil)
      center.addObserver(self, selector: #selector(enteredForeground(_:)),
        name: UIScene.didActivateNotification, object: nil)
      center.addObserver(self, selector: #selector(inputModeChanged),
        name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
      center.addObserver(self, selector: #selector(softwareKeyboardChanged),
        name: .tetherSoftwareKeyboard, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    override var canBecomeFirstResponder: Bool { wantsFocus }

    /// Empty while the software keyboard is suppressed, so this view can stay
    /// first responder — the edit menu and a hardware keyboard need that —
    /// without the system keyboard covering the terminal.
    override var inputView: UIView? {
      PhoneKeyboard.staysDown ? blankKeyboard : nil
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      // The edit menu's gestures arrive with the window. They must not be
      // told to wait for the selection press: that press already won, and
      // the menu it presents then does nothing.
      if window != nil { absorbEditMenuGestures() }
      if let selectionPress { deferSystemMenu(to: selectionPress) }
      guard wantsFocus else { return }
      // During the SwiftUI update that inserts this view, becoming first
      // responder does not present the keyboard. The next turn does.
      // Coming forward leaves that keyboard down (`PhoneKeyboard`).
      DispatchQueue.main.async { [weak self] in
        guard let self, self.wantsFocus, self.window != nil else { return }
        self.becomeFirstResponder()
      }
    }

    /// Gestures whose type is the edit menu's own. Named that way because
    /// the interaction does not hand them out.
    private func absorbEditMenuGestures() {
      for gesture in gestureRecognizers ?? [] {
        let name = String(describing: type(of: gesture))
        if name.contains("EditMenu") { editMenuGestureIDs.insert(ObjectIdentifier(gesture)) }
      }
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
      guard canBecomeFirstResponder else { return false }
      // Set before the keyboard is built. Reloading here tears the input
      // method down before it has attached, and Chinese then types nothing.
      let language = textInputMode?.primaryLanguage
      autocorrectionType = PhoneInput.correction(for: language)
      traitsMultistage = PhoneInput.multistage(language)
      return super.becomeFirstResponder()
    }

    /// The shortcut row, or a tap, changed whether the software keyboard is up.
    @objc private func softwareKeyboardChanged() {
      guard window != nil else { return }
      if wantsFocus, !isFirstResponder, !PhoneKeyboard.staysDown {
        _ = becomeFirstResponder()
      }
      reloadInputViews()
    }

    /// The app left the foreground. The keyboard it had up is not brought
    /// back with it. The view stays first responder, so a long-press after
    /// returning still has a menu.
    @objc private func leftForeground(_ note: Notification) {
      guard sceneMatches(note) else { return }
      PhoneKeyboard.noteLeftForeground(phone: phone)
    }

    /// iOS restores the system keyboard as the scene activates. Put the empty
    /// input view back until a tap or the key bar asks for the keyboard.
    @objc private func enteredForeground(_ note: Notification) {
      guard sceneMatches(note), PhoneKeyboard.staysDown else { return }
      reloadInputViews()
    }

    private func sceneMatches(_ note: Notification) -> Bool {
      guard let scene = note.object as? UIScene, let mine = window?.windowScene else { return true }
      return scene === mine
    }

    /// Switching onto pinyin (or kana, or hangul) has to reread correction,
    /// or the candidate bar stays the one built for a direct layout. Once,
    /// and not while a word is open: reloading then drops the composition.
    @objc private func inputModeChanged() {
      let language = textInputMode?.primaryLanguage
      let next = PhoneInput.multistage(language)
      autocorrectionType = PhoneInput.correction(for: language)
      let changed = next != traitsMultistage
      traitsMultistage = next
      guard changed, !reloadingTraits, isFirstResponder, marked.isEmpty else { return }
      reloadingTraits = true
      reloadInputViews()
      reloadingTraits = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      consumedPress = false
      super.touchesBegan(touches, with: event)
    }

    @objc private func takeFocus(_ gesture: UITapGestureRecognizer) {
      guard wantsFocus else { return }
      if consumedPress {
        consumedPress = false
        return
      }
      if selection != nil {
        onSelection(.clear)
        selection = nil
        return
      }
      PhoneKeyboard.noteTapped(phone: phone)
      if !isFirstResponder { becomeFirstResponder() }
      onFocus?()
      guard mouse != .off, gesture.state == .ended else { return }
      guard let cell = geometry.cell(at: gesture.location(in: self)) else { return }
      point(.press, button: .left, cell: cell)
      point(.release, button: .left, cell: cell)
    }

    /// Double tap. Copies the word when the keyboard commits letters directly.
    @objc private func quickCopied(_ gesture: UITapGestureRecognizer) {
      guard gesture.state == .ended else { return }
      _ = quickCopy(at: gesture.location(in: self), language: textInputMode?.primaryLanguage)
    }

    /// The word under `location`, onto the clipboard. Nothing while a word
    /// is still being chosen, or while the keyboard is multistage.
    @discardableResult
    func quickCopy(at location: CGPoint, language: String?) -> Bool {
      guard wantsFocus, PhoneInput.quickCopy(language: language, composing: !marked.isEmpty) else { return false }
      guard let cell = geometry.cell(at: location) else { return false }
      let point = GridPoint(row: Int(cell.row), column: Int(cell.column))
      onSelection(.copy(.word, point, point))
      return true
    }

    /// A still finger selects. Moving it grows the selection. Lifting leaves
    /// the highlight and shows Copy, Close and the rest: the system's own
    /// menu loses to this shorter press, so it never gets to show them.
    @objc private func holdSelecting(_ gesture: UILongPressGestureRecognizer) {
      guard wantsFocus, marked.isEmpty else { return }
      guard let cell = geometry.clampedCell(at: gesture.location(in: self)) else { return }
      let point = GridPoint(row: Int(cell.row), column: Int(cell.column))
      switch gesture.state {
      case .began:
        consumedPress = true
        // The menu needs a first responder. Becoming one with the empty input
        // view does not raise the software keyboard.
        if !isFirstResponder { _ = becomeFirstResponder() }
        selectionAnchor = point
        onSelection(.highlight(.word, point, point))
      case .changed:
        onSelection(.highlight(.character, selectionAnchor ?? point, point))
      case .ended:
        selectionAnchor = nil
        editPoint = gesture.location(in: self)
        // Presenting in this callback is dismissed by the touch that just
        // ended. The next turn is after that touch has left.
        DispatchQueue.main.async { [weak self] in
          self?.presentEditingMenu()
        }
      case .cancelled, .failed:
        selectionAnchor = nil
      default:
        break
      }
    }

    /// Ordinary text belongs to the selection press. A link does not: that
    /// press fails, and the system's menu — which waits for this one — shows
    /// the file.
    private func presentEditingMenu() {
      guard wantsFocus, marked.isEmpty, window != nil else { return }
      if !isFirstResponder { _ = becomeFirstResponder() }
      editMenu?.presentEditMenu(
        with: UIEditMenuConfiguration(identifier: nil, sourcePoint: editPoint))
    }

    func ownsSelectionPress(at location: CGPoint) -> Bool {
      guard wantsFocus, marked.isEmpty else { return false }
      guard let cell = geometry.clampedCell(at: location) else { return false }
      return links.find(cell.row, cell.column) == nil
    }

    /// The system's menu waits until the selection press has failed. On a
    /// link that failure is the moment the press would have begun, which is
    /// what lets the file menu appear. The edit menu is not one of these:
    /// it is presented after the press has already succeeded.
    private func deferSystemMenu(to press: UILongPressGestureRecognizer) {
      for gesture in gestureRecognizers ?? [] {
        let id = ObjectIdentifier(gesture)
        guard !editMenuGestureIDs.contains(id), !deferredMenuGestures.contains(id),
          !ownedGestures.contains(where: { $0 === gesture })
        else { continue }
        // The system menu's press is a touch-duration observer and a simple
        // press, not a type whose name says "context menu". Relationship
        // recognizers are the failure edges themselves and must be left alone.
        let name = String(describing: type(of: gesture))
        guard name.contains("TouchDuration") || name.contains("SimplePress") || name.contains("SecondaryClick")
        else { continue }
        gesture.require(toFail: press)
        deferredMenuGestures.append(id)
      }
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
      guard wantsFocus else { return }
      if gesture.state == .began { touchPeak = gesture.numberOfTouches }
      if gesture.state == .changed || gesture.state == .ended {
        touchPeak = max(touchPeak, gesture.numberOfTouches)
      }
      defer {
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
          touchPeak = 0
          carried = 0
          if reported != nil { endPointer(at: gesture.location(in: self)) }
        }
      }
      if selection != nil || selectionAnchor != nil {
        dragSelection(gesture)
        return
      }
      let kind = PhoneDrag.kind(
        touches: max(touchPeak, gesture.numberOfTouches), mouse: mouse, selecting: false,
        translation: gesture.translation(in: self))
      switch kind {
      case .selection:
        dragSelection(gesture)
      case .scroll:
        if reported != nil { endPointer(at: gesture.location(in: self)) }
        scrollDrag(gesture)
      case .pointer:
        // A vertical swipe declares itself after a few points. Pressing on
        // the first movement would click the pane and then scroll it.
        let translation = gesture.translation(in: self)
        guard hypot(translation.x, translation.y) >= PhoneDrag.slop else { return }
        dragPointer(gesture)
      }
    }

    /// Whole lines only: a terminal's history has no half-rows to stop
    /// between, and each update asks for the difference rather than the total.
    private func scrollDrag(_ gesture: UIPanGestureRecognizer) {
      guard gesture.state == .changed || gesture.state == .ended else { return }
      let lines = Int32((gesture.translation(in: self).y / max(lineHeight, 1)).rounded())
      let step = lines - carried
      guard step != 0 else { return }
      carried = lines
      let cell = geometry.clampedCell(at: gesture.location(in: self))
      let claim = cell.map { claimsWheel(step, $0.column, $0.row) } ?? .pass
      WheelDispatch.route(
        lines: step, shift: false, mouse: mouse, hasCell: cell != nil, claim: claim,
        report: { button in
          guard let cell else { return }
          self.point(.press, button: button, cell: cell)
        },
        scroll: { self.onScroll?($0) })
    }

    private func dragSelection(_ gesture: UIPanGestureRecognizer) {
      guard let cell = geometry.clampedCell(at: gesture.location(in: self)) else { return }
      let point = GridPoint(row: Int(cell.row), column: Int(cell.column))
      switch gesture.state {
      case .began:
        selectionAnchor = selection?.anchor ?? point
      case .changed, .ended:
        if let anchor = selectionAnchor {
          onSelection(.highlight(.character, anchor, point))
        }
        if gesture.state == .ended { selectionAnchor = nil }
      case .cancelled, .failed:
        selectionAnchor = nil
      default: break
      }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      if action == #selector(copy(_:)) { return wantsFocus && selection != nil }
      if action == #selector(paste(_:)) { return wantsFocus && UIPasteboard.general.hasStrings }
      // Marked text makes this view a text input. Select and Select All
      // would offer to edit a document it does not have.
      if action == #selector(select(_:)) || action == #selector(selectAll(_:)) { return false }
      return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
      guard wantsFocus, let selection else { return }
      onSelection(.copyExisting(selection))
    }

    override func paste(_ sender: Any?) {
      guard wantsFocus, let text = UIPasteboard.general.string else { return }
      pasteText(text)
    }

    func pasteText(_ text: String) {
      guard wantsFocus, !text.isEmpty else { return }
      onSelection(.clear)
      selection = nil
      onInput?(.paste(text))
    }

    /// A sideways drag is the mouse a program asked for. A vertical one, and
    /// every two-finger drag, scrolls: tmux with mouse mode otherwise keeps
    /// the only finger and the history never moves.
    private func dragPointer(_ gesture: UIPanGestureRecognizer) {
      let point = gesture.location(in: self)
      switch gesture.state {
      case .began, .changed:
        guard let cell = geometry.clampedCell(at: point) else { return }
        if reported == nil {
          becomeFirstResponder()
          self.point(.press, button: .left, cell: cell)
          reported = cell
          return
        }
        guard mouse == .drag || mouse == .any else { return }
        guard reported?.row != cell.row || reported?.column != cell.column else { return }
        reported = cell
        self.point(.move, button: .left, cell: cell)
      case .ended, .cancelled, .failed:
        endPointer(at: point)
      default:
        break
      }
    }

    private func endPointer(at point: CGPoint) {
      if reported != nil, let cell = geometry.clampedCell(at: point) {
        self.point(.release, button: .left, cell: cell)
      }
      reported = nil
    }

    private func point(_ phase: PointerPhase, button: PointerButton, cell: (row: UInt16, column: UInt16)) {
      onInput?(.pointer(button: button, phase: phase, column: cell.column, row: cell.row))
    }

    // MARK: - The software keyboard

    /// Always true. A terminal's content is the remote screen, not this
    /// view's, so "has text" cannot be answered from here — and answering
    /// `false` makes the keyboard suppress its delete key.
    var hasText: Bool { true }

    /// A candidate, or a key the input method did not keep for itself.
    /// Composing text is drawn here and is not sent until this is called.
    func insertText(_ text: String) {
      let replacing = !marked.isEmpty
      if replacing { beginCompositionChange() }
      let committed = composition.insert(text)
      if replacing { endCompositionChange() }
      if let committed { sendCommitted(committed) }
    }

    func deleteBackward() {
      // Backspace while a word is still being chosen edits that word.
      // Sending it would delete whatever cell the caret is sitting on.
      guard !marked.isEmpty else {
        onInput?(.key(.backspace, latch.spend()))
        return
      }
      beginCompositionChange()
      _ = composition.deleteBackward()
      endCompositionChange()
    }

    private func beginCompositionChange() {
      inputDelegate?.selectionWillChange(self)
      inputDelegate?.textWillChange(self)
    }

    private func endCompositionChange() {
      inputDelegate?.textDidChange(self)
      inputDelegate?.selectionDidChange(self)
      setNeedsDisplay()
    }

    /// The return key arrives as a newline rather than as a key press, and a
    /// terminal wants the carriage return its line editor is waiting for.
    /// Whatever the key bar armed is spent here.
    private func sendCommitted(_ text: String) {
      if text == "\n" {
        onInput?(.key(.enter, latch.spend()))
        return
      }
      guard !text.isEmpty else { return }
      onInput?(.key(.text(text), latch.spend()))
    }

    override func draw(_ rect: CGRect) {
      guard !marked.isEmpty else { return }
      let text = marked as NSString
      let font = UIFont.monospacedSystemFont(ofSize: max(8, lineHeight * 0.8), weight: .regular)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.label,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]
      let measured = text.size(withAttributes: attributes)
      let height = cursorRect.height > 0 ? cursorRect.height : lineHeight
      let originY = cursorRect == .zero ? bounds.height - height : cursorRect.minY
      var chip = CGRect(
        x: cursorRect.minX, y: originY, width: measured.width + 6, height: height)
      if chip.maxX > bounds.width { chip.origin.x = max(0, bounds.width - chip.width) }
      UIColor.systemBackground.setFill()
      UIBezierPath(roundedRect: chip, cornerRadius: 2).fill()
      let baseline = chip.minY + max(0, (height - measured.height) / 2)
      text.draw(at: CGPoint(x: chip.minX + 3, y: baseline), withAttributes: attributes)
    }

    // MARK: - A hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      // Letters of a word still being chosen belong to the input method.
      // Sending them here as well would type the pinyin into the shell.
      if markedTextRange != nil {
        super.pressesBegan(presses, with: event)
        return
      }
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

  /// Where a finger goes. Two fingers are a wheel. One finger scrolls when
  /// nothing has taken the mouse, and also when the drag is vertical: tmux
  /// with mouse mode would otherwise turn that finger into a selection and
  /// the pane would not move. A sideways drag stays a pointer.
  enum PhoneDrag: Equatable {
    case scroll
    case pointer
    case selection

    static let slop: CGFloat = 8

    static func kind(
      touches: Int, mouse: MouseTracking, selecting: Bool, translation: CGPoint
    ) -> PhoneDrag {
      if selecting { return .selection }
      if touches >= 2 || mouse == .off { return .scroll }
      if abs(translation.y) >= abs(translation.x), abs(translation.y) >= slop { return .scroll }
      return .pointer
    }
  }

  extension KeyCaptureView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer === quickTap {
        return PhoneInput.quickCopy(language: textInputMode?.primaryLanguage, composing: !marked.isEmpty)
      }
      guard gestureRecognizer === selectionPress else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
      return ownsSelectionPress(at: gestureRecognizer.location(in: self))
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      // A second menu running with the selection press is the one that
      // hid Close. These stay exclusive. A link fails the press instead,
      // and the system's menu then runs on its own.
      false
    }
  }

  extension KeyCaptureView {
    private var markedEnd: Int { marked.utf16.count }

    private func positionOffset(_ position: UITextPosition) -> Int {
      (position as? InputPosition)?.offset ?? 0
    }

    private func replaceMarked(_ text: String?) {
      let next = text ?? ""
      setMarkedText(next, selectedRange: NSRange(location: next.utf16.count, length: 0))
    }
  }

  extension KeyCaptureView {
    var selectedTextRange: UITextRange? {
      get {
        // Nil tells a pinyin keyboard there is no caret, and it never marks.
        if marked.isEmpty { return InputRange(0, 0) }
        let start = min(max(0, markedSelection.location), markedEnd)
        let end = min(start + max(0, markedSelection.length), markedEnd)
        return InputRange(start, end)
      }
      set {
        let start = newValue.map { positionOffset($0.start) } ?? 0
        let end = newValue.map { positionOffset($0.end) } ?? start
        markedSelection = NSRange(location: start, length: max(0, end - start))
      }
    }

    var markedTextRange: UITextRange? {
      marked.isEmpty ? nil : InputRange(0, markedEnd)
    }

    var beginningOfDocument: UITextPosition { InputPosition(0) }
    var endOfDocument: UITextPosition { InputPosition(markedEnd) }

    var tokenizer: UITextInputTokenizer {
      if let storedTokenizer { return storedTokenizer }
      let made = UITextInputStringTokenizer(textInput: self)
      storedTokenizer = made
      return made
    }

    func text(in range: UITextRange) -> String? {
      let utf16 = marked.utf16
      let start = min(max(0, positionOffset(range.start)), utf16.count)
      let end = min(max(start, positionOffset(range.end)), utf16.count)
      let from = utf16.index(utf16.startIndex, offsetBy: start)
      let to = utf16.index(from, offsetBy: end - start)
      return String(utf16[from..<to])
    }

    func replace(_ range: UITextRange, withText text: String) {
      let current = self.text(in: range) ?? ""
      guard let span = marked.range(of: current) else {
        replaceMarked(text)
        return
      }
      var next = marked
      next.replaceSubrange(span, with: text)
      replaceMarked(next)
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
      beginCompositionChange()
      composition.setMarked(markedText, selected: selectedRange)
      endCompositionChange()
    }

    /// The system Chinese keyboard calls this rather than the string form.
    func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
      setMarkedText(markedText?.string, selectedRange: selectedRange)
    }

    /// Confirming the marked word. The Chinese keyboard commits a letter
    /// this way, with no `insertText` after it; discarding the mark dropped
    /// both the pinyin and the English typed on that keyboard.
    func unmarkText() {
      guard !marked.isEmpty else { return }
      beginCompositionChange()
      let committed = composition.unmark()
      endCompositionChange()
      if let committed { sendCommitted(committed) }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
      InputRange(positionOffset(fromPosition), positionOffset(toPosition))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
      let next = positionOffset(position) + offset
      guard next >= 0, next <= markedEnd else { return nil }
      return InputPosition(next)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int)
      -> UITextPosition?
    {
      let delta = direction == .left || direction == .up ? -offset : offset
      return self.position(from: position, offset: delta)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
      let left = positionOffset(position)
      let right = positionOffset(other)
      if left < right { return .orderedAscending }
      if left > right { return .orderedDescending }
      return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
      positionOffset(toPosition) - positionOffset(from)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
      direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection)
      -> UITextRange?
    {
      let start = positionOffset(position)
      let end = direction == .left || direction == .up ? max(0, start - 1) : min(markedEnd, start + 1)
      return InputRange(start, end)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection)
      -> NSWritingDirection
    { .leftToRight }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect { caretRect(for: range.start) }

    func caretRect(for position: UITextPosition) -> CGRect {
      if cursorRect.isEmpty {
        return CGRect(x: 0, y: max(0, bounds.height - lineHeight), width: 2, height: lineHeight)
      }
      return cursorRect
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
      // An empty list gives the candidate window nowhere to sit, and pinyin
      // then never marks.
      [PhoneCaretRect(caretRect(for: range.start))]
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
      range.end
    }

    func characterRange(at point: CGPoint) -> UITextRange? { markedTextRange }
  }

  private final class PhoneCaretRect: UITextSelectionRect {
    private let caret: CGRect
    init(_ caret: CGRect) {
      self.caret = caret
      super.init()
    }
    override var rect: CGRect { caret }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { true }
    override var containsEnd: Bool { true }
    override var isVertical: Bool { false }
  }

  private final class InputPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) {
      self.offset = max(0, offset)
      super.init()
    }
  }

  private final class InputRange: UITextRange {
    let startOffset: Int
    let endOffset: Int
    init(_ start: Int, _ end: Int) {
      startOffset = min(start, end)
      endOffset = max(start, end)
      super.init()
    }
    override var start: UITextPosition { InputPosition(startOffset) }
    override var end: UITextPosition { InputPosition(endOffset) }
    override var isEmpty: Bool { startOffset == endOffset }
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
    private var keyboardButton: UIButton?
    private var control: UIButton?
    private var option: UIButton?
    private var keys: [UIButton] = []
    private var titles: [ObjectIdentifier: String] = [:]
    private var symbols: [ObjectIdentifier: String] = [:]
    private var widths: [NSLayoutConstraint] = []
    private var stackSpacing: UIStackView?
    /// Scroll to the safe area's left, between the row and the hide key,
    /// and the hide key to the right.
    private var sideInsets: [NSLayoutConstraint] = []
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

    init(onKey: @escaping (Key) -> Void, onModifier: @escaping (Modifier) -> Void) {
      self.onKey = onKey
      self.onModifier = onModifier
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
      ])
      // Pinned at the right, outside the scrolling row: the keyboard control
      // is never scrolled off screen. It toggles the software keyboard.
      let hide = key(symbol: "keyboard", named: "Show keyboard") { [weak self] in
        self?.toggleKeyboard()
      }
      keyboardButton = hide
      hide.translatesAutoresizingMaskIntoConstraints = false
      addSubview(hide)
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
      keys = stack.arrangedSubviews.compactMap { $0 as? UIButton } + [hide]
      widths = keys.map { button in
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: touch)
        width.isActive = true
        return width
      }
      let fill = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
      fill.priority = .defaultHigh
      // As wide as the keys it sits beside while they fill the row.
      let sameWidth = hide.widthAnchor.constraint(equalTo: control.widthAnchor)
      sameWidth.priority = .defaultHigh
      let leading = scroll.leadingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.leadingAnchor, constant: gap)
      let between = hide.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: gap)
      let trailing = hide.trailingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -gap)
      let top = scroll.topAnchor.constraint(equalTo: topAnchor, constant: gap)
      let bottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap)
      sideInsets = [leading, between, trailing]
      verticalInsets = [top, bottom]
      NSLayoutConstraint.activate([
        leading,
        between,
        trailing,
        hide.topAnchor.constraint(equalTo: scroll.topAnchor),
        hide.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        sameWidth,
        top,
        bottom,
        stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
        stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        fill,
      ])
      restyle()
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyboardVisibilityChanged), name: .tetherSoftwareKeyboard, object: nil)
      reflectKeyboard()
      registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: KeyBar, _: UITraitCollection) in
        view.restyle()
        view.invalidateIntrinsicContentSize()
      }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Shows or hides the software keyboard. The capture view is what applies
    /// it; this button only changes the flag and then follows it.
    func toggleKeyboard() { PhoneKeyboard.toggle() }

    @objc private func keyboardVisibilityChanged() { reflectKeyboard() }

    private func reflectKeyboard() {
      guard let keyboardButton else { return }
      let hidden = PhoneKeyboard.staysDown
      symbols[ObjectIdentifier(keyboardButton)] =
        hidden ? "keyboard" : "keyboard.chevron.compact.down"
      keyboardButton.accessibilityLabel = hidden ? "Show keyboard" : "Hide keyboard"
      restyle()
    }

    override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: fittingHeight)
    }

    private func restyle() {
      stackSpacing?.spacing = gap
      for constraint in widths { constraint.constant = touch }
      for (index, constraint) in sideInsets.enumerated() {
        constraint.constant = index == sideInsets.count - 1 ? -gap : gap
      }
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

  extension KeyCaptureView: @MainActor UIEditMenuInteractionDelegate {
    func editMenuInteraction(
      _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      terminalMenu(at: editPoint)
    }

    func editMenuInteraction(
      _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
      CGRect(x: editPoint.x, y: editPoint.y, width: 1, height: max(lineHeight, 1))
    }
  }

  extension KeyCaptureView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard let menu = terminalMenu(at: location) else { return nil }
      consumedPress = true
      let preview = pressed.flatMap { links.menu($0)?.preview }.map { make in
        { () -> UIViewController? in UIHostingController(rootView: make()) }
      }
      return UIContextMenuConfiguration(
        identifier: nil, previewProvider: preview,
        actionProvider: { _ in menu })
    }

    /// Select, copy, and the terminal's own actions. The same menu whichever
    /// press won: the edit menu on ordinary text, the system one on a link.
    private func terminalMenu(at location: CGPoint) -> UIMenu? {
      guard wantsFocus, let cell = geometry.clampedCell(at: location) else { return nil }
      let point = GridPoint(row: Int(cell.row), column: Int(cell.column))
      let link = links.find(cell.row, cell.column)
      let linkMenu = link.flatMap { links.menu($0) }
      pressed = link
      let editing = UIMenu(options: .displayInline, children: [
        UIAction(title: "Select Text", image: UIImage(systemName: "text.cursor")) { [weak self] _ in
          self?.onSelection(.highlight(.word, point, point))
        },
        UIAction(title: "Select Line", image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
          self?.onSelection(.highlight(.line, point, point))
        },
        UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
          guard let self else { return }
          if let selected = self.selection { self.onSelection(.copyExisting(selected)) }
          else { self.onSelection(.copy(.word, point, point)) }
        },
        UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard"),
          attributes: UIPasteboard.general.hasStrings ? [] : [.disabled]) { [weak self] _ in
          self?.paste(nil)
        },
      ])
      let actions = linkMenu?.items.map { item in
        UIAction(title: item.title, image: UIImage(systemName: item.symbol),
          attributes: item.destructive ? .destructive : []) { _ in item.action() }
      } ?? []
      let commands = PhoneMenu.workspaceSections(menuItems).map { section in
        UIMenu(options: .displayInline, children: section.map { self.element(for: $0) })
      }
      let links = actions.isEmpty ? [] : [UIMenu(options: .displayInline, children: actions)]
      return UIMenu(children: [editing] + commands + links)
    }

    private func element(for item: TerminalMenuItem) -> UIMenuElement {
      if !item.children.isEmpty {
        return UIMenu(title: item.title, children: item.children.map { element(for: $0) })
      }
      return UIAction(
        title: item.title, attributes: item.enabled ? [] : .disabled, state: item.checked ? .on : .off
      ) { _ in item.action?() }
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
