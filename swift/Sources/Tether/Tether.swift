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

public enum TetherError: Error, Equatable, Sendable {
    /// The person declined, or the surrounding `Task` was cancelled.
    case cancelled
    case timedOut(millis: UInt64)
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
private final class PrompterBridge: TetherFFIBindings.InteractivePrompter {
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
            switch error {
            case .Cancelled: throw TetherError.cancelled
            case .TimedOut(let millis): throw TetherError.timedOut(millis: millis)
            }
        }
    }
}
