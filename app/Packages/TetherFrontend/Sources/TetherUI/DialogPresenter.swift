import SwiftUI

/// Where a platform draws a dialog.
///
/// `answer` is called at most once, with the chosen action and one value per
/// field. `gone` is called exactly once, when the dialog has left the screen
/// — after an answer, after `withdraw`, or because the platform took it away
/// — and not a frame before: the next dialog is shown only then.
@MainActor
protocol DialogSurface: AnyObject {
  /// Shows `dialog` in the anchor's window, or the frontmost without one.
  /// False when there is nowhere to show it.
  func show(
    _ dialog: Dialog, in anchor: DialogAnchor?,
    answer: @escaping (Int, [String]) -> Void, gone: @escaping () -> Void) -> Bool
  /// Takes the dialog on screen away without an answer.
  func withdraw()
}

/// Every dialog, one at a time.
///
/// Two questions can arrive in the same breath — a host to trust, then the
/// code its login asks for — and showing the second over the first, or while
/// the first is still animating away, is how a Continue became a Cancel. So
/// nothing is shown until the one before it is gone.
@MainActor
final class DialogQueue {
  private struct Entry {
    let id: UUID
    let dialog: Dialog
    let anchor: DialogAnchor?
    let shown: (@MainActor () -> Void)?
    let finish: (DialogReply?) -> Void
  }

  private let surface: DialogSurface
  private var waiting: [Entry] = []
  private var showing: Entry?
  /// From `show` until `gone`: the surface is occupied even after an answer.
  private var occupied = false

  init(surface: DialogSurface) {
    self.surface = surface
  }

  /// The person's reply, or `nil` when the question was withdrawn — the
  /// asking task was cancelled — or it left the screen unanswered, or there
  /// was nowhere to put it. `shown` runs when it reaches the screen, which
  /// can be long after it was asked: another question may be ahead of it.
  @discardableResult
  func ask(
    _ dialog: Dialog, in anchor: DialogAnchor? = nil, shown: (@MainActor () -> Void)? = nil
  ) async -> DialogReply? {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        waiting.append(
          Entry(id: id, dialog: dialog, anchor: anchor, shown: shown) { continuation.resume(returning: $0) })
        showNext()
      }
    } onCancel: {
      Task { @MainActor in self.withdraw(id) }
    }
  }

  private func withdraw(_ id: UUID) {
    if let index = waiting.firstIndex(where: { $0.id == id }) {
      waiting.remove(at: index).finish(nil)
    } else if let entry = showing, entry.id == id {
      showing = nil
      entry.finish(nil)
      surface.withdraw()
    }
  }

  private func showNext() {
    guard !occupied, !waiting.isEmpty else { return }
    let entry = waiting.removeFirst()
    showing = entry
    occupied = true
    let shown = surface.show(
      entry.dialog, in: entry.anchor,
      answer: { [weak self] action, values in self?.answer(entry.id, action: action, values: values) },
      gone: { [weak self] in self?.gone() })
    guard !shown else {
      entry.shown?()
      return
    }
    showing = nil
    occupied = false
    entry.finish(nil)
    showNext()
  }

  private func answer(_ id: UUID, action: Int, values: [String]) {
    guard let entry = showing, entry.id == id, entry.dialog.actions.indices.contains(action) else { return }
    showing = nil
    let chosen = entry.dialog.actions[action]
    // Exactly one value per field, whatever the platform handed back.
    let fields = entry.dialog.fields.indices.map { values.indices.contains($0) ? values[$0] : "" }
    chosen.perform(fields)
    entry.finish(DialogReply(action: action, role: chosen.role, values: fields))
  }

  /// Gone without an answer is still an ending: whoever asked hears nil,
  /// rather than waiting on a dialog that is no longer anywhere.
  private func gone() {
    if let unanswered = showing {
      showing = nil
      unanswered.finish(nil)
    }
    occupied = false
    showNext()
  }
}

/// The one way a dialog reaches the screen.
///
/// Above everything else the app is showing — a sheet, a popover, another
/// window's worth of navigation — and in a place the app's own presentations
/// cannot take away: a phone's dialogs get a window of their own, a Mac's are
/// a sheet on whatever is frontmost. A view asks with `.dialog(for:)`; code
/// that must wait for an answer asks with ``ask(_:)``.
@MainActor
public enum DialogPresenter {
  static let queue = DialogQueue(surface: PlatformDialogSurface())

  /// Shows `dialog` and waits for the person. The chosen action's `perform`
  /// has already run when this returns. Cancelling the calling task takes
  /// the dialog away and returns `nil`. `shown` runs once it is on screen —
  /// the moment to start timing an answer, not the moment it was asked.
  @discardableResult
  public static func ask(_ dialog: Dialog, shown: (@MainActor () -> Void)? = nil) async -> DialogReply? {
    await queue.ask(dialog, shown: shown)
  }
}

extension View {
  /// Shows a dialog for as long as `key` is not `nil`.
  ///
  /// The dialog's actions are what clear `key`: they are the answer. A key
  /// that changes shows the dialog for the new one; a key cleared by
  /// something else takes the dialog away, unanswered. A view that goes away
  /// answers its question with Cancel, as a sheet's own alert would.
  public func dialog<Key: Hashable>(for key: Key?, _ make: @escaping (Key) -> Dialog) -> some View {
    modifier(DialogModifier(key: key, make: make))
  }
}

private struct DialogModifier<Key: Hashable>: ViewModifier {
  let key: Key?
  let make: (Key) -> Dialog
  /// The key on screen, or answered and still held by the state.
  @State private var shown: Key?
  @State private var asking: (dialog: Dialog, task: Task<Void, Never>)?
  @State private var anchor = DialogAnchor()

  func body(content: Content) -> some View {
    content
      .background(DialogAnchorReader(anchor: anchor))
      .onAppear { present(key) }
      .onChange(of: key) { _, key in present(key) }
      .onDisappear(perform: dismissed)
  }

  private func present(_ key: Key?) {
    guard key != shown else { return }
    asking?.task.cancel()
    asking = nil
    shown = key
    guard let key else { return }
    let dialog = make(key)
    let anchor = anchor
    let task = Task {
      let reply = await DialogPresenter.queue.ask(dialog, in: anchor)
      // Gone without an answer, and not because of this view: it counts as
      // Cancel, so the state that asked is not left asking.
      if reply == nil, !Task.isCancelled { Self.cancel(dialog) }
      // Answered, or withdrawn: either way nothing is left to cancel.
      if asking?.dialog.id == dialog.id { asking = nil }
    }
    asking = (dialog, task)
  }

  private func dismissed() {
    guard let asking else { return }
    asking.task.cancel()
    self.asking = nil
    shown = nil
    Self.cancel(asking.dialog)
  }

  private static func cancel(_ dialog: Dialog) {
    guard let cancel = dialog.cancelAction else { return }
    dialog.actions[cancel].perform(dialog.fields.map(\.initial))
  }
}
