import Foundation
import TetherFFIBindings

// MARK: - Screen data

// The frame types are surfaced by alias rather than copied into Swift
// structs of our own.
//
// Everywhere else in this façade a generated type is wrapped, so that a
// consumer's signatures never name one. These are the exception, and the
// reason is measurable rather than aesthetic: a frame is the hot path. It
// crosses on every repaint, and re-boxing forty rows of runs into parallel
// Swift structs would allocate the whole screen again each time, to arrive at
// types with identical fields.
//
// What the rule protects is that a consumer never writes `TetherFFIBindings`
// and never depends on the generator's *naming*. An alias keeps both: these
// are `Tether.ScreenFrame` and so on, and if the boundary shape ever diverges
// from what the generator emits, they become wrappers here without touching a
// line of consumer code.

public typealias ScreenFrame = TetherFFIBindings.ScreenFrame
public typealias MouseTracking = TetherFFIBindings.MouseTracking
public typealias ScreenRow = TetherFFIBindings.ScreenRow
public typealias FrameUpdate = TetherFFIBindings.FrameUpdate
public typealias UpdatedRow = TetherFFIBindings.UpdatedRow
public typealias StyledRun = TetherFFIBindings.StyledRun
public typealias CellStyle = TetherFFIBindings.CellStyle
public typealias CellColor = TetherFFIBindings.CellColor
public typealias ColorName = TetherFFIBindings.ColorName
public typealias UnderlineStyle = TetherFFIBindings.UnderlineStyle
public typealias CaretShape = TetherFFIBindings.CaretShape
public typealias TerminalLink = TetherFFIBindings.TerminalLink
public typealias LinkKind = TetherFFIBindings.LinkKind
public typealias LinkSpan = TetherFFIBindings.LinkSpan

// MARK: - Input

/// A key, named by what it is rather than by a scancode.
public enum Key: Sendable, Equatable {
  /// Text the platform's keyboard layer already composed. Input methods,
  /// dead keys and combining marks are resolved before this point.
  case text(String)
  case enter, tab, backspace, escape, delete, insert
  case up, down, left, right
  case home, end, pageUp, pageDown
  case function(UInt8)
}

/// Which modifiers were held.
///
/// No `command`: terminals do not send it. On Apple keyboards, Option is
/// `alt`, and a frontend maps its platform's names onto these.
public struct KeyModifiers: Sendable, Equatable {
  public var shift: Bool
  public var alt: Bool
  public var control: Bool

  public init(shift: Bool = false, alt: Bool = false, control: Bool = false) {
    self.shift = shift
    self.alt = alt
    self.control = control
  }

  public static let none = KeyModifiers()
}

/// A mouse button. `none` is a move with nothing held down.
public enum PointerButton: Sendable, Equatable {
  case left, middle, right, none, wheelUp, wheelDown
}

/// Press, release, or a move.
public enum PointerPhase: Sendable, Equatable {
  case press, release, move
}

/// Something the person did.
public enum TerminalInput: Sendable, Equatable {
  case key(Key, KeyModifiers = .none)
  /// Text arriving all at once. Bracketing — and the stripping that stops a
  /// paste from ending its own bracket — happens in the engine, where the
  /// mode that decides it lives.
  case paste(String)
  /// A pointer event in cells of the visible grid, from the top left.
  ///
  /// The engine writes it in the protocol the far side asked for, and writes
  /// nothing when that program has not asked. Column and row are zero-based.
  case pointer(
    button: PointerButton, phase: PointerPhase, column: UInt16, row: UInt16,
    modifiers: KeyModifiers = .none)
}

// MARK: - Colours

/// One colour, as the far side will be told it.
public struct TerminalColor: Sendable, Equatable {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }
}

/// What an application draws with, for the questions the far side asks.
///
/// Not the screen — see [`TerminalSession.setPalette(_:)`]. The sixteen ANSI
/// colours are a fixed-size list because that is what they are; a palette of
/// some other length is refused rather than padded with colours nobody chose.
public struct TerminalPalette: Sendable, Equatable {
  public var foreground: TerminalColor
  public var background: TerminalColor
  public var cursor: TerminalColor
  /// Eight normal, then eight bright.
  public var ansi: [TerminalColor]

  public init(
    foreground: TerminalColor,
    background: TerminalColor,
    cursor: TerminalColor,
    ansi: [TerminalColor]
  ) {
    self.foreground = foreground
    self.background = background
    self.cursor = cursor
    self.ansi = ansi
  }
}

/// Where to put the viewport over the scrollback.
///
/// Named by intent rather than by line arithmetic: how much a page is depends
/// on the screen, and a frontend that worked it out could disagree with the
/// engine that applies it.
public enum ScrollTo: Sendable, Equatable {
  /// Positive goes back into history, negative comes forward.
  case lines(Int32)
  case pageUp
  case pageDown
  case oldest
  /// Back to the live screen, where new output appears.
  case live
}

// MARK: - Trust

/// A host key, as an application is asked to judge it.
public struct HostIdentity: Sendable, Equatable {
  public let host: String
  public let port: UInt16
  public let algorithm: String
  /// The `SHA256:…` form a person compares against what their
  /// administrator published.
  public let fingerprint: String

  /// Public because a consumer has to be able to make one.
  ///
  /// `HostTrust` is where an application decides whether to talk to a
  /// machine, and that decision is exactly the kind a person writes tests
  /// for — "a key that changed must be refused" is not something to find out
  /// in production. A memberwise initialiser is internal by default, which
  /// would leave every consumer unable to exercise its own trust policy.
  public init(host: String, port: UInt16, algorithm: String, fingerprint: String) {
    self.host = host
    self.port = port
    self.algorithm = algorithm
    self.fingerprint = fingerprint
  }
}

/// Decides whether a host may be talked to.
///
/// Asked during the handshake, before any credential exists on the wire —
/// which is the point of asking. There is no trust-everything default to
/// reach for; an application must say what trust means to it.
public protocol HostTrust: Sendable {
  func trusts(_ host: HostIdentity) async -> Bool
}

/// A private key that needs its passphrase, as a person is shown it.
public struct LockedKey: Sendable, Equatable {
  /// The `SHA256:…` form `ssh-keygen -l` prints. `nil` for the formats that
  /// keep even the public half behind the passphrase.
  public let fingerprint: String?
  /// The key's own comment, often `user@host`. Empty when the format
  /// encrypts it along with the key.
  public let comment: String

  public init(fingerprint: String?, comment: String) {
    self.fingerprint = fingerprint
    self.comment = comment
  }
}

/// Supplies a private key's passphrase, when and only when a login needs it.
///
/// Asked from the middle of a handshake. Where the key's format allows, the
/// server has already said it would take this key — a person is never asked
/// to unlock a key that was not going to be used.
public protocol KeyUnlocker: Sendable {
  /// `attempt` counts from 1; a second call means the first passphrase was
  /// wrong. `nil` is the person's no, which ends the login as a decline.
  func passphrase(for key: LockedKey, attempt: Int) async -> String?
}

/// Something to authenticate with. Offered in the order given, which is how
/// "a key, then a one-time code" is expressed: two credentials, one login.
public enum Credential: Sendable {
  case password(String)
  /// PEM text, so a key in a keychain item never has to reach the disk.
  ///
  /// A key protected by a passphrase is unlocked with `passphrase` if one is
  /// given, and otherwise by asking `unlock`. With neither it is left out,
  /// and named in the error if the login then fails — as is a key that
  /// cannot be read at all, which no longer costs the credentials after it.
  case privateKey(pem: String, passphrase: String? = nil, unlock: (any KeyUnlocker)? = nil)
  case interactive(any AuthPrompter)
}

/// Lines of history a new session keeps when the caller does not say.
///
/// Ten thousand lines is cheap on a Mac. On a phone, a handful of tabs at
/// that size is enough to be jetsam-killed. Two thousand is the cap a tmux
/// pane already uses.
public let defaultScrollbackLines: UInt32 = {
  #if os(iOS)
    2_000
  #else
    10_000
  #endif
}()

/// Where to connect and as whom.
public struct Jump: Sendable {
  public var host: String
  public var port: UInt16
  public var user: String
  public var credentials: [Credential]
  public init(host: String, port: UInt16 = 22, user: String, credentials: [Credential]) {
    self.host = host; self.port = port; self.user = user; self.credentials = credentials
  }
}

public struct Destination: Sendable {
  public var host: String
  public var port: UInt16
  public var user: String
  /// What the far side will see in `$TERM`. It decides which sequences
  /// remote programs emit, so it must describe what this frontend can
  /// actually draw.
  public var term: String
  public var columns: UInt16
  public var rows: UInt16
  public var scrollbackLines: UInt32
  public var history: SessionHistory?

  public init(
    host: String,
    port: UInt16 = 22,
    user: String,
    term: String = "xterm-256color",
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    scrollbackLines: UInt32 = defaultScrollbackLines,
    history: SessionHistory? = nil
  ) {
    self.host = host
    self.port = port
    self.user = user
    self.term = term
    self.columns = columns
    self.rows = rows
    self.scrollbackLines = scrollbackLines
    self.history = history
  }
}

/// Where a shell on this machine starts, and what it should believe it is
/// running on.
///
/// There is no host, no user and no credential here, and that absence is the
/// design: there is no handshake with the machine the application is already
/// running on. What [`TerminalSession.local`] returns is the same type
/// [`TerminalSession.connect`] returns, so a frontend has one kind of session
/// to draw and not two.
public struct LocalShell: Sendable {
  /// Where the shell starts. The person's home directory when `nil`, which
  /// is what a shell would have chosen anyway.
  public var directory: String?
  /// What the shell will see in `$TERM`. It decides which sequences programs
  /// emit, so it must describe what this frontend can actually draw.
  public var term: String
  public var columns: UInt16
  public var rows: UInt16
  public var scrollbackLines: UInt32
  public var history: SessionHistory?
  public var shell: String?

  public init(
    directory: String? = nil,
    term: String = "xterm-256color",
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    scrollbackLines: UInt32 = defaultScrollbackLines,
    history: SessionHistory? = nil,
    shell: String? = nil
  ) {
    self.shell = shell
    self.directory = directory
    self.term = term
    self.columns = columns
    self.rows = rows
    self.scrollbackLines = scrollbackLines
    self.history = history
  }
}

/// Why a session stopped.
public enum SessionEnding: Sendable, Equatable {
  /// The remote shell exited with this status.
  case exited(status: UInt32)
  /// The application closed it.
  case closed
  /// The connection failed underneath it.
  case lost(cause: String)
}

// MARK: - Session

/// A live terminal session: a remote shell and the screen it is drawing.
///
/// Safe to use from several tasks — a repaint reads the frame while typing
/// writes — because the locking lives in Rust rather than in a consumer's
/// code.
public final class TerminalSession: Sendable {
  private let inner: TetherFFIBindings.Session

  init(_ inner: TetherFFIBindings.Session) {
    self.inner = inner
  }

  /// Local PTY name, used to identify tmux clients opened in this shell.
  public var terminalName: String? { inner.terminalName() }

  /// Connects, authenticates and opens a shell.
  public static func connect(
    to destination: Destination,
    trusting trust: any HostTrust,
    offering credentials: [Credential],
    through jumps: [Jump] = []
  ) async throws -> TerminalSession {
    let token = TetherFFIBindings.CancellationToken()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let session = try await Tether.mapped {
        try await TetherFFIBindings.connectCancellable(
          destination: TetherFFIBindings.Destination(
            host: destination.host,
            port: destination.port,
            user: destination.user,
            term: destination.term,
            columns: destination.columns,
            rows: destination.rows,
            scrollbackLines: destination.scrollbackLines, history: destination.history?.inner),
          trust: HostTrustBridge(trust),
          secrets: credentials.map(secret),
          jumps: jumps.map { TetherFFIBindings.Jump(host: $0.host, port: $0.port, user: $0.user, secrets: $0.credentials.map(secret)) },
          cancellation: token)
      }
      if Task.isCancelled {
        session.close()
        throw CancellationError()
      }
      return TerminalSession(session)
    } onCancel: {
      token.cancel()
    }
  }

  /// Opens a shell on this machine.
  ///
  /// Not a different kind of session: what comes back reads, types, scrolls,
  /// resizes and ends exactly like one that crossed a network, because it is
  /// the same type over a different byte stream. A frontend that can draw one
  /// can draw the other without knowing which it holds.
  public static func local(_ shell: LocalShell = LocalShell()) async throws -> TerminalSession {
    let session = try await Tether.mapped {
      try await TetherFFIBindings.openLocal(
        shell: TetherFFIBindings.LocalShell(
          directory: shell.directory,
          term: shell.term,
          columns: shell.columns,
          rows: shell.rows,
          scrollbackLines: shell.scrollbackLines, shell: shell.shell, history: shell.history?.inner))
    }
    return TerminalSession(session)
  }

  /// Whether this platform lets an application start a shell.
  ///
  /// A question rather than a failure, so an application can leave the
  /// feature out of its interface instead of offering one that always
  /// refuses. iOS answers `false`: there is no `fork`/`exec` outside the
  /// sandbox, and that is the system's decision rather than a setting.
  public static var isLocalAvailable: Bool {
    TetherFFIBindings.localShellAvailable()
  }

  /// Whether OpenSSH already has a multiplexing master for this config alias.
  ///
  /// A live master is a handshake that has already been spent. Attaching
  /// through [`connectOverSsh`] reuses it instead of asking for credentials
  /// again.
  public static func sshMasterIsRunning(_ target: String) async -> Bool {
    await TetherFFIBindings.sshMasterRunning(target: target)
  }

  /// Opens a shell by asking the OpenSSH client, typically a ControlMaster.
  ///
  /// The target is the stanza name (`Arrhenius`), which is the name `ssh`
  /// takes. No host key is asked about and no credential is offered: those
  /// were spent getting the master.
  public static func connectOverSsh(
    _ target: String,
    term: String = "xterm-256color",
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    scrollbackLines: UInt32 = defaultScrollbackLines,
    history: SessionHistory? = nil
  ) async throws -> TerminalSession {
    let token = TetherFFIBindings.CancellationToken()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let session = try await Tether.mapped {
        try await TetherFFIBindings.connectOverSshClientCancellable(
          target: target,
          shell: TetherFFIBindings.LocalShell(
            directory: nil,
            term: term,
            columns: columns,
            rows: rows,
            scrollbackLines: scrollbackLines, shell: nil, history: history?.inner),
          cancellation: token)
      }
      if Task.isCancelled {
        session.close()
        throw CancellationError()
      }
      return TerminalSession(session)
    } onCancel: {
      token.cancel()
    }
  }

  /// A lease on whatever can run a second command where this session's shell
  /// is running.
  ///
  /// Present for both kinds of session, and that is the point: over SSH it is
  /// another channel on the authenticated connection, and on this machine it
  /// is another process. A feature that needs one — a tmux workspace is the
  /// one that exists — is written against this and works on both.
  ///
  /// Still optional, because asking is how a frontend finds out rather than
  /// by knowing what it is holding.
  public var connection: RemoteConnection? {
    inner.connection().map(RemoteConnection.init)
  }

  /// Tells the engine what this application draws with.
  ///
  /// Only used to answer the far side's colour queries. `OSC 11 ; ?` asks
  /// "what is your background?", and a program that hears nothing falls back
  /// to assuming a dark terminal — then paints its own dark theme over every
  /// cell, which no palette on this side can undo, because those cells now
  /// carry explicit colours.
  ///
  /// The screen itself is unchanged: cells still report colour *names*, and
  /// what `red` looks like is still this application's business (spec §12).
  /// Settable at any time — a person switching their window to light is the
  /// same question being asked again.
  public func setPalette(_ palette: TerminalPalette?) throws {
    try Tether.mappedSync {
      try inner.setPalette(palette: palette.map(bridged))
    }
  }

  /// What the text at a cell names — a hyperlink a program attached, a web
  /// address, or something shaped like a path — and where it is drawn, so
  /// it can be underlined. Shape, not truth: a path has not been checked.
  public func link(atRow row: UInt16, column: UInt16) -> TerminalLink? {
    inner.linkAt(row: row, column: column)
  }

  /// The shell's current directory, preferring its OSC 7 report and falling
  /// back to the local shell process when no report is available.
  public var workingDirectory: String? {
    inner.workingDirectory() ?? inner.currentDirectory()
  }

  /// Everything needed to draw the screen once.
  public func frame() -> ScreenFrame {
    inner.frame()
  }

  /// What changed since the last call. Unchanged rows are absent.
  public func update() -> FrameUpdate {
    inner.update()
  }

  /// Commit the screen before the owning tab closes or the app backgrounds.
  public func checkpointHistory() { inner.checkpointHistory() }
  public var historyError: String? { inner.historyError() }

  /// Text a remote program asked to place on the local clipboard since the
  /// last call (`OSC 52`).
  ///
  /// `nil` when it asked for nothing. The caller writes it to this machine's
  /// pasteboard. A request to read the clipboard is refused and does not
  /// appear here.
  public func takeClipboard() -> String? {
    inner.takeClipboard()
  }

  /// Drops scrollback above `keep` lines and does not grow it back.
  public func releaseHistory(keep: UInt32) {
    inner.releaseHistory(keep: keep)
  }

  /// Stops reading the far side until `resume`. Closing still ends the session.
  public func pause() {
    inner.pause()
  }

  /// Reads the far side again. Output that arrived while paused is delivered then.
  public func resume() {
    inner.resume()
  }

  /// Waits until the screen changed, returning `false` once the session has
  /// ended and never will again.
  ///
  /// A repaint loop is `while await session.awaitChange() { … }`: it costs
  /// nothing while the screen is still, and wakes on the first byte.
  /// Polling on a timer would either lag or burn a core.
  public func awaitChange() async -> Bool {
    await inner.awaitChange()
  }

  /// Sends something the person did.
  ///
  /// Encoding happens in Rust, against the modes the *remote* program set:
  /// the same arrow key is a different sequence depending on state only the
  /// terminal knows, which is why this takes a key and not bytes.
  public func send(_ input: TerminalInput) throws {
    try Tether.mappedSync { try inner.send(input: bridged(input)) }
  }

  /// Moves the viewport over the scrollback.
  ///
  /// Nothing is thrown and nothing is returned: the engine clamps at both
  /// ends, so a wheel at the end of its travel is a no-op rather than
  /// something a frontend has to handle on every notch.
  public func scroll(_ to: ScrollTo) {
    let target: TetherFFIBindings.ScrollTo =
      switch to {
      case .lines(let count): .lines(count: count)
      case .pageUp: .pageUp
      case .pageDown: .pageDown
      case .oldest: .oldest
      case .live: .live
      }
    inner.scroll(to: target)
  }

  /// Tells both the engine and the far side that the window changed size.
  public func resize(columns: UInt16, rows: UInt16) throws {
    try Tether.mappedSync { try inner.resize(columns: columns, rows: rows) }
  }

  /// `nil` while the session is still running.
  public func ending() -> SessionEnding? {
    switch inner.ending() {
    case .none: nil
    case .exited(let status): .exited(status: status)
    case .closed: .closed
    case .lost(let cause): .lost(cause: cause)
    }
  }

  /// Ends the session. Idempotent, because a window closing cannot easily
  /// know whether the far side got there first.
  public func close() {
    inner.close()
  }
}

// MARK: - The seam

private func secret(_ credential: Credential) -> TetherFFIBindings.Secret {
  switch credential {
  case .password(let password):
    .password(password: password)
  case .privateKey(let pem, let passphrase, let unlock):
    .privateKey(pem: pem, passphrase: passphrase, unlock: unlock.map(UnlockBridge.init))
  case .interactive(let prompter):
    .interactive(prompter: PrompterBridge(prompter))
  }
}

/// Bridges a consumer's `KeyUnlocker` onto the generated callback
/// interface, so a generated type never appears in a signature a consumer
/// writes.
final class UnlockBridge: TetherFFIBindings.PassphrasePrompter {
  private let inner: any KeyUnlocker

  init(_ inner: any KeyUnlocker) { self.inner = inner }

  func passphrase(key: TetherFFIBindings.LockedKey, attempt: UInt32) async -> String? {
    await inner.passphrase(
      for: LockedKey(fingerprint: key.fingerprint, comment: key.comment), attempt: Int(attempt))
  }
}

private func bridged(_ palette: TerminalPalette) -> TetherFFIBindings.TerminalPalette {
  func colour(_ value: TerminalColor) -> TetherFFIBindings.ColorValue {
    TetherFFIBindings.ColorValue(red: value.red, green: value.green, blue: value.blue)
  }
  return TetherFFIBindings.TerminalPalette(
    foreground: colour(palette.foreground),
    background: colour(palette.background),
    cursor: colour(palette.cursor),
    ansi: palette.ansi.map(colour))
}

func bridged(_ input: TerminalInput) -> TetherFFIBindings.TerminalInput {
  switch input {
  case .paste(let text):
    return .paste(text: text)
  case .key(let key, let modifiers):
    let press: TetherFFIBindings.KeyPress =
      switch key {
      case .text(let text): .char(text: text)
      case .enter: .enter
      case .tab: .tab
      case .backspace: .backspace
      case .escape: .escape
      case .delete: .delete
      case .insert: .insert
      case .up: .up
      case .down: .down
      case .left: .left
      case .right: .right
      case .home: .home
      case .end: .end
      case .pageUp: .pageUp
      case .pageDown: .pageDown
      case .function(let number): .function(number: number)
      }
    return .key(
      key: press,
      modifiers: TetherFFIBindings.KeyModifiers(
        shift: modifiers.shift, alt: modifiers.alt, control: modifiers.control))
  case .pointer(let button, let phase, let column, let row, let modifiers):
    let named: TetherFFIBindings.PointerButton =
      switch button {
      case .left: .left
      case .middle: .middle
      case .right: .right
      case .none: .none
      case .wheelUp: .wheelUp
      case .wheelDown: .wheelDown
      }
    let where_: TetherFFIBindings.PointerPhase =
      switch phase {
      case .press: .press
      case .release: .release
      case .move: .move
      }
    return .pointer(
      button: named, phase: where_, column: column, row: row,
      modifiers: TetherFFIBindings.KeyModifiers(
        shift: modifiers.shift, alt: modifiers.alt, control: modifiers.control))
  }
}

/// Bridges a consumer's `HostTrust` onto the generated callback interface.
private final class HostTrustBridge: TetherFFIBindings.HostTrust {
  private let inner: any HostTrust

  init(_ inner: any HostTrust) { self.inner = inner }

  func trusts(host: TetherFFIBindings.HostIdentity) async -> Bool {
    await inner.trusts(
      HostIdentity(
        host: host.host,
        port: host.port,
        algorithm: host.algorithm,
        fingerprint: host.fingerprint))
  }
}
