#if os(macOS)
  import AppKit
  import CoreGraphics

  /// Where the quick terminal appears on the display it shows on. Every
  /// mode is the same permanently floating, non-activating panel — this
  /// is placement, not window level.
  enum QuickTerminalPlacement: String, CaseIterable {
    case top, bottom, left, right, floating

    var title: String {
      switch self {
      case .top: "Top"
      case .bottom: "Bottom"
      case .left: "Left"
      case .right: "Right"
      case .floating: "Floating"
      }
    }
  }

  extension QuickTerminalController {
    /// The panel's frame on a display, for a placement. Hung from the
    /// top edge, resting on the bottom one, hugging the sides, or
    /// centered; a remembered size wins over the default, clamped to the
    /// display and never below the minimum. Whole points, as before.
    static func frame(
      in visibleFrame: NSRect, size: NSSize?, minimum: NSSize,
      placement: QuickTerminalPlacement
    ) -> NSRect {
      let wanted: NSSize
      switch placement {
      case .top, .bottom:
        wanted = size ?? NSSize(width: visibleFrame.width, height: visibleFrame.height / 3)
      case .left, .right:
        wanted = size ?? NSSize(width: visibleFrame.width * 0.4, height: visibleFrame.height)
      case .floating:
        wanted = size ?? NSSize(width: visibleFrame.width * 0.6, height: visibleFrame.height * 0.5)
      }
      let width = min(visibleFrame.width, max(minimum.width, wanted.width))
      let height = min(visibleFrame.height, max(minimum.height, wanted.height))
      let origin: NSPoint
      switch placement {
      case .top:
        origin = NSPoint(x: visibleFrame.midX - width / 2, y: visibleFrame.maxY - height)
      case .bottom:
        origin = NSPoint(x: visibleFrame.midX - width / 2, y: visibleFrame.minY)
      case .left:
        origin = NSPoint(x: visibleFrame.minX, y: visibleFrame.midY - height / 2)
      case .right:
        origin = NSPoint(x: visibleFrame.maxX - width, y: visibleFrame.midY - height / 2)
      case .floating:
        origin = NSPoint(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2)
      }
      return NSRect(origin: origin, size: NSSize(width: width, height: height)).integral
    }

    /// What a panel's current frame was computed from: the placement and
    /// the resolved display. A floating panel keeps a dragged position
    /// while the basis is unchanged and the frame still fits the
    /// display; any other case re-hangs it on its mode's geometry.
    struct FrameBasis: Equatable {
      var placement: QuickTerminalPlacement
      /// The resolved display's stable id; nil when the display has no
      /// durable identity (it cannot be pinned, only fallen back to).
      var targetID: String?
    }

    /// Whether a shown panel's frame can simply be kept. Edge placements
    /// always re-hang; floating keeps its position only on an unchanged
    /// basis and a frame that still fits.
    static func shouldKeepFrame(
      current: FrameBasis?, requested: FrameBasis, frame: NSRect, visibleFrame: NSRect
    ) -> Bool {
      guard current == requested else { return false }
      if case .floating = requested.placement { return visibleFrame.contains(frame) }
      return false
    }
  }

  /// A display as the settings can name and find it again: a stable id
  /// and the name a person recognizes. No array index and no transient
  /// `CGDirectDisplayID` — both move when displays change.
  struct QuickDisplay: Equatable {
    let id: String
    let name: String
  }

  enum QuickDisplayCatalog {
    /// The displays attached now, in `NSScreen.screens` order, same-named
    /// displays told apart by a short id suffix. A screen with no durable
    /// identity cannot be pinned, so it is not offered as a choice.
    static func current() -> [QuickDisplay] {
      disambiguate(NSScreen.screens.compactMap { screen in
        guard let id = id(for: screen) else { return nil }
        return QuickDisplay(id: id, name: screen.localizedName)
      })
    }

    /// Stable identity from CoreGraphics. Nil when the UUID is not
    /// available — a frame or array position is not an identity and is
    /// never used as one.
    static func id(for screen: NSScreen) -> String? {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
        let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
      else { return nil }
      return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(withID wanted: String) -> NSScreen? {
      NSScreen.screens.first { id(for: $0) == wanted }
    }

    /// Two displays with the same localized name get a short, stable
    /// suffix so the picker can tell them apart.
    static func disambiguate(_ displays: [QuickDisplay]) -> [QuickDisplay] {
      var counts: [String: Int] = [:]
      for display in displays { counts[display.name, default: 0] += 1 }
      return displays.map { display in
        guard counts[display.name, default: 0] > 1 else { return display }
        let suffix = String(display.id.suffix(6))
        return QuickDisplay(id: display.id, name: "\(display.name) (\(suffix))")
      }
    }
  }

  enum QuickDisplayChoice {
    /// Which display the panel appears on: the fixed choice when that
    /// display is attached, the pointer's display otherwise. Nil means
    /// neither exists — the caller falls back to the main or any
    /// display. A fixed choice that matches nothing is NOT discarded:
    /// the preference stays, and a display with that id appearing later
    /// wins again.
    static func target(fixedID: String?, pointerID: String?, displays: [QuickDisplay]) -> String? {
      if let fixedID, displays.contains(where: { $0.id == fixedID }) { return fixedID }
      if let pointerID, displays.contains(where: { $0.id == pointerID }) { return pointerID }
      return nil
    }
  }
#endif
