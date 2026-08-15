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
}
