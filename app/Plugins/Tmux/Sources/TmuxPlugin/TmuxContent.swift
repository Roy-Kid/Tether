import SwiftUI
import Tether
import TetherUI

/// Plugin-local visual roles: this package never imports the app's theme.
private enum TmuxStyle {
  static let inset: CGFloat = 12
  static let markerRadius: CGFloat = 2
  static let markerWidth: CGFloat = 18
  static let markerHeight: CGFloat = 3
  static let markerInset: CGFloat = 4
  static let dividerWidth: CGFloat = 5
  static let warning = Color.orange
  #if os(macOS)
    static let controlSize: CGFloat = 22
  #else
    static let controlSize: CGFloat = 44
  #endif
}

struct TmuxContent: View {
  @Bindable var model: TmuxTab
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  var body: some View {
    VStack(spacing: 0) {
      if let error = model.error {
        HStack(alignment: .top) {
          Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(
            .enabled)
          Spacer()
          Button {
            model.error = nil
          } label: {
            Image(systemName: "xmark")
              .font(.caption.weight(.semibold))
              .frame(width: TmuxStyle.controlSize, height: TmuxStyle.controlSize)
              .contentShape(Rectangle())
          }.buttonStyle(.borderless).accessibilityLabel("Dismiss error")
            .help("Dismiss error")
        }
        .padding(TmuxStyle.inset)
        .background(.background)
        .overlay(alignment: .leading) {
          Rectangle().fill(TmuxStyle.warning).frame(width: TmuxStyle.markerHeight)
        }
      }
      if model.session == nil {
        ContentUnavailableView("Original shell", systemImage: "terminal")
      } else {
        if let ending = model.snapshot?.ended {
          HStack {
            Label(ending, systemImage: "wifi.slash").font(.callout)
            Spacer()
            Button("Reconnect") { model.reconnect() }.disabled(model.busy)
          }.padding(TmuxStyle.inset).background(.background)
            .overlay(alignment: .bottom) { Divider() }
        }
        if let window = model.currentWindow {
          panes(window).allowsHitTesting(!model.ended)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .dialog(for: model.pendingDestruction) { action in
      Dialog.confirm(
        endTitle(action), verb: "End", role: .destructive, cancel: { model.pendingDestruction = nil }
      ) {
        model.pendingDestruction = nil
        model.perform(action)
      }
    }
  }

  /// A pane's history is scrolled by lines. The ends are as many lines as
  /// there could be: the engine stops at either one.
  static func lines(for scroll: ScrollTo, page: Int32) -> Int32 {
    switch scroll {
    case .lines(let count): count
    case .pageUp: max(page - 1, 1)
    case .pageDown: -max(page - 1, 1)
    case .oldest: Int32(Int16.max)
    case .live: -Int32(Int16.max)
    }
  }

  private func endTitle(_ action: TmuxAction) -> String {
    switch action {
    case .closeWindow(id: _): "End this window?"
    case .closePane(id: _): "End this pane?"
    default: "End this?"
    }
  }

  private func panes(_ window: TmuxWindowInfo) -> some View {
    let asked = min(24, max(10, fontSize))
    let full = FontMetrics(size: asked)
    return GeometryReader { geometry in
      // Two sizes, and the difference matters. `full` is the type the person
      // asked for, and it decides what to ask tmux for. `metrics` is what
      // the window costs to draw *now* — another client can hold the window
      // wider than this screen, and shrinking the type shows the whole grid
      // instead of its top-left corner.
      let metrics = fitting(window, in: geometry.size, asked: asked, at: full)
      // Same cells the surface draws. Stretching to the view (pixels / tmux
      // cells) and then drawing at cellWidth is how a slightly-too-wide
      // window painted past the clip.
      let cell = metrics.cellWidth
      let line = metrics.lineHeight
      ZStack(alignment: .topLeading) {
        ForEach(
          model.snapshot?.panes.filter { $0.window == window.id && $0.visible } ?? [], id: \.id
        ) { pane in
          TerminalSurface(
            frame: pane.frame, active: pane.active, inset: 0,
            onInput: { model.send(pane.id, $0) },
            onFocus: { if !pane.active { model.perform(.selectPane(id: pane.id)) } },
            onScroll: { model.scroll(pane.id, lines: Self.lines(for: $0, page: Int32(pane.height))) },
            links: model.links(for: pane.id)
          )
          .overlay(alignment: .topTrailing) {
            if pane.active {
              RoundedRectangle(cornerRadius: TmuxStyle.markerRadius).fill(Color.accentColor)
                .frame(width: TmuxStyle.markerWidth, height: TmuxStyle.markerHeight)
                .padding(TmuxStyle.markerInset).allowsHitTesting(false).accessibilityHidden(true)
            }
          }
          .frame(width: CGFloat(pane.width) * cell, height: CGFloat(pane.height) * line)
          .clipped()
          .position(
            x: (CGFloat(pane.x) + CGFloat(pane.width) / 2) * cell,
            y: (CGFloat(pane.y) + CGFloat(pane.height) / 2) * line)
          if Int(pane.x) + Int(pane.width) < Int(window.width) {
            Rectangle().fill(.separator).frame(
              width: TmuxStyle.dividerWidth, height: CGFloat(pane.height) * line
            )
            .contentShape(Rectangle())
            .position(
              x: CGFloat(pane.x + pane.width) * cell,
              y: (CGFloat(pane.y) + CGFloat(pane.height) / 2) * line
            )
            .gesture(
              DragGesture().onEnded { value in
                model.perform(
                  .resizePane(
                    id: pane.id,
                    columns: UInt16(
                      max(1, min(1000, Int(pane.width) + Int(value.translation.width / cell)))),
                    rows: pane.height))
              })
          }
          if Int(pane.y) + Int(pane.height) < Int(window.height) {
            Rectangle().fill(.separator).frame(
              width: CGFloat(pane.width) * cell, height: TmuxStyle.dividerWidth
            )
            .contentShape(Rectangle())
            .position(
              x: (CGFloat(pane.x) + CGFloat(pane.width) / 2) * cell,
              y: CGFloat(pane.y + pane.height) * line
            )
            .gesture(
              DragGesture().onEnded { value in
                model.perform(
                  .resizePane(
                    id: pane.id, columns: pane.width,
                    rows: UInt16(
                      max(1, min(500, Int(pane.height) + Int(value.translation.height / line))))))
              })
          }
        }
      }
      .clipped()
      .onAppear { resize(geometry.size, full) }
      .onChange(of: geometry.size) { _, size in resize(size, full) }
      .onChange(of: fontSize) { _, _ in resize(geometry.size, full) }
    }
  }

  /// The type size that puts the whole window inside the view.
  ///
  /// Never larger than what was asked for: this shrinks to fit and does
  /// nothing otherwise. Measured rather than scaled arithmetically, because
  /// a cell is a rounded advance and a size two thirds of another does not
  /// give two thirds of the cell.
  private func fitting(
    _ window: TmuxWindowInfo, in size: CGSize, asked: CGFloat, at full: FontMetrics
  ) -> FontMetrics {
    guard window.width > 0, window.height > 0, size.width > 0, size.height > 0 else { return full }
    func fits(_ metrics: FontMetrics) -> Bool {
      CGFloat(window.width) * metrics.cellWidth <= size.width
        && CGFloat(window.height) * metrics.lineHeight <= size.height
    }
    if fits(full) { return full }

    let scale = min(
      size.width / (CGFloat(window.width) * full.cellWidth),
      size.height / (CGFloat(window.height) * full.lineHeight))
    var candidate = max(5, (asked * scale).rounded(.down))
    // Three tries, not a search: the estimate is off by a rounded cell at
    // most, and a layout pass is not the place for a loop that could run.
    for _ in 0..<3 {
      let metrics = FontMetrics(size: candidate)
      if fits(metrics) || candidate <= 5 { return metrics }
      candidate -= 1
    }
    return FontMetrics(size: max(5, candidate))
  }

  private func resize(_ size: CGSize, _ metrics: FontMetrics) {
    model.resize(metrics.columns(fitting: size.width), metrics.rows(fitting: size.height))
  }
}
struct TmuxInspector: View {
  @Bindable var model: TmuxTab
  var body: some View {
    Form {
      Section("Workspace") {
        LabeledContent("Host", value: model.tab.plugin.hostLabel)
        LabeledContent("Session", value: model.session?.name ?? "Not attached")
        LabeledContent(
          "Status",
          value: model.ended
            ? "Disconnected" : (model.session == nil ? "Not attached" : "Connected"))
      }
      if let pane = model.activePane {
        Section("Active pane") {
          LabeledContent("Size", value: "\(pane.width) × \(pane.height)")
          ForEach(model.paneCommands) { command in
            Button(command.title, systemImage: command.symbol, action: command.action)
          }
          Button("End pane…", role: .destructive) {
            model.pendingDestruction = .closePane(id: pane.id)
          }
        }.disabled(model.ended || model.busy)
      }
    }.formStyle(.grouped)
  }
}
