import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The visual vocabulary, in one place.
///
/// Here rather than in the app because a plugin draws chrome in the same
/// window — a picker in a tab's popover, a row in a sheet — and chrome that
/// came from a second vocabulary would read as a second application.
///
/// Three surfaces, not one: a terminal client is read for hours, and the
/// depth is what keeps a dense host list from reading as a wall. The terminal
/// itself sits *below* the window background rather than above it — the
/// content is the hole in the chrome, not a card on top of it.
public enum Theme {
  // Semantic, not literal. Both platforms already have names for "the
  // surface a window sits on" and "the surface content sits on", and they
  // are the names that follow the person's appearance settings, their
  // increased-contrast setting and their accent colour. Hard-coding hexes
  // here would opt out of all three.
  #if os(macOS)
    public static let window = Color(nsColor: .windowBackgroundColor)
    public static let sidebar = Color(nsColor: .controlBackgroundColor)
    public static let raised = Color(nsColor: .textBackgroundColor)
    public static let stroke = Color(nsColor: .separatorColor)
    public static let terminal = Color(nsColor: .textBackgroundColor)
  #else
    // A phone's grouped background is the one a `List` draws on, which is
    // what the sidebar becomes when the split view collapses.
    public static let window = Color(uiColor: .systemGroupedBackground)
    public static let sidebar = Color(uiColor: .secondarySystemBackground)
    public static let raised = Color(uiColor: .systemBackground)
    public static let stroke = Color(uiColor: .separator)
    public static let terminal = Color(uiColor: .systemBackground)
  #endif

  public static let text = Color.primary
  public static let subtle = Color.secondary
  public static let accent = Color.accentColor
  public static let danger = Color.red
  public static let success = Color.green
  public static let warning = Color.orange
}

/// Shared roles, with platform-specific density. Terminal cell metrics are
/// deliberately independent from these controls and Dynamic Type.
public enum UIStyle {
  public enum Space {
    public static let tight: CGFloat = 2
    public static let small: CGFloat = 4
    public static let inline: CGFloat = 6
    public static let group: CGFloat = 8
    public static let inset: CGFloat = 12
    public static let section: CGFloat = 16
    public static let page: CGFloat = 24
    public static let wide: CGFloat = 28
  }
  public static let rowRadius: CGFloat = 4
  public static let badgeRadius: CGFloat = 5
  public static let panelRadius: CGFloat = 10
  /// Sizes of chrome marks. The number lives here; a view asks for the role.
  public enum Mark {
    public static let hairline: CGFloat = 1
    public static let rule: CGFloat = 2
    public static let presence: CGFloat = 7
    public static let disclosure: CGFloat = 10
    public static let chevron: CGFloat = 12
    public static let glyph: CGFloat = 16
    public static let icon: CGFloat = 18
    public static let iconLarge: CGFloat = 20
    public static let status: CGFloat = 22
    public static let badge: CGFloat = 23
    public static let tileWidth: CGFloat = 30
    public static let tileHeight: CGFloat = 34
    public static let progress: CGFloat = 60
    public static let hero: CGFloat = 64
  }
  public static let sheetWidth: CGFloat = 400
  public static let sheetHeight: CGFloat = 420
  public static let compactWidth: CGFloat = 240
  public static let compactHeight: CGFloat = 200
  public static let menuWidth: CGFloat = 340
  public static let menuHeight: CGFloat = 180
  public static let panelWidth: CGFloat = 420
  public static let pickerWidth: CGFloat = 280
  public static let treeWidth: CGFloat = 260
  public static let listHeight: CGFloat = 280
  public static let selectionOpacity = 0.12
  /// Drawn over glyphs, so it has to read as a selection and still leave
  /// the text visible. A list row's highlight is too faint for that.
  public static let textSelectionOpacity = 0.40
  public static let hoverOpacity = 0.06
  /// Hover in a list someone is choosing from, where the row under the
  /// pointer is the answer being considered and has to read as one.
  public static let focusOpacity = 0.10
  public static let pressedOpacity = 0.18
  public static let disabledOpacity = 0.45
  public static let scrimOpacity = 0.28
  public static let shadowOpacity = 0.16
  public static let shadowRadius: CGFloat = 12
  public static let shadowOffset: CGFloat = 4

  #if os(macOS)
    public static let title: Font = .system(size: 12)
    public static let detail: Font = .system(size: 11)
    public static let header: Font = .system(size: 10, weight: .semibold)
    public static let input: Font = .system(size: 13)
    public static let symbol: Font = .system(size: 11, weight: .medium)
    public static let accessory: Font = .system(size: 10, weight: .semibold)
    public static let rowPadding: CGFloat = 3
    public static let rowHeight: CGFloat = 22
    public static let controlHeight: CGFloat = 22
  #else
    public static let title: Font = .body
    public static let detail: Font = .caption
    public static let header: Font = .caption.weight(.semibold)
    public static let input: Font = .body
    public static let symbol: Font = .body.weight(.medium)
    public static let accessory: Font = .caption.weight(.semibold)
    public static let rowPadding: CGFloat = 8
    public static let rowHeight: CGFloat = 44
    public static let controlHeight: CGFloat = 44
  #endif
}

/// A common state treatment for custom rows and compact chrome. Keep the
/// system focus effect so keyboard focus remains separate from selection.
public struct ChromeButtonStyle: ButtonStyle {
  public var selected: Bool
  /// Hover owned by a container, when the row has controls of its own on
  /// top of the button and the pointer over them is still over the row.
  public var hovered: Bool?
  public var hoverOpacity: Double

  public init(
    selected: Bool = false, hovered: Bool? = nil, hoverOpacity: Double = UIStyle.hoverOpacity
  ) {
    self.selected = selected
    self.hovered = hovered
    self.hoverOpacity = hoverOpacity
  }

  public func makeBody(configuration: Configuration) -> some View {
    ChromeButtonBody(
      configuration: configuration, selected: selected, hovered: hovered,
      hoverOpacity: hoverOpacity)
  }

  private struct ChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let hovered: Bool?
    let hoverOpacity: Double
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
      configuration.label
        .background {
          RoundedRectangle(cornerRadius: UIStyle.rowRadius)
            .fill(Theme.accent.opacity(opacity))
        }
        .overlay {
          if selected && contrast == .increased {
            RoundedRectangle(cornerRadius: UIStyle.rowRadius)
              .strokeBorder(Theme.text, lineWidth: UIStyle.Mark.hairline)
          }
        }
        .opacity(enabled ? 1 : UIStyle.disabledOpacity)
        .onHover { hovering = $0 }
    }

    private var opacity: Double {
      if enabled && configuration.isPressed { return UIStyle.pressedOpacity }
      if selected { return UIStyle.selectionOpacity }
      return enabled && (hovered ?? hovering) ? hoverOpacity : 0
    }
  }
}

private struct FloatingPanel: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content
      .background {
        if reduceTransparency {
          RoundedRectangle(cornerRadius: UIStyle.panelRadius).fill(Theme.raised)
        } else {
          RoundedRectangle(cornerRadius: UIStyle.panelRadius).fill(.regularMaterial)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: UIStyle.panelRadius)
          .strokeBorder(contrast == .increased ? Theme.text : Theme.stroke, lineWidth: UIStyle.Mark.hairline)
          .allowsHitTesting(false)
      }
      .shadow(color: .black.opacity(UIStyle.shadowOpacity),
              radius: UIStyle.shadowRadius, y: UIStyle.shadowOffset)
  }
}

/// Names can wrap at accessibility sizes without forcing desktop chrome
/// or ordinary phone rows to become taller.
private struct AdaptiveRowText: ViewModifier {
  @Environment(\.dynamicTypeSize) private var typeSize

  func body(content: Content) -> some View {
    #if os(macOS)
      content.lineLimit(1)
    #else
      content.lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    #endif
  }
}

extension View {
  public func floatingPanel() -> some View { modifier(FloatingPanel()) }
  public func adaptiveRowText() -> some View { modifier(AdaptiveRowText()) }
}

extension Color {
  public init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

/// An empty place in the window: one symbol, its name on hover.
///
/// A title and a description under a large icon is a second layout. The name
/// stays available to the pointer and to accessibility. `detail` is data —
/// a reason that arrived from elsewhere — and is the only line of text.
public struct QuietMark: View {
  public let title: String
  public let systemImage: String
  public var detail: String?

  public init(_ title: String, systemImage: String, detail: String? = nil) {
    self.title = title
    self.systemImage = systemImage
    self.detail = detail
  }

  private var spoken: String {
    guard let detail, !detail.isEmpty else { return title }
    return "\(title). \(detail)"
  }

  public var body: some View {
    VStack(spacing: UIStyle.Space.group) {
      Image(systemName: systemImage)
        .font(.system(size: UIStyle.Mark.tileWidth, weight: .medium))
        .foregroundStyle(Theme.subtle)
        .accessibilityHidden(true)
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(UIStyle.detail)
          .foregroundStyle(Theme.subtle)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .padding(.horizontal, UIStyle.Space.inset)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .help(title)
  }
}

/// Icon-only chrome. Apply it to the button itself.
///
/// `labelStyle` inherits, so a container-level style is not a convenience:
/// it strips the title from every `Label` under it, and a tab strip becomes
/// a row of identical terminal icons. A button style does not inherit.
///
/// On iOS 26 the navigation bar draws a toolbar item's title beside its
/// symbol. `.labelStyle(.iconOnly)` on the button never reaches the title
/// the bar already took. Replacing the label from inside a `ButtonStyle`
/// does. A button that also needs `ChromeButtonStyle` cannot wear two
/// styles; that one keeps `.labelStyle(.iconOnly)` on its own label, which
/// is enough outside a toolbar.
public struct IconOnlyButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label.labelStyle(.iconOnly)
  }
}

extension ButtonStyle where Self == IconOnlyButtonStyle {
  public static var iconOnly: Self { Self() }
}
