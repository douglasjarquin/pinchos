import Darwin
import Foundation
import XCTest
@testable import PinchosCore

final class CommandExecutionTests: XCTestCase {
    func testSuccessfulExecutionCapturesStdoutAndDuration() async throws {
        let runner = CommandRunner(command: "printf 'ok\\n'", timeout: 1, maxOutputBytes: 64)
        let outcome = await runner.runIfIdle()

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        XCTAssertEqual(execution.stdout, "ok\n")
        XCTAssertEqual(execution.stderr, "")
        XCTAssertGreaterThan(execution.duration, 0)
        XCTAssertFalse(execution.stdoutTruncated)
    }

    func testPreservesNonZeroExitCodeAndStderr() async {
        let runner = CommandRunner(command: "printf 'boom\\n' >&2; exit 7", timeout: 1, maxOutputBytes: 64)
        let outcome = await runner.runIfIdle()

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 7))
        XCTAssertEqual(execution.stderr, "boom\n")
        XCTAssertGreaterThan(execution.duration, 0)
    }

    func testSimultaneousLargeStdoutAndStderrAreDrainedAndBounded() async {
        let runner = CommandRunner(
            command: "(yes O | head -c 1048576) & (yes E | head -c 1048576 >&2) & wait",
            timeout: 5,
            maxOutputBytes: 1024
        )
        let outcome = await runner.runIfIdle()

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        XCTAssertGreaterThanOrEqual(execution.stdoutBytesRead, 1024 * 1024)
        XCTAssertGreaterThanOrEqual(execution.stderrBytesRead, 1024 * 1024)
        XCTAssertLessThanOrEqual(execution.stdout.utf8.count, 1024)
        XCTAssertLessThanOrEqual(execution.stderr.utf8.count, 1024)
        XCTAssertTrue(execution.stdoutTruncated)
        XCTAssertTrue(execution.stderrTruncated)
        XCTAssertFalse(execution.stderr.isEmpty)
    }

    func testTimeoutKillsProcessGroup() async throws {
        let childPIDURL = temporaryURL("timeout-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        let command = "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait \"$child\""
        let runner = CommandRunner(command: command, timeout: 0.2, maxOutputBytes: 64)

        let task = Task { await runner.runIfIdle() }
        let childPID = try await waitForPID(at: childPIDURL)
        let outcome = await task.value

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .timedOut)
        XCTAssertTrue(waitUntilGone(childPID), "timeout left child process \(childPID) alive")
    }

    func testCancellationKillsProcessGroup() async throws {
        let childPIDURL = temporaryURL("cancel-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        let command = "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait \"$child\""
        let runner = CommandRunner(command: command, timeout: 30, maxOutputBytes: 64)

        let task = Task { await runner.runIfIdle() }
        let childPID = try await waitForPID(at: childPIDURL)
        await runner.cancelActive()
        let outcome = await task.value

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .cancelled)
        XCTAssertTrue(waitUntilGone(childPID), "cancellation left child process \(childPID) alive")
        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
    }

    private func temporaryURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pinchos-\(prefix)-\(UUID().uuidString)")
    }

    private func waitForPID(at url: URL) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let value = try? String(contentsOf: url), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "CommandExecutionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(url.path)"])
    }

    private func waitUntilGone(_ pid: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }
}
