import Accessibility
import SwiftUI
import TetherUI

private enum WindowFeedbackStyle {
  static let radius: CGFloat = 16
  static let minWidth: CGFloat = 220
  static let maxWidth: CGFloat = 280
  static let horizontalPadding: CGFloat = 18
  static let verticalPadding: CGFloat = 12
  static let symbolFont: Font = .system(size: 16, weight: .medium)
  static let titleFont: Font = .system(size: 16, weight: .medium)
}

/// A centered, transient status HUD for the host window that owns it. The
/// model owns replacement and expiry; this view only renders the current
/// message and announces it without taking focus. The visible title stays the
/// same in either state — struck through when disabled — while the spoken
/// label carries the explicit state for accessibility.
struct WindowFeedbackView: View {
  let message: WindowFeedback.Message

  var body: some View {
    HStack(spacing: UIStyle.Space.inline) {
      Image(systemName: message.symbol)
        .font(WindowFeedbackStyle.symbolFont)
        .foregroundStyle(Theme.subtle)
        .accessibilityHidden(true)
      Text(message.title)
        .font(WindowFeedbackStyle.titleFont)
        .foregroundStyle(Theme.text)
        .strikethrough(message.isStruckThrough, color: Theme.text)
        .lineLimit(1)
        .layoutPriority(1)
    }
    .padding(.horizontal, WindowFeedbackStyle.horizontalPadding)
    .padding(.vertical, WindowFeedbackStyle.verticalPadding)
    .frame(minWidth: WindowFeedbackStyle.minWidth, maxWidth: WindowFeedbackStyle.maxWidth)
    .fixedSize(horizontal: false, vertical: true)
    .windowFeedbackMaterial()
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(message.accessibilityLabel)
    .onAppear {
      // Polite, transient, and independent of whether VoiceOver happens to
      // land on this non-interactive label.
      AccessibilityNotification.Announcement(message.accessibilityLabel).post()
    }
  }
}

/// The larger HUD uses the same material rules as chrome panels: system glass
/// normally, and an opaque raised surface with a hairline when transparency is
/// reduced or contrast is increased.
private struct WindowFeedbackMaterial: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let solid = reduceTransparency || contrast == .increased
    return content
      .background {
        if solid {
          RoundedRectangle(cornerRadius: WindowFeedbackStyle.radius, style: .continuous)
            .fill(Theme.raised)
        }
      }
      .glassEffect(solid ? .identity : .regular,
                   in: .rect(cornerRadius: WindowFeedbackStyle.radius))
      .overlay {
        if solid {
          RoundedRectangle(cornerRadius: WindowFeedbackStyle.radius, style: .continuous)
            .strokeBorder(contrast == .increased ? Theme.text : Theme.stroke,
                          lineWidth: UIStyle.Mark.hairline)
            .allowsHitTesting(false)
        }
      }
      .shadow(color: .black.opacity(solid ? UIStyle.shadowOpacity : 0),
              radius: UIStyle.shadowRadius, y: UIStyle.shadowOffset)
  }
}

extension View {
  fileprivate func windowFeedbackMaterial() -> some View {
    modifier(WindowFeedbackMaterial())
  }
}
