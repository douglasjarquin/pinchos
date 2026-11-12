import Foundation
import XCTest
@testable import PinchosCore

final class CommandRunnerTests: XCTestCase {
    func testSkippedRefreshTicksAreRecordedAndLastExecutionIsPreserved() async throws {
        let runner = CommandRunner(command: "sleep 0.2; printf done", timeout: 1, maxOutputBytes: 64)
        let firstTask = Task { await runner.runIfIdle() }
        try await waitUntilRunning(runner)

        let skippedOutcome = await runner.runIfIdle()
        XCTAssertEqual(skippedOutcome, .skipped)
        let firstOutcome = await firstTask.value
        guard case .completed(let execution) = firstOutcome else {
            return XCTFail("expected the first execution to complete, got \(firstOutcome)")
        }
        XCTAssertEqual(execution.stdout, "done")

        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.skippedRefreshes, 1)
        XCTAssertEqual(snapshot.lastExecution, execution)
    }

    func testManualRefreshDuringScheduledRunUsesTheSameExecutionGate() async throws {
        let runner = CommandRunner(command: "sleep 0.2; printf scheduled", timeout: 1, maxOutputBytes: 64)
        let scheduledTask = Task { await runner.runIfIdle() }
        try await waitUntilRunning(runner)

        let manualOutcome = await runner.runIfIdle()

        XCTAssertEqual(manualOutcome, .skipped)
        guard case .completed(let scheduledExecution) = await scheduledTask.value else {
            return XCTFail("expected the scheduled execution to complete")
        }
        XCTAssertEqual(scheduledExecution.stdout, "scheduled")
        let snapshot = await runner.snapshot()
        XCTAssertEqual(snapshot.skippedRefreshes, 1)
        XCTAssertEqual(snapshot.lastExecution, scheduledExecution)
    }

    func testCancellationIsIdempotentAndRunnerCanRunAgain() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pinchos-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = CommandRunner(
            command: "if [ ! -e '\(marker.path)' ]; then touch '\(marker.path)'; sleep 30; else exit 0; fi",
            timeout: 30,
            maxOutputBytes: 64
        )
        let firstTask = Task { await runner.runIfIdle() }
        try await waitUntilRunning(runner)
        try await waitUntilMarkerCreated(marker)

        await runner.cancelActive()
        await runner.cancelActive()
        guard case .completed(let firstExecution) = await firstTask.value else {
            return XCTFail("expected cancellation to produce a completed execution")
        }
        XCTAssertEqual(firstExecution.terminalReason, .cancelled)

        let secondOutcome = await runner.runIfIdle()
        guard case .completed(let secondExecution) = secondOutcome else {
            return XCTFail("expected a subsequent run to complete, got \(secondOutcome)")
        }
        XCTAssertEqual(secondExecution.terminalReason, .exited(code: 0))
    }

    func testBeginIfIdleWhileRunningIsSkipped() async throws {
        let runner = CommandRunner(command: "sleep 0.2; printf done", timeout: 1, maxOutputBytes: 64)
        let started = await runner.beginIfIdle()
        XCTAssertTrue(started)

        let secondStart = await runner.beginIfIdle()
        XCTAssertFalse(secondStart)
        let runningSnapshot = await runner.snapshot()
        XCTAssertTrue(runningSnapshot.isRunning)
        XCTAssertEqual(runningSnapshot.skippedRefreshes, 1)

        guard case .completed(let execution) = await runner.finishActiveRun() else {
            return XCTFail("expected the started run to complete")
        }
        XCTAssertEqual(execution.stdout, "done")
        let finishAgain = await runner.finishActiveRun()
        XCTAssertEqual(finishAgain, .skipped, "an idle runner has no active run to finish")
    }

    func testBeginIfIdleWhileDescendantsLingerIsSkippedUntilCancelled() async throws {
        let childPID = temporaryURL("lingering-child")
        defer { try? FileManager.default.removeItem(at: childPID) }
        let command = "(trap '' TERM; while :; do sleep 1; done) & printf '%s' \"$!\" > '\(childPID.path)'; exit 0"
        let runner = CommandRunner(command: command, timeout: 30, maxOutputBytes: 64)

        guard case .completed(let preliminary) = await runner.runIfIdle() else {
            return XCTFail("expected the shell to complete")
        }
        XCTAssertEqual(preliminary.terminalReason, .exited(code: 0))
        let child = try await waitForPID(at: childPID)
        defer { kill(child, SIGKILL) }

        let lingeringStart = await runner.beginIfIdle()
        XCTAssertFalse(lingeringStart)
        let lingeringSnapshot = await runner.snapshot()
        XCTAssertTrue(lingeringSnapshot.isRunning, "a run whose descendants remain stays running")
        XCTAssertEqual(lingeringSnapshot.skippedRefreshes, 1)

        await runner.cancelActive()

        let cancelledSnapshot = await runner.snapshot()
        XCTAssertFalse(cancelledSnapshot.isRunning)
        XCTAssertEqual(cancelledSnapshot.lastExecution?.terminalReason, .cancelled)
        let restarted = await runner.beginIfIdle()
        XCTAssertTrue(restarted, "a cancelled lingering run returns the runner to idle")
        _ = await runner.finishActiveRun()
    }

    func testLingeringDescendantsSettlingReturnTheRunnerToIdle() async throws {
        let runner = CommandRunner(command: "(sleep 0.3; printf late) & exit 0", timeout: 5, maxOutputBytes: 64)

        guard case .completed(let preliminary) = await runner.runIfIdle() else {
            return XCTFail("expected the shell to complete")
        }
        XCTAssertEqual(preliminary.terminalReason, .exited(code: 0))
        let lingeringSnapshot = await runner.snapshot()
        XCTAssertTrue(lingeringSnapshot.isRunning)

        let settled = await waitForRunnerIdle(runner)
        XCTAssertFalse(settled.isRunning)
        XCTAssertEqual(settled.lastExecution?.stdout, "late")
        let restarted = await runner.beginIfIdle()
        XCTAssertTrue(restarted)
        _ = await runner.finishActiveRun()
    }

    func testBeginIfIdleDuringCancellationIsSkipped() async throws {
        let escapedPID = temporaryURL("cancelling-escapee")
        defer { try? FileManager.default.removeItem(at: escapedPID) }
        let runner = CommandRunner(command: try escapedShellCommand(pidFile: escapedPID), timeout: 30, maxOutputBytes: 64)
        let runTask = Task { await runner.runIfIdle() }
        let escaped = try await waitForPID(at: escapedPID)
        defer { kill(escaped, SIGKILL) }

        let cancellation = Task { await runner.cancelActive() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let startedDuringCancellation = await runner.beginIfIdle()
        XCTAssertFalse(startedDuringCancellation)
        let cancellingSnapshot = await runner.snapshot()
        XCTAssertTrue(cancellingSnapshot.isRunning)
        XCTAssertEqual(cancellingSnapshot.skippedRefreshes, 1)

        kill(escaped, SIGKILL)
        await cancellation.value
        guard case .completed(let execution) = await runTask.value else {
            return XCTFail("expected the cancelled run to complete")
        }
        XCTAssertEqual(execution.terminalReason, .cancelled)
        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        let restarted = await runner.beginIfIdle()
        XCTAssertTrue(restarted, "a finished cancellation returns the runner to idle")
    }

    func testConcurrentCancelActiveCallsCancelTheRunOnce() async throws {
        let escapedPID = temporaryURL("double-cancel-escapee")
        defer { try? FileManager.default.removeItem(at: escapedPID) }
        let runner = CommandRunner(command: try escapedShellCommand(pidFile: escapedPID), timeout: 30, maxOutputBytes: 64)
        let runTask = Task { await runner.runIfIdle() }
        let escaped = try await waitForPID(at: escapedPID)
        defer { kill(escaped, SIGKILL) }

        let returned = ReturnCounter()
        let first = Task { await runner.cancelActive(); returned.increment() }
        let second = Task { await runner.cancelActive(); returned.increment() }
        let deadline = Date().addingTimeInterval(2)
        while returned.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(returned.count, 1, "the call that joins an in-flight cancellation returns without starting another")
        let inFlightSnapshot = await runner.snapshot()
        XCTAssertTrue(inFlightSnapshot.isRunning, "the original cancellation is still waiting for the command")

        kill(escaped, SIGKILL)
        await first.value
        await second.value
        guard case .completed(let execution) = await runTask.value else {
            return XCTFail("expected the cancelled run to complete")
        }
        XCTAssertEqual(execution.terminalReason, .cancelled)
        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.lastExecution?.terminalReason, .cancelled)
    }

    func testCancelForShutdownFromIdleRejectsLaterRuns() async {
        let runner = CommandRunner(command: "printf never", timeout: 1, maxOutputBytes: 64)
        await runner.cancelForShutdown()

        let started = await runner.beginIfIdle()
        XCTAssertFalse(started)
        let outcome = await runner.runIfIdle()
        XCTAssertEqual(outcome, .skipped)
        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertNil(snapshot.lastExecution)
        XCTAssertEqual(snapshot.skippedRefreshes, 2)

        await runner.cancelActive()
        await runner.cancelForShutdown()
        let startedAfterRepeatedCancel = await runner.beginIfIdle()
        XCTAssertFalse(startedAfterRepeatedCancel, "a shut down runner never runs again")
    }

    func testCancelForShutdownDuringCancellationEndsShutDown() async throws {
        let escapedPID = temporaryURL("shutdown-during-cancel-escapee")
        defer { try? FileManager.default.removeItem(at: escapedPID) }
        let runner = CommandRunner(command: try escapedShellCommand(pidFile: escapedPID), timeout: 30, maxOutputBytes: 64)
        let runTask = Task { await runner.runIfIdle() }
        let escaped = try await waitForPID(at: escapedPID)
        defer { kill(escaped, SIGKILL) }

        let cancellation = Task { await runner.cancelActive() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let shutdown = Task { await runner.cancelForShutdown() }
        try await Task.sleep(nanoseconds: 50_000_000)
        kill(escaped, SIGKILL)
        await cancellation.value
        await shutdown.value
        guard case .completed(let execution) = await runTask.value else {
            return XCTFail("expected the cancelled run to complete")
        }
        XCTAssertEqual(execution.terminalReason, .cancelled)

        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        let started = await runner.beginIfIdle()
        XCTAssertFalse(started, "shutdown requested during a cancellation must outlast it")
    }

    func testFinishActiveRunAfterConcurrentCancellationKeepsTheCancelledResult() async throws {
        let marker = temporaryURL("finish-after-cancel")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = CommandRunner(
            command: "if [ ! -e '\(marker.path)' ]; then touch '\(marker.path)'; trap '' TERM; sleep 30; else printf second; fi",
            timeout: 30,
            maxOutputBytes: 64
        )
        let runTask = Task { await runner.runIfIdle() }
        try await waitUntilMarkerCreated(marker)

        await runner.cancelActive()
        guard case .completed(let cancelled) = await runTask.value else {
            return XCTFail("expected the cancelled run to complete")
        }
        XCTAssertEqual(cancelled.terminalReason, .cancelled)
        let cancelledSnapshot = await waitForRunnerIdle(runner)
        XCTAssertEqual(cancelledSnapshot.lastExecution?.terminalReason, .cancelled)

        guard case .completed(let second) = await runner.runIfIdle() else {
            return XCTFail("expected the runner to run again after cancellation")
        }
        XCTAssertEqual(second.stdout, "second")
        let finalSnapshot = await runner.snapshot()
        XCTAssertFalse(finalSnapshot.isRunning)
        XCTAssertEqual(finalSnapshot.lastExecution, second)
    }

    /// The shell execs a process that leaves the command's process group
    /// before recording its pid, so cancellation cannot kill it and stays in
    /// flight until the test kills it.
    private func escapedShellCommand(pidFile: URL) throws -> String {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
        return "exec /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); open(my $f, \">\", $ARGV[0]); print $f $$; close($f); sleep 30' '\(pidFile.path)'"
    }

    private func temporaryURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pinchos-runner-\(prefix)-\(UUID().uuidString)")
    }

    private func waitForPID(at url: URL) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let value = try? String(contentsOf: url, encoding: .utf8),
                let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "CommandRunnerTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(url.path)"])
    }

    private func waitForRunnerIdle(_ runner: CommandRunner, timeout: TimeInterval = 5) async -> CommandRunnerSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var snapshot = await runner.snapshot()
        while snapshot.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            snapshot = await runner.snapshot()
        }
        return snapshot
    }

    private func waitUntilRunning(_ runner: CommandRunner) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await runner.snapshot().isRunning {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "CommandRunnerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "runner did not become active"])
    }

    private func waitUntilMarkerCreated(_ marker: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "CommandRunnerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "command did not create its readiness marker"])
    }
}

private final class ReturnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
