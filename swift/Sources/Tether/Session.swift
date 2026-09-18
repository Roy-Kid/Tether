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
public typealias ScreenRow = TetherFFIBindings.ScreenRow
public typealias StyledRun = TetherFFIBindings.StyledRun
public typealias CellStyle = TetherFFIBindings.CellStyle
public typealias CellColor = TetherFFIBindings.CellColor
public typealias ColorName = TetherFFIBindings.ColorName
public typealias UnderlineStyle = TetherFFIBindings.UnderlineStyle
public typealias CaretShape = TetherFFIBindings.CaretShape

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

/// Something the person did.
public enum TerminalInput: Sendable, Equatable {
  case key(Key, KeyModifiers = .none)
  /// Text arriving all at once. Bracketing — and the stripping that stops a
  /// paste from ending its own bracket — happens in the engine, where the
  /// mode that decides it lives.
  case paste(String)
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
}

/// Decides whether a host may be talked to.
///
/// Asked during the handshake, before any credential exists on the wire —
/// which is the point of asking. There is no trust-everything default to
/// reach for; an application must say what trust means to it.
public protocol HostTrust: Sendable {
  func trusts(_ host: HostIdentity) async -> Bool
}

/// Something to authenticate with. Offered in the order given, which is how
/// "a key, then a one-time code" is expressed: two credentials, one login.
public enum Credential: Sendable {
  case password(String)
  /// PEM text, so a key in a keychain item never has to reach the disk.
  case privateKey(pem: String, passphrase: String? = nil)
  case interactive(any AuthPrompter)
}

/// Where to connect and as whom.
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

  public init(
    host: String,
    port: UInt16 = 22,
    user: String,
    term: String = "xterm-256color",
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    scrollbackLines: UInt32 = 10_000
  ) {
    self.host = host
    self.port = port
    self.user = user
    self.term = term
    self.columns = columns
    self.rows = rows
    self.scrollbackLines = scrollbackLines
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

  fileprivate init(_ inner: TetherFFIBindings.Session) {
    self.inner = inner
  }

  /// Connects, authenticates and opens a shell.
  public static func connect(
    to destination: Destination,
    trusting trust: any HostTrust,
    offering credentials: [Credential]
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
            scrollbackLines: destination.scrollbackLines),
          trust: HostTrustBridge(trust),
          secrets: credentials.map(secret), cancellation: token)
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

  public var connection: RemoteConnection? {
    inner.connection().map(RemoteConnection.init)
  }

  /// Everything needed to draw the screen once.
  public func frame() -> ScreenFrame {
    inner.frame()
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
  case .privateKey(let pem, let passphrase):
    .privateKey(pem: pem, passphrase: passphrase)
  case .interactive(let prompter):
    .interactive(prompter: PrompterBridge(prompter))
  }
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
