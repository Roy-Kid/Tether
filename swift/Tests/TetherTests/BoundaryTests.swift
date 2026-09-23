import Foundation
import Testing
@testable import Tether

/// Answers a fixed script, and records what it was asked.
private actor ScriptedPrompter: AuthPrompter {
    private let answers: [[String]]
    private var round = 0
    private(set) var seen: [[AuthPrompt]] = []

    init(answers: [[String]]) { self.answers = answers }

    func answer(instruction: String, prompts: [AuthPrompt]) async -> [String] {
        seen.append(prompts)
        guard round < answers.count else { return [] }
        defer { round += 1 }
        return answers[round]
    }
}

@Suite("Rust boundary")
struct BoundaryTests {
    @Test("every engine is reachable through one surface")
    func composition() {
        // Three, not two: a terminal, and the two producers that can feed
        // it. An about screen that named only some of what a build is made
        // of would be worse than one that named none.
        let parts = Tether.composition()
        #expect(parts.count == 3)
        #expect(parts.contains { $0.hasPrefix("russh") })
        #expect(parts.contains { $0.hasPrefix("portable-pty") })
        #expect(parts.contains { $0.contains("alacritty") })
    }

    @Test("an async Rust call completes")
    func asyncCall() async throws {
        #expect(try await Tether.probeDelay(millis: 10, budgetMillis: 1_000) == "waited 10ms")
    }

    @Test("a Rust-side timeout surfaces as a typed Swift error")
    func timeout() async {
        await #expect(throws: TetherError.timedOut(millis: 20)) {
            try await Tether.probeDelay(millis: 500, budgetMillis: 20)
        }
    }

    @Test("a failure is a sentence, not an NSError code")
    func failureIsReadable() {
        let protocolFailure = TetherError.protocolFailure(cause: "no server running")
        #expect(protocolFailure.localizedDescription == "no server running")
        #expect(!protocolFailure.localizedDescription.contains("couldn't be completed"))

        let refused = TetherError.shellRefused(cause: "server refused the command")
        #expect(refused.localizedDescription.contains("server refused the command"))
        #expect(!refused.localizedDescription.contains("couldn't be completed"))

        let unsupported = TetherError.unsupported(what: "a local shell")
        #expect(unsupported.localizedDescription.contains("a local shell"))
        #expect(!unsupported.localizedDescription.contains("error 8"))
    }

    @Test("a multi-round exchange carries answers up and questions down")
    func exchange() async throws {
        let prompter = ScriptedPrompter(answers: [["first"], ["second"]])
        let collected = try await Tether.authenticate(with: prompter)

        #expect(collected == ["first", "second"])
        let seen = await prompter.seen
        #expect(seen.count == 2)
        // A password prompt must stay unechoed across the boundary, or a
        // consumer would render a one-time code in the clear.
        #expect(seen[0][0].echo == true)
        #expect(seen[1][0].echo == false)
    }

    @Test("declining to answer is a cancellation, not a failure")
    func declining() async {
        await #expect(throws: TetherError.cancelled) {
            try await Tether.authenticate(with: ScriptedPrompter(answers: []))
        }
    }

    /// Asserts timing as well as the error. Before the façade carried a
    /// cancellation token across, this call returned "waited 5000ms"
    /// successfully — an untimed check would have passed against a build where
    /// cancellation did nothing at all.
    @Test("cancelling a Swift task interrupts the Rust future")
    func cancellationReachesRust() async {
        let start = Date()
        let task = Task { try await Tether.probeDelay(millis: 5_000, budgetMillis: 10_000) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        var thrown: TetherError?
        do { _ = try await task.value } catch let error as TetherError { thrown = error } catch {}

        #expect(thrown == .cancelled)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test("an already-cancelled task never crosses the boundary")
    func preCancelled() async {
        let task = Task { try await Tether.probeDelay(millis: 5_000, budgetMillis: 10_000) }
        task.cancel()

        var shortCircuited = false
        do { _ = try await task.value } catch is CancellationError { shortCircuited = true } catch {}

        #expect(shortCircuited)
    }
}
