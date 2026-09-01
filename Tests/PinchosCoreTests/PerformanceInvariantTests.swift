import Foundation
import XCTest
@testable import PinchosCore

// Deterministic resource-invariant coverage for issue #55 (P4 "output
// pressure" budget), at the full `CommandRunner` integration level.
//
// `Tests/PinchosCoreTests/TailByteBufferTests.swift` already proves the
// underlying ring buffer's exact-cap and tail-retention behavior at the unit
// level, and `CommandExecutionTests.testAggregateOutputBudgetCapsRetainedBytesAcrossManyRunners`
// already proves the shared `OutputMemoryBudget` bounds many runners
// together. This file adds one thing neither covers: an end-to-end,
// timing-independent proof (via `head -c`, not `yes`, so there is no
// process-scheduling race) that a real `CommandRunner` retains *exactly* its
// explicit per-runner budget and *exactly* the tail of the stream -- not just
// "some amount less than or equal to it" -- through the same path `ManagedItem`
// uses in production.
//
// See docs/performance.md for the full profile catalogue and the wall-clock/
// RSS budgets enforced separately on a reference machine.
final class PerformanceInvariantTests: XCTestCase {
    func testRetainedStdoutIsExactlyBoundedToTheRunnerByteBudgetAndKeepsTheTail() async throws {
        let headBytes = 7936
        let tailBytes = 256
        let command = "head -c \(headBytes) /dev/zero | tr '\\0' 'B'; head -c \(tailBytes) /dev/zero | tr '\\0' 'C'"
        let runner = CommandRunner(command: command, timeout: 5, maxOutputBytes: tailBytes)

        let outcome = await runner.runIfIdle()
        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }

        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        XCTAssertEqual(
            execution.stdoutBytesRead, headBytes + tailBytes,
            "byte-read accounting must report the true produced volume even while retention is capped"
        )
        XCTAssertEqual(
            execution.stdout.utf8.count, tailBytes,
            "retained stdout must be capped at exactly the runner byte budget, not merely bounded above it"
        )
        XCTAssertEqual(
            execution.stdout, String(repeating: "C", count: tailBytes),
            "the retained bytes must be the tail of the stream, not the head, so the most recent output survives truncation"
        )
        XCTAssertTrue(execution.stdoutTruncated)
    }
}
