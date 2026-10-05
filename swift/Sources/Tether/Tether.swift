import Foundation
import TetherFFIBindings

/// A single question an SSH server asks during keyboard-interactive auth.
///
/// `echo` is false for anything that must not be shown while typed — a
/// password, a one-time code — and a consumer is expected to honour it.
public struct AuthPrompt: Sendable, Equatable {
    public let text: String
    public let echo: Bool

    public init(text: String, echo: Bool) {
        self.text = text
        self.echo = echo
    }
}

/// Answers the questions a server asks.
///
/// The server decides how many rounds there are and what it asks; neither is
/// known in advance, which is why this is a conversation rather than a
/// credential handed over once.
public protocol AuthPrompter: Sendable {
    func answer(instruction: String, prompts: [AuthPrompt]) async -> [String]
}

public enum TetherError: Error, Equatable, Sendable, LocalizedError {
    /// The person declined, or the surrounding `Task` was cancelled.
    case cancelled
    case timedOut(millis: UInt64)

    case unreachable(endpoint: String, cause: String)
    /// The application's own trust decision, handed back to it. Nothing was
    /// sent: this is not a failed login.
    case hostRejected(endpoint: String)
    /// What the server said it would still accept, so an application can say
    /// "this host wants a key" rather than "login failed" — and the keys that
    /// were never used, with why. `remaining` is empty when nothing reached
    /// the server to be refused: every key given was unusable.
    case authenticationFailed(remaining: [String], skipped: [SkippedKey] = [])
    /// The credential was *accepted* and another factor is wanted, but none
    /// was left to offer. Telling someone their password was wrong when it
    /// was right is its own failure.
    case moreFactorsNeeded(remaining: [String])
    case nothingToOffer
    /// Neither side would give us a shell. Worded for both: by this point an
    /// application holds a session and does not care whether the shell it
    /// asked for was going to run here or somewhere else.
    case shellRefused(cause: String)
    /// The system does not offer this at all. iOS and a local shell is the
    /// case it exists for — distinct from a refusal, because a refusal is
    /// something a person might be able to fix.
    case unsupported(what: String)
    case disconnected(cause: String)
    case sessionEnded
    case protocolFailure(cause: String)

    /// Without this, SwiftUI prints `The operation couldn’t be completed.
    /// (TetherError error 8.)` — the NSError code, not the cause. The session
    /// tree and every other `localizedDescription` site would then hide the
    /// only sentence that can be acted on.
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Cancelled."
        case .timedOut(let millis):
            return "Timed out after \(millis)ms."
        case .unreachable(_, let cause):
            return "Could not reach the host. \(cause)"
        case .hostRejected:
            return "The host key was not trusted."
        case .authenticationFailed(let remaining, let skipped):
            let refused = remaining.isEmpty
                ? "Authentication failed."
                : "Authentication failed. The server accepts: \(remaining.joined(separator: ", "))."
            return ([refused] + skipped.map(\.sentence)).joined(separator: " ")
        case .moreFactorsNeeded(let remaining):
            return "Another factor is needed: \(remaining.joined(separator: ", "))."
        case .nothingToOffer:
            return "No credentials were offered."
        case .shellRefused(let cause):
            return "Could not open a shell. \(cause)"
        case .unsupported(let what):
            return "This device does not offer \(what)."
        case .disconnected(let cause):
            return "The connection was lost. \(cause)"
        case .sessionEnded:
            return "The session has ended."
        case .protocolFailure(let cause):
            let cause = cause.trimmingCharacters(in: .whitespacesAndNewlines)
            return cause.isEmpty ? "Protocol failure." : cause
        }
    }
}

/// Why a private key could not be used.
public enum KeyProblem: Sendable, Equatable, CustomStringConvertible {
    /// Not a private key in a format this build reads. `cause` is the
    /// parser's own words, for diagnostics rather than for a person.
    case unreadable(cause: String)
    /// A kind this build cannot sign with — a hardware security key, whose
    /// private half never leaves the device, or DSA.
    case unsupported(what: String)
    /// Protected by a passphrase, and nothing was given to ask for it.
    case locked
    /// Every passphrase offered for it was wrong.
    case wrongPassphrase

    /// A clause, to follow a key's name.
    public var description: String {
        switch self {
        case .unreadable: "it is not a private key that can be read"
        case .unsupported(let what): "\(what) are not supported"
        case .locked: "it needs a passphrase that was not given"
        case .wrongPassphrase: "the passphrase was not accepted"
        }
    }
}

/// A private key that was left out of a login, and why.
public struct SkippedKey: Sendable, Equatable {
    /// Its place among the credentials offered, counting from zero — which
    /// is how an application that built that list finds the file.
    public let position: Int
    /// `SHA256:…`, when the key could be read far enough to have one.
    public let fingerprint: String?
    public let problem: KeyProblem
    /// What a person calls it. Tether never learns a file name; an
    /// application that knows one sets it, and the error's sentence uses it.
    public var name: String?

    public init(position: Int, fingerprint: String?, problem: KeyProblem, name: String? = nil) {
        self.position = position
        self.fingerprint = fingerprint
        self.problem = problem
        self.name = name
    }

    /// One sentence: which key, and why it was not used.
    var sentence: String {
        "\(name ?? fingerprint ?? "A key") was not used: \(problem)."
    }

    init(_ skipped: TetherFFIBindings.SkippedKey) {
        let problem: KeyProblem =
            switch skipped.problem {
            case .unreadable(let cause): .unreadable(cause: cause)
            case .unsupported(let what): .unsupported(what: what)
            case .locked: .locked
            case .wrongPassphrase: .wrongPassphrase
            }
        self.init(position: Int(skipped.position), fingerprint: skipped.fingerprint, problem: problem)
    }
}

public enum Tether {
    public static func composition() -> [String] {
        TetherFFIBindings.composition()
    }

    public static func probeDelay(millis: UInt64, budgetMillis: UInt64) async throws -> String {
        try await cancellable { token in
            try await TetherFFIBindings.probeDelay(
                millis: millis, budgetMillis: budgetMillis, token: token)
        }
    }

    public static func authenticate(with prompter: AuthPrompter) async throws -> [String] {
        try await mapped {
            try await TetherFFIBindings.runInteractiveExchange(
                prompter: PrompterBridge(prompter))
        }
    }
}

// MARK: - The seam

/// Bridges a consumer's `AuthPrompter` onto the generated callback interface,
/// so generated types never appear in a signature a consumer writes.
final class PrompterBridge: TetherFFIBindings.InteractivePrompter {
    private let inner: AuthPrompter

    init(_ inner: AuthPrompter) { self.inner = inner }

    func answer(
        instruction: String,
        prompts: [TetherFFIBindings.AuthPrompt]
    ) async -> [String] {
        await inner.answer(
            instruction: instruction,
            prompts: prompts.map { AuthPrompt(text: $0.text, echo: $0.echo) })
    }
}

extension Tether {
    /// Runs `body` with a cancellation token wired to the surrounding task.
    ///
    /// UniFFI's generated Swift polls a Rust future to completion and never
    /// consults `Task.isCancelled` — measured, not assumed: a cancelled
    /// three-second call returned normally after 3002ms. Carrying the token
    /// across by hand is what makes ordinary `Task.cancel()` work for a
    /// consumer.
    static func cancellable<T>(
        _ body: @escaping @Sendable (TetherFFIBindings.CancellationToken) async throws -> T
    ) async throws -> T {
        let token = TetherFFIBindings.CancellationToken()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await mapped { try await body(token) }
        } onCancel: {
            token.cancel()
        }
    }

    /// Translates generated errors into Tether's own, so a consumer switches
    /// over a Swift enum rather than over whatever the generator emitted.
    static func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as TetherFFIBindings.TetherError {
            throw translate(error)
        }
    }

    /// The same translation for the calls that do not await.
    static func mappedSync<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TetherFFIBindings.TetherError {
            throw translate(error)
        }
    }

    static func translate(_ error: TetherFFIBindings.TetherError) -> TetherError {
        switch error {
        case .Cancelled: .cancelled
        case .TimedOut(let millis): .timedOut(millis: millis)
        case .Unreachable(let endpoint, let cause): .unreachable(endpoint: endpoint, cause: cause)
        case .HostRejected(let endpoint): .hostRejected(endpoint: endpoint)
        case .AuthenticationFailed(let remaining, let skipped):
            .authenticationFailed(remaining: remaining, skipped: skipped.map(SkippedKey.init))
        case .MoreFactorsNeeded(let remaining): .moreFactorsNeeded(remaining: remaining)
        case .NothingToOffer: .nothingToOffer
        case .ShellRefused(let cause): .shellRefused(cause: cause)
        case .Unsupported(let what): .unsupported(what: what)
        case .Disconnected(let cause): .disconnected(cause: cause)
        case .SessionEnded: .sessionEnded
        case .Protocol(let cause): .protocolFailure(cause: cause)
        }
    }
}
