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
    @Test("both engines are reachable through one surface")
    func composition() {
        #expect(Tether.composition().count == 2)
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
