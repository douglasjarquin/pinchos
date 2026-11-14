import Foundation
import XCTest
@testable import PinchosCore

// Deterministic resource-invariant coverage for issue #55 (P4 "output
// pressure" budget) and issue #129 (completed-cache vs active-output
// budgets), at the full `CommandRunner`/`CommandSource` integration level.
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

    /// The 8 MiB `OutputMemoryBudget` only covers live `TailByteBuffer`
    /// storage. After a command settles, `CachedValue` / `CommandExecution`
    /// Strings live outside that budget and must be measured separately
    /// (#129). They stay bounded by the per-runner byte cap, replace on
    /// refresh rather than accumulating, and the active budget returns to
    /// zero once collectors deallocate.
    func testCompletedCacheIsBoundedIndependentlyOfTheActiveOutputBudget() async throws {
        let budget = OutputMemoryBudget(totalBytes: 8 * 1024 * 1024)
        let cap = 4096
        let produced = 64 * 1024
        let runner = CommandRunner(
            command: "head -c \(produced) /dev/zero | tr '\\0' 'A'",
            timeout: 5,
            maxOutputBytes: cap,
            outputBudget: budget
        )
        let source = CommandSource(
            configuration: CommandSourceConfiguration(
                command: "ignored",
                timeout: 5,
                maxOutputBytes: cap
            ),
            scheduler: CommandScheduler(maxActiveSessions: 1),
            runner: runner
        )

        let cached = await source.refresh()
        XCTAssertEqual(cached.state, .fresh)
        XCTAssertEqual(cached.value?.utf8.count, cap)
        XCTAssertEqual(cached.lastExecution?.stdout.utf8.count, cap)
        XCTAssertEqual(cached.lastExecution?.stdoutBytesRead, produced)
        XCTAssertLessThanOrEqual(retainedCacheUTF8Bytes(cached), cap * 2)
        XCTAssertEqual(
            budget.reservedBytesSnapshot,
            0,
            "active TailByteBuffer reservation must drop after the run settles; completed Strings are outside that budget"
        )

        let preview = DiagnosticPreviewFormatter.preview(
            cached.value ?? "",
            limits: .menuValue
        )
        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThan(
            preview.text.utf8.count,
            cap,
            "UI snapshot size is a separate, smaller bound than completed-cache retention"
        )
    }

    func testCompletedCacheReplacesOnRefreshAndDropsWhenTheLastConsumerReleases() async throws {
        let budget = OutputMemoryBudget(totalBytes: 1024 * 1024)
        let cap = 2048
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-129-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: log) }
        let command = """
        printf 'x\\n' >> '\(log.path)'; \
        count=$(wc -l < '\(log.path)' | tr -d ' '); \
        if [ "$count" -eq 1 ]; then head -c \(cap) /dev/zero | tr '\\0' 'B'; else printf tiny; fi
        """
        let registry = CommandSourceRegistry()
        let scheduler = CommandScheduler(maxActiveSessions: 2)
        let configuration = CommandSourceConfiguration(
            command: command,
            timeout: 5,
            maxOutputBytes: cap
        )
        let runner = CommandRunner(
            command: command,
            timeout: 5,
            maxOutputBytes: cap,
            outputBudget: budget
        )
        let first = registry.acquire(
            configuration: configuration,
            scheduler: scheduler,
            runner: runner
        )
        let second = registry.acquire(configuration: configuration, scheduler: scheduler)
        XCTAssertEqual(registry.sourceCount, 1)

        let large = await first.source.refresh()
        XCTAssertEqual(large.value?.utf8.count, cap)
        XCTAssertEqual(retainedCacheUTF8Bytes(large), cap * 2)

        let tiny = await first.source.refresh()
        XCTAssertEqual(tiny.value, "tiny")
        XCTAssertLessThan(
            retainedCacheUTF8Bytes(tiny),
            32,
            "a later small result must replace the large completed cache, not sit beside it"
        )
        XCTAssertEqual(budget.reservedBytesSnapshot, 0)

        await registry.releaseAndCancelIfLast(first)
        XCTAssertEqual(registry.sourceCount, 1)
        await registry.releaseAndCancelIfLast(second)
        XCTAssertEqual(registry.sourceCount, 0)
        XCTAssertEqual(budget.reservedBytesSnapshot, 0)
    }

    func testManyCompletedSourcesDoNotAccumulatePastPerSourceCaps() async throws {
        let budget = OutputMemoryBudget(totalBytes: 1024 * 1024)
        let cap = 1024
        let sourceCount = 8
        var snapshots: [CachedValue] = []
        snapshots.reserveCapacity(sourceCount)

        for index in 0..<sourceCount {
            let marker = String(UnicodeScalar(65 + index)!)
            let command = "head -c \(cap * 4) /dev/zero | tr '\\0' '\(marker)'"
            let source = CommandSource(
                configuration: CommandSourceConfiguration(
                    command: command,
                    timeout: 5,
                    maxOutputBytes: cap
                ),
                scheduler: CommandScheduler(maxActiveSessions: 1),
                runner: CommandRunner(
                    command: command,
                    timeout: 5,
                    maxOutputBytes: cap,
                    outputBudget: budget
                )
            )
            snapshots.append(await source.refresh())
        }

        let retained = snapshots.reduce(0) { $0 + retainedCacheUTF8Bytes($1) }
        XCTAssertLessThanOrEqual(retained, sourceCount * cap * 2)
        XCTAssertEqual(budget.reservedBytesSnapshot, 0)
        XCTAssertTrue(snapshots.allSatisfy { $0.state == .fresh })
    }

    private func retainedCacheUTF8Bytes(_ cached: CachedValue) -> Int {
        (cached.value?.utf8.count ?? 0)
            + (cached.lastExecution?.stdout.utf8.count ?? 0)
            + (cached.lastExecution?.stderr.utf8.count ?? 0)
            + (cached.diagnostic?.utf8.count ?? 0)
    }
}
