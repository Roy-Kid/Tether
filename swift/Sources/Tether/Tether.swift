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
    /// "this host wants a key" rather than "login failed".
    case authenticationFailed(remaining: [String])
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
        case .unreachable(let endpoint, let cause):
            return "Could not reach \(endpoint). \(cause)"
        case .hostRejected(let endpoint):
            return "The host key for \(endpoint) was not trusted."
        case .authenticationFailed(let remaining):
            return remaining.isEmpty
                ? "Authentication failed."
                : "Authentication failed. The server accepts: \(remaining.joined(separator: ", "))."
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
    /// consumer. See `Decisions/0003`.
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
        case .AuthenticationFailed(let remaining): .authenticationFailed(remaining: remaining)
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
