import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

@MainActor
public final class TmuxPlugin: TetherPlugin {
  public let metadata = PluginMetadata(
    id: "dev.tether.tmux", name: "tmux", symbol: "rectangle.split.2x2",
    summary: "Persistent sessions. Native windows and panes.")
  public init() {}
  public func launch(in context: PluginContext) {
    context.openWorkspace(TmuxWorkspaceModel(context: context))
  }
  public func settings() -> AnyView {
    AnyView(
      VStack(alignment: .leading, spacing: 8) {
        Text("Closing a workspace detaches it. Your remote tasks keep running.")
        Text("Uses tmux on the remote host’s default socket.").foregroundStyle(.secondary)
      })
  }
}

@MainActor @Observable
final class TmuxWorkspaceModel: PluginWorkspace {
  let id = UUID()
  let context: PluginContext
  let symbol = "rectangle.split.2x2"
  var title: String { session.map { "tmux · \($0.name)" } ?? "tmux" }
  var subtitle: String { context.hostLabel }
  var sessions: [TmuxSessionInfo] = []
  var session: TmuxSessionInfo?
  var snapshot: TmuxSnapshot?
  var error: String?
  var busy = false
  var draftName = ""
  var connection: RemoteConnection
  var pendingDestruction: TmuxAction?
  var sessionToEnd: TmuxSessionInfo?
  var renameWindow: TmuxWindowInfo?
  var renameSession: TmuxSessionInfo?
  var renameText = ""
  private var workspace: TmuxWorkspace?
  private var pump: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var closed = false
  private var lastSize: (UInt16, UInt16)?
  private var sizeTask: Task<Void, Never>?

  init(context: PluginContext) {
    self.context = context
    connection = context.connection
  }
  var ended: Bool { snapshot?.ended != nil }
  var currentWindow: TmuxWindowInfo? {
    snapshot?.windows.first(where: \.active) ?? snapshot?.windows.first
  }
  var activePane: TmuxPaneFrame? {
    snapshot?.panes.first { $0.window == currentWindow?.id && $0.active }
  }
  var commands: [PluginCommand] {
    guard session != nil, !ended else { return [] }
    var result = [
      PluginCommand(id: "newWindow", title: "New window", symbol: "plus.rectangle") { [weak self] in
        self?.perform(.newWindow)
      }
    ]
    if let pane = activePane {
      result += [
        PluginCommand(
          id: "splitHorizontal", title: "Split left and right", symbol: "rectangle.split.2x1"
        ) { [weak self] in self?.perform(.split(id: pane.id, horizontal: true)) },
        PluginCommand(
          id: "splitVertical", title: "Split top and bottom", symbol: "rectangle.split.1x2"
        ) { [weak self] in self?.perform(.split(id: pane.id, horizontal: false)) },
        PluginCommand(id: "zoom", title: "Zoom pane", symbol: "arrow.up.left.and.arrow.down.right")
        { [weak self] in self?.perform(.zoomPane(id: pane.id)) },
      ]
    }
    return result
  }
  func content() -> AnyView { AnyView(TmuxContent(model: self)) }
  func inspector() -> AnyView { AnyView(TmuxInspector(model: self)) }
  func close() {
    closed = true
    operation?.cancel()
    pump?.cancel()
    sizeTask?.cancel()
    workspace?.detach()
    workspace = nil
  }
  func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy, !closed else { return }
    busy = true
    error = nil
    operation = Task { [weak self] in
      do { try await action() } catch is CancellationError {} catch {
        self?.error = error.localizedDescription
      }
      self?.busy = false
    }
  }
  func refresh() { run { [self] in sessions = try await connection.tmuxSessions() } }
  func create() {
    run { [self] in
      let created = try await connection.createTmux(name: draftName)
      try await attach(created)
    }
  }
  func open(_ session: TmuxSessionInfo) { run { [self] in try await attach(session) } }
  private func attach(_ session: TmuxSessionInfo) async throws {
    workspace?.detach()
    pump?.cancel()
    let workspace = try await connection.attachTmux(sessionID: session.id)
    guard !closed, !Task.isCancelled else {
      workspace.detach()
      return
    }
    self.workspace = workspace
    self.session = session
    self.snapshot = workspace.snapshot()
    lastSize = nil
    pump = Task { [weak self] in
      while await workspace.awaitChange() {
        guard !Task.isCancelled, let self else { return }
        self.snapshot = workspace.snapshot()
      }
      if !Task.isCancelled { self?.snapshot = workspace.snapshot() }
    }
  }
  func reconnect() {
    run { [self] in
      connection = try await context.reconnect()
      sessions = try await connection.tmuxSessions()
      if let previous = session, let found = sessions.first(where: { $0.id == previous.id }) {
        try await attach(found)
      } else {
        session = nil
        snapshot = nil
        error = "The previous session no longer exists. Choose a session or create one."
      }
    }
  }
  func perform(_ action: TmuxAction) {
    guard !ended else { return }
    run { [self] in try await workspace?.perform(action) }
  }
  func send(_ pane: UInt32, _ input: TerminalInput) {
    guard !ended else { return }
    do { try workspace?.send(pane: pane, input: input) } catch {
      self.error = error.localizedDescription
    }
  }
  func resize(_ columns: UInt16, _ rows: UInt16) {
    guard !ended, let workspace, lastSize?.0 != columns || lastSize?.1 != rows else { return }
    lastSize = (columns, rows)
    sizeTask?.cancel()
    sizeTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(100))
        try await workspace.perform(.resize(columns: columns, rows: rows))
      } catch is CancellationError {} catch { self?.error = error.localizedDescription }
    }
  }
}

private struct TmuxContent: View {
  @Bindable var model: TmuxWorkspaceModel
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
          }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }.padding(12).background(.orange.opacity(0.12))
      }
      if model.session == nil {
        picker
      } else {
        windowBar
        if let ending = model.snapshot?.ended {
          HStack {
            Label(ending, systemImage: "wifi.slash").font(.callout)
            Spacer()
            Button("Reconnect") { model.reconnect() }.disabled(model.busy)
          }.padding(12).background(.quaternary)
        }
        if let window = model.currentWindow {
          panes(window).allowsHitTesting(!model.ended)
        } else {
          ProgressView("Opening workspace…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .task { if model.session == nil { model.refresh() } }
    .confirmationDialog(
      "End this remote task?",
      isPresented: Binding(
        get: { model.pendingDestruction != nil }, set: { if !$0 { model.pendingDestruction = nil } }
      )
    ) {
      Button("End remote task", role: .destructive) {
        if let action = model.pendingDestruction { model.perform(action) }
        model.pendingDestruction = nil
      }
    } message: {
      Text(
        "Processes in the selected pane or window will stop. Closing the workspace tab instead keeps them running."
      )
    }
    .confirmationDialog(
      "End session and all its tasks?",
      isPresented: Binding(
        get: { model.sessionToEnd != nil }, set: { if !$0 { model.sessionToEnd = nil } })
    ) {
      Button("End session", role: .destructive) {
        guard let session = model.sessionToEnd else { return }
        model.sessionToEnd = nil
        model.run {
          try await model.connection.endTmux(sessionID: session.id)
          model.sessions = try await model.connection.tmuxSessions()
        }
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.renameWindow != nil || model.renameSession != nil },
        set: {
          if !$0 {
            model.renameWindow = nil
            model.renameSession = nil
          }
        })
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Rename").font(.title2.weight(.semibold))
        TextField("Name", text: $model.renameText).textFieldStyle(.roundedBorder)
        HStack {
          Button("Cancel") {
            model.renameWindow = nil
            model.renameSession = nil
          }.keyboardShortcut(.cancelAction)
          Spacer()
          Button("Save") {
            let name = model.renameText
            if let window = model.renameWindow {
              model.perform(.renameWindow(id: window.id, name: name))
            }
            if let session = model.renameSession {
              model.run {
                try await model.connection.renameTmux(sessionID: session.id, name: name)
                model.sessions = try await model.connection.tmuxSessions()
              }
            }
            model.renameWindow = nil
            model.renameSession = nil
          }.keyboardShortcut(.defaultAction).disabled(
            model.renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }.padding(24).frame(width: 340)
    }
  }
  private var picker: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "rectangle.split.2x2").font(.system(size: 36, weight: .light))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 6) {
          Text("Your work, still running.").font(.title.weight(.semibold))
          Text("Choose a tmux session on \(model.context.hostLabel).").foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.help("Refresh sessions").disabled(model.busy)
      }
      if model.busy { ProgressView().controlSize(.small) }
      if model.sessions.isEmpty && !model.busy {
        ContentUnavailableView(
          "No sessions", systemImage: "rectangle.stack",
          description: Text("Create a session to keep your work running after you disconnect."))
      } else {
        List(model.sessions, id: \.id) { session in
          Button {
            model.open(session)
          } label: {
            HStack {
              Image(systemName: "terminal").foregroundStyle(.tint)
              Text(session.name).font(.body.weight(.medium))
              Spacer()
              Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
            }.padding(.vertical, 8).contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(model.busy)
            .contextMenu {
              Button("Rename…") {
                model.renameSession = session
                model.renameText = session.name
              }
              Button("End session…", role: .destructive) { model.sessionToEnd = session }
            }
        }.listStyle(.inset).frame(minHeight: 100)
      }
      HStack {
        TextField("New session name", text: $model.draftName).textFieldStyle(.roundedBorder)
          .onSubmit { if !model.draftName.isEmpty { model.create() } }
        Button("Create session") { model.create() }.buttonStyle(.borderedProminent)
          .disabled(model.busy || model.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      Text("Closing this workspace keeps remote tasks running.").font(.caption).foregroundStyle(
        .secondary)
    }.padding(32).frame(maxWidth: 680).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private var windowBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(model.snapshot?.windows ?? [], id: \.id) { window in
          Button {
            model.perform(.selectWindow(id: window.id))
          } label: {
            Label(window.name, systemImage: "rectangle.split.2x2")
              .padding(.horizontal, 10).padding(.vertical, 7)
              .background(
                window.active ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(.plain)
            .contextMenu {
              Button("Rename…") {
                model.renameWindow = window
                model.renameText = window.name
              }
              Button("End window…", role: .destructive) {
                model.pendingDestruction = .closeWindow(id: window.id)
              }
            }
        }
      }.padding(8)
    }.scrollIndicators(.hidden).frame(height: 48).disabled(model.ended || model.busy).background(.bar)
  }
  private func panes(_ window: TmuxWindowInfo) -> some View {
    let metrics = FontMetrics(size: min(24, max(10, fontSize)))
    return GeometryReader { geometry in
      let sx = geometry.size.width / CGFloat(max(1, window.width))
      let sy = geometry.size.height / CGFloat(max(1, window.height))
      ZStack(alignment: .topLeading) {
        ForEach(
          model.snapshot?.panes.filter { $0.window == window.id && $0.visible } ?? [], id: \.id
        ) { pane in
          TerminalSurface(
            frame: pane.frame, active: pane.active, inset: 0,
            onInput: { model.send(pane.id, $0) },
            onFocus: { if !pane.active { model.perform(.selectPane(id: pane.id)) } }
          )
          .overlay(alignment: .topTrailing) {
            if pane.active {
              RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 18, height: 3)
                .padding(4).allowsHitTesting(false)
            }
          }
          .frame(width: CGFloat(pane.width) * sx, height: CGFloat(pane.height) * sy)
          .position(
            x: (CGFloat(pane.x) + CGFloat(pane.width) / 2) * sx,
            y: (CGFloat(pane.y) + CGFloat(pane.height) / 2) * sy)
          if Int(pane.x) + Int(pane.width) < Int(window.width) {
            Rectangle().fill(.secondary.opacity(0.25)).frame(
              width: 5, height: CGFloat(pane.height) * sy
            )
            .contentShape(Rectangle())
            .position(
              x: CGFloat(pane.x + pane.width) * sx,
              y: (CGFloat(pane.y) + CGFloat(pane.height) / 2) * sy
            )
            .gesture(
              DragGesture().onEnded { value in
                model.perform(
                  .resizePane(
                    id: pane.id,
                    columns: UInt16(
                      max(1, min(1000, Int(pane.width) + Int(value.translation.width / sx)))),
                    rows: pane.height))
              })
          }
          if Int(pane.y) + Int(pane.height) < Int(window.height) {
            Rectangle().fill(.secondary.opacity(0.25)).frame(
              width: CGFloat(pane.width) * sx, height: 5
            )
            .contentShape(Rectangle())
            .position(
              x: (CGFloat(pane.x) + CGFloat(pane.width) / 2) * sx,
              y: CGFloat(pane.y + pane.height) * sy
            )
            .gesture(
              DragGesture().onEnded { value in
                model.perform(
                  .resizePane(
                    id: pane.id, columns: pane.width,
                    rows: UInt16(
                      max(1, min(500, Int(pane.height) + Int(value.translation.height / sy))))))
              })
          }
        }
      }
      .onAppear { resize(geometry.size, metrics) }
      .onChange(of: geometry.size) { _, size in resize(size, metrics) }
      .onChange(of: fontSize) { _, _ in resize(geometry.size, metrics) }
    }
  }
  private func resize(_ size: CGSize, _ metrics: FontMetrics) {
    model.resize(
      UInt16(max(1, min(1000, size.width / metrics.cellWidth))),
      UInt16(max(1, min(500, size.height / metrics.lineHeight))))
  }
}
private struct TmuxInspector: View {
  @Bindable var model: TmuxWorkspaceModel
  var body: some View {
    Form {
      Section("Workspace") {
        LabeledContent("Host", value: model.subtitle)
        LabeledContent("Session", value: model.session?.name ?? "Not attached")
        LabeledContent(
          "Status",
          value: model.ended
            ? "Disconnected" : (model.session == nil ? "Choose a session" : "Connected"))
      }
      if let pane = model.activePane {
        Section("Active pane") {
          LabeledContent("Size", value: "\(pane.width) × \(pane.height)")
          ForEach(model.commands) { command in
            Button(command.title, systemImage: command.symbol, action: command.action)
          }
          Button("End pane…", role: .destructive) {
            model.pendingDestruction = .closePane(id: pane.id)
          }
        }.disabled(model.ended || model.busy)
      }
      Section {
        Text("Close the workspace tab to detach. Remote tasks will continue running.").font(
          .callout
        ).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }
}
