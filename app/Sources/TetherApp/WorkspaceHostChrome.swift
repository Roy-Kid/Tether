#if os(macOS)
  import AppKit
  import SwiftUI
  import TetherPluginKit
  import TetherUI

  /// Registers the window a host view lives in. Nothing more: the
  /// native bridge is the one source of a host's state — key along the
  /// whole sheet/parent chain, occlusion, miniaturize, close — and a
  /// view neither owns that state nor outlives the window. A rebuilt
  /// view re-registering the same id must not disturb what the bridge
  /// reported; the bridge removes the host when the window truly closes.
  struct WorkspaceHostReporter: NSViewRepresentable {
    let hostID: UUID
    let kind: WorkspaceHostKind
    let interaction: WorkspaceInteraction

    func makeNSView(context: Context) -> Probe {
      let view = Probe()
      view.register = register
      return view
    }

    func updateNSView(_ view: Probe, context: Context) {
      view.register = register
      view.register?(view.window)
    }

    private func register(_ window: NSWindow?) {
      guard let window else { return }
      interaction.register(id: hostID, kind: kind, window: window)
    }

    final class Probe: NSView {
      var register: ((NSWindow?) -> Void)?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        register?(window)
      }
    }
  }

  /// The shared presentations either host can be asked for, drawn by exactly
  /// one. The interaction's presentation owner — the host a blocking
  /// question fixed until it is answered — presents what blocks; without
  /// one, the effective host presents. The other host draws nothing, so
  /// two hosts never present the same thing.
  ///
  /// Window feedback is outside that sharing: a message belongs to one host
  /// id, and this modifier draws only the message addressed to `hostID`.
  ///
  /// Questions are not here: ordinary dialogs are submitted once by the
  /// controller and held to their answer (`WorkspaceInteraction`'s
  /// stable observation and lease), never consumed per host — a
  /// condition-driven `.dialog` in two hosts would answer a question
  /// twice, or cancel it when the presenting host changed.
  struct WorkspaceHostPresenters: ViewModifier {
    @Bindable var tabs: TabSet
    let interaction: WorkspaceInteraction
    let hostID: UUID
    let store: HostStore
    let registry: PluginRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether this host is the one presenting: a blocking question's
    /// fixed owner first, then the effective host. Never both, never
    /// neither while a host is up.
    private var presents: Bool {
      (interaction.presentationOwner ?? interaction.effectiveHost) == hostID
    }

    /// State feedback is addressed to one host and stays there; it is not a
    /// shared presentation that arbitration can hand to the other window.
    private var feedbackID: UUID? {
      interaction.windowFeedback.message(for: hostID)?.id
    }

    func body(content: Content) -> some View {
      let feedbackID = feedbackID
      return content
        .overlay {
          if presents {
            PaletteOverlay(
              tabs: tabs, store: store,
              commands: interaction.commandItems(from: hostID),
              onPickHost: { interaction.open($0) })
          }
        }
        .overlay {
          if presents && tabs.hostPicker && !tabs.zen {
            Color.black.opacity(0.001)
              .onTapGesture { tabs.hostPicker = false }
              .overlay(alignment: .bottomLeading) {
                HostPicker(tabs: tabs, store: store)
                  .padding(.leading, UIStyle.panelRadius)
                  .padding(.bottom, Chrome.status + UIStyle.Space.group)
              }
          }
        }
        .overlay(alignment: .center) {
          Group {
            if let message = interaction.windowFeedback.message(for: hostID) {
              WindowFeedbackView(message: message)
                .id(message.id)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
          }
          .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: feedbackID)
        }
    }
  }
#endif
