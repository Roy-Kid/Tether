import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The number follows the current list of enabled destinations, after filtering.
public struct PickerShortcutHint: View {
  let index: Int?

  public init(index: Int?) { self.index = index }

  public var body: some View {
    #if os(macOS)
      if let index, (0..<9).contains(index) {
        Text("⌘\(index + 1)")
          .font(UIStyle.detail)
          .monospacedDigit()
          .foregroundStyle(Theme.subtle)
          .fixedSize()
          .accessibilityLabel("Command \(index + 1)")
      }
    #endif
  }
}

public extension View {
  /// Cmd+1…9 immediately activates an enabled destination in this popup.
  func onPickerQuickSelection(count: Int, _ select: @escaping (Int) -> Void) -> some View {
    #if os(macOS)
      background {
        PickerShortcutMonitor(count: count, select: select)
          .allowsHitTesting(false)
      }
    #else
      self
    #endif
  }
}

#if os(macOS)
@MainActor
public enum PickerShortcuts {
  /// Call before workspace bindings so a visible popup owns its numbered keys,
  /// regardless of the order AppKit invokes local event monitors.
  public static func handle(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown,
      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
      let key = event.charactersIgnoringModifiers, key.count == 1,
      let number = Int(key), (1...9).contains(number),
      let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
      NSApp.modalWindow == nil,
      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
      let content = window.contentView, let picker = monitor(in: content)
    else { return false }
    // An absent number and key repeats belong to the popup too; neither may
    // fall through to a workspace command or the terminal behind it.
    if !event.isARepeat, number <= picker.count { picker.select?(number - 1) }
    return true
  }

  private static func monitor(in view: NSView) -> PickerShortcutMonitor.MonitorView? {
    guard !view.isHiddenOrHasHiddenAncestor else { return nil }
    if let view = view as? PickerShortcutMonitor.MonitorView { return view }
    return view.subviews.reversed().lazy.compactMap { monitor(in: $0) }.first
  }
}

private struct PickerShortcutMonitor: NSViewRepresentable {
  let count: Int
  let select: (Int) -> Void

  func makeNSView(context: Context) -> MonitorView { MonitorView() }
  func updateNSView(_ view: MonitorView, context: Context) {
    view.count = count
    view.select = select
  }
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

  final class MonitorView: NSView {
    var count = 0
    var select: ((Int) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        PickerShortcuts.handle(event) ? nil : event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
#endif
