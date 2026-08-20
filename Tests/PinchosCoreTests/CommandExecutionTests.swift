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

    func testConfiguredEnvironmentMergesAndOverridesInheritedValuesAndUsesWorkingDirectory() async throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let inheritedHome = try XCTUnwrap(ProcessInfo.processInfo.environment["HOME"])
        let configuredPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let runner = CommandRunner(
            command: "printf '%s\\n%s\\n%s\\n' \"$HOME\" \"$PATH\" \"$PINCHOS_TEST_OVERRIDE\"; pwd",
            timeout: 1,
            maxOutputBytes: 512,
            shell: ["/bin/zsh", "-lc"],
            workingDirectory: workingDirectory.path,
            environment: [
                "PATH": configuredPath,
                "PINCHOS_TEST_OVERRIDE": "configured's value"
            ]
        )

        let outcome = await runner.runIfIdle()
        guard case .completed(let execution) = outcome else {
            return XCTFail("expected configured execution to complete, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        let outputLines = execution.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard outputLines.count == 4 else {
            return XCTFail("expected four output lines, got \(outputLines)")
        }
        XCTAssertEqual(outputLines[0], inheritedHome)
        XCTAssertEqual(outputLines[1], configuredPath)
        XCTAssertEqual(outputLines[2], "configured's value")
        XCTAssertEqual(URL(fileURLWithPath: outputLines[3]).lastPathComponent, workingDirectory.lastPathComponent)
    }

    func testUnresolvableConfiguredShellReportsItsPath() async {
        let shell = "/definitely/missing/pinchos-shell"
        let runner = CommandRunner(
            command: "printf ok",
            timeout: 1,
            maxOutputBytes: 64,
            shell: [shell, "-lc"]
        )

        guard case .completed(let execution) = await runner.runIfIdle() else {
            return XCTFail("expected a completed launch failure")
        }
        guard case .launchFailed(let message) = execution.terminalReason else {
            return XCTFail("expected shell launch failure, got \(execution.terminalReason)")
        }
        XCTAssertTrue(message.contains(shell), "launch diagnostic omitted shell path: \(message)")
    }

    func testUnresolvableWorkingDirectoryReportsItsPath() async {
        let workingDirectory = "/definitely/missing/pinchos-directory"
        let runner = CommandRunner(
            command: "printf ok",
            timeout: 1,
            maxOutputBytes: 64,
            workingDirectory: workingDirectory
        )

        guard case .completed(let execution) = await runner.runIfIdle() else {
            return XCTFail("expected a completed launch failure")
        }
        guard case .launchFailed(let message) = execution.terminalReason else {
            return XCTFail("expected working-directory launch failure, got \(execution.terminalReason)")
        }
        XCTAssertTrue(message.contains(workingDirectory), "launch diagnostic omitted working directory: \(message)")
    }

    func testInvalidConfiguredEnvironmentNameReportsDiagnostic() async {
        let runner = CommandRunner(
            command: "printf ok",
            timeout: 1,
            maxOutputBytes: 64,
            environment: ["BAD-NAME": "value"]
        )

        guard case .completed(let execution) = await runner.runIfIdle() else {
            return XCTFail("expected an environment launch failure")
        }
        guard case .launchFailed(let message) = execution.terminalReason else {
            return XCTFail("expected environment launch failure, got \(execution.terminalReason)")
        }
        XCTAssertTrue(message.contains("BAD-NAME"), "launch diagnostic omitted environment name: \(message)")
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

    func testExtremelyLargeTimeoutDoesNotTrapDuringTimerSetup() async {
        let runner = CommandRunner(command: "sleep 0.1", timeout: .greatestFiniteMagnitude, maxOutputBytes: 64)
        let outcome = await runner.runIfIdle()

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
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
        let runner = CommandRunner(command: command, timeout: 0.8, maxOutputBytes: 64)

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

    func testCancellationKillsForegroundCommandBeforeItsTimeout() async throws {
        let pidURL = temporaryURL("cancel-foreground-pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let runner = CommandRunner(
            command: "printf '%s' \"$$\" > '\(pidURL.path)'; exec sleep 30",
            timeout: 30,
            maxOutputBytes: 64
        )
        let startedAt = Date()
        let task = Task { await runner.runIfIdle() }
        let processID = try await waitForPID(at: pidURL)
        XCTAssertEqual(kill(processID, 0), 0)

        await runner.cancelActive()
        let outcome = await task.value

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed cancellation, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
    }

    func testRapidGroupReuseDuringCancellationLeavesNoLingeringRuns() async throws {
        let childPIDURL = temporaryURL("stress-cancel-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        let command = "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait \"$child\""
        let lingeringRunner = CommandRunner(command: command, timeout: 30, maxOutputBytes: 64)
        let lingeringTask = Task { await lingeringRunner.runIfIdle() }
        let childPID = try await waitForPID(at: childPIDURL)
        let fastRunners = (0..<12).map { _ in
            CommandRunner(command: "printf ok", timeout: 2, maxOutputBytes: 64)
        }
        let fastRuns = Task {
            await withTaskGroup(of: CommandRunOutcome.self, returning: [CommandRunOutcome].self) { group in
                for runner in fastRunners {
                    group.addTask { await runner.runIfIdle() }
                }
                var outcomes = [CommandRunOutcome]()
                for await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }
        }

        await lingeringRunner.cancelActive()
        let lingeringOutcome = await lingeringTask.value
        let fastOutcomes = await fastRuns.value

        guard case .completed(let execution) = lingeringOutcome else {
            return XCTFail("expected a completed cancellation, got \(lingeringOutcome)")
        }
        XCTAssertEqual(execution.terminalReason, .cancelled)
        XCTAssertEqual(fastOutcomes.count, fastRunners.count)
        for outcome in fastOutcomes {
            guard case .completed(let execution) = outcome else {
                return XCTFail("expected every stress run to complete, got \(outcome)")
            }
            XCTAssertEqual(execution.terminalReason, .exited(code: 0))
            XCTAssertEqual(execution.stdout, "ok")
        }
        XCTAssertTrue(waitUntilGone(childPID), "stress cancellation left child process \(childPID) alive")
        let snapshot = await lingeringRunner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
    }

    func testCancelActiveCompletesWhenFinishActiveRunRacesTeardown() async throws {
        let childPIDURL = temporaryURL("cancel-race-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        let command = "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait \"$child\""
        let runner = CommandRunner(command: command, timeout: 30, maxOutputBytes: 64)

        let runTask = Task { await runner.runIfIdle() }
        let childPID = try await waitForPID(at: childPIDURL)
        let cancellationTask = Task { await runner.cancelActive() }
        let outcome = await runTask.value
        await cancellationTask.value

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed cancellation, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .cancelled)
        XCTAssertTrue(waitUntilGone(childPID), "teardown left child process \(childPID) alive")
        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
    }

    func testTimeoutDoesNotWaitForDetachedPipeHolder() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
        let childPIDURL = temporaryURL("detached-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        var childPID: Int32?
        defer {
            if let childPID {
                _ = kill(childPID, SIGKILL)
                _ = waitUntilGone(childPID)
            }
        }

        let command = "/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); print qq(escaped\\n); sleep 30' & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait \"$child\""
        let runner = CommandRunner(command: command, timeout: 0.2, maxOutputBytes: 64)
        let startedAt = Date()
        let task = Task { await runner.runIfIdle() }
        childPID = try await waitForPID(at: childPIDURL)
        let outcome = await task.value

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testNormalExitRetainsBackgroundProcessGroupUntilCancellation() async throws {
        let childPIDURL = temporaryURL("natural-exit-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        var childPID: Int32?
        defer {
            if let childPID {
                _ = kill(childPID, SIGKILL)
                _ = waitUntilGone(childPID)
            }
        }

        let command = "(trap '' TERM; while :; do printf x; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; exit 0"
        let runner = CommandRunner(command: command, timeout: 5, maxOutputBytes: 64)
        let outcome = await runner.runIfIdle()

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        let child = try await waitForPID(at: childPIDURL)
        childPID = child
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        let activeSnapshot = await runner.snapshot()
        XCTAssertTrue(activeSnapshot.isRunning)
        XCTAssertNotEqual(kill(child, 0), -1)

        await runner.cancelActive()

        XCTAssertTrue(waitUntilGone(child), "cancellation left natural-exit child process \(child) alive")
        let finalSnapshot = await runner.snapshot()
        XCTAssertFalse(finalSnapshot.isRunning)
    }

    func testNaturalExitBackgroundProcessHonorsTimeout() async throws {
        let childPIDURL = temporaryURL("natural-timeout-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        var childPID: Int32?
        defer {
            if let childPID {
                _ = kill(childPID, SIGKILL)
                _ = waitUntilGone(childPID)
            }
        }

        let command = "(trap '' TERM; while :; do printf x; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; exit 0"
        let runner = CommandRunner(command: command, timeout: 0.2, maxOutputBytes: 64)
        let outcome = await runner.runIfIdle()
        let child = try await waitForPID(at: childPIDURL)
        childPID = child

        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        let activeSnapshot = await runner.snapshot()
        XCTAssertTrue(activeSnapshot.isRunning)

        try await Task.sleep(nanoseconds: 1_400_000_000)

        XCTAssertTrue(waitUntilGone(child), "timeout left natural-exit child process \(child) alive")
        let finalSnapshot = await runner.snapshot()
        XCTAssertFalse(finalSnapshot.isRunning)
    }

    func testNaturalExitDescendantFinishingDuringDrainGraceDoesNotStayActive() async throws {
        let childPIDURL = temporaryURL("natural-grace-child")
        defer { try? FileManager.default.removeItem(at: childPIDURL) }
        let command = "(sleep 0.05) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; exit 0"
        let runner = CommandRunner(command: command, timeout: 1, maxOutputBytes: 64)

        let outcome = await runner.runIfIdle()
        let child = try await waitForPID(at: childPIDURL)
        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        XCTAssertTrue(waitUntilGone(child))
        let finalSnapshot = await waitForRunnerIdle(runner)
        XCTAssertFalse(finalSnapshot.isRunning, "runner still reported running after its descendant exited")

        try await Task.sleep(nanoseconds: 1_200_000_000)
        guard case .completed(let rerun) = await runner.runIfIdle() else {
            return XCTFail("expected a subsequent run after a grace-period descendant exit")
        }
        XCTAssertEqual(rerun.terminalReason, .exited(code: 0))
    }

    func testNaturalExitRetainsLateStderrForLastExecution() async throws {
        let runner = CommandRunner(
            command: "(sleep 0.5; printf 'late-diagnostic\\n' >&2) & exit 0",
            timeout: 2,
            maxOutputBytes: 64
        )

        let outcome = await runner.runIfIdle()
        guard case .completed(let execution) = outcome else {
            return XCTFail("expected a completed execution, got \(outcome)")
        }
        XCTAssertEqual(execution.terminalReason, .exited(code: 0))
        let activeSnapshot = await runner.snapshot()
        XCTAssertTrue(activeSnapshot.isRunning)

        try await Task.sleep(nanoseconds: 800_000_000)

        let snapshot = await runner.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.lastExecution?.stderr, "late-diagnostic\n")
    }

    func testCancellationDoesNotSignalARecycledProcessGroupAfterSessionOwnershipEnds() {
        let signalBackend = FakeSignalBackend()
        let originalTarget = FakeSignalTarget()
        let original = FakeProcessSession(
            numericGroupID: 71,
            signalBackend: signalBackend,
            signalTarget: originalTarget,
            isOwned: true,
            hasDescendants: true
        )
        original.release()

        let unrelatedTarget = FakeSignalTarget()
        let unrelated = FakeProcessSession(
            numericGroupID: original.numericGroupID,
            signalBackend: signalBackend,
            signalTarget: unrelatedTarget,
            isOwned: true,
            hasDescendants: true
        )
        let controller = ProcessGroupController(session: original)

        _ = controller.beginTermination(.cancelled)

        XCTAssertEqual(original.numericGroupID, unrelated.numericGroupID)
        XCTAssertTrue(signalBackend.target(for: original.numericGroupID) === unrelatedTarget)
        XCTAssertEqual(original.terminationRequestCount, 0)
        XCTAssertEqual(unrelated.terminationRequestCount, 0)
        XCTAssertEqual(originalTarget.signalCount, 0)
        XCTAssertEqual(unrelatedTarget.signalCount, 0)
    }

    func testOwnedProcessSessionReceivesOneTerminationSequenceForRepeatedClaims() {
        let session = FakeProcessSession(isOwned: true, hasDescendants: true)
        let controller = ProcessGroupController(session: session)

        _ = controller.beginTermination(.cancelled)
        _ = controller.beginTermination(.timedOut)
        controller.requestGroupTermination()

        XCTAssertEqual(session.terminationRequestCount, 1)
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

    /// `CommandRunnerSnapshot.isRunning` only clears once the process-session
    /// supervisor observes the process group is empty. That observation is a
    /// polling loop (see `ProcessSessionSpawner.supervisorScript`) that forks
    /// `ps`/`awk` on a fixed interval, so it can lag noticeably behind the
    /// descendant actually exiting under CI load. Poll for idle instead of
    /// asserting immediately after the descendant is confirmed gone.
    private func waitForRunnerIdle(_ runner: CommandRunner, timeout: TimeInterval = 5) async -> CommandRunnerSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var snapshot = await runner.snapshot()
        while snapshot.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            snapshot = await runner.snapshot()
        }
        return snapshot
    }
}

private final class FakeSignalTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var signalCountStorage = 0

    var signalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return signalCountStorage
    }

    func receiveSignal() {
        lock.lock()
        signalCountStorage += 1
        lock.unlock()
    }
}

private final class FakeSignalBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var targets = [pid_t: FakeSignalTarget]()

    func register(groupID: pid_t, target: FakeSignalTarget) {
        lock.lock()
        targets[groupID] = target
        lock.unlock()
    }

    func unregister(groupID: pid_t, target: FakeSignalTarget) {
        lock.lock()
        if targets[groupID] === target {
            targets[groupID] = nil
        }
        lock.unlock()
    }

    func target(for groupID: pid_t) -> FakeSignalTarget? {
        lock.lock()
        defer { lock.unlock() }
        return targets[groupID]
    }

    func signal(groupID: pid_t) {
        target(for: groupID)?.receiveSignal()
    }
}

private final class FakeProcessSession: ProcessSessionIdentity, @unchecked Sendable {
    let numericGroupID: pid_t
    private let signalBackend: FakeSignalBackend
    private let signalTarget: FakeSignalTarget
    var isOwned: Bool
    var hasDescendants: Bool
    private(set) var terminationRequestCount = 0

    init(
        numericGroupID: pid_t = 0,
        signalBackend: FakeSignalBackend = FakeSignalBackend(),
        signalTarget: FakeSignalTarget = FakeSignalTarget(),
        isOwned: Bool,
        hasDescendants: Bool
    ) {
        self.numericGroupID = numericGroupID
        self.signalBackend = signalBackend
        self.signalTarget = signalTarget
        self.isOwned = isOwned
        self.hasDescendants = hasDescendants
        signalBackend.register(groupID: numericGroupID, target: signalTarget)
    }

    func requestTermination() {
        terminationRequestCount += 1
        signalBackend.signal(groupID: numericGroupID)
    }

    func commandDidExit() {}

    func release() {
        isOwned = false
        hasDescendants = false
        signalBackend.unregister(groupID: numericGroupID, target: signalTarget)
    }

    func waitForExit() async {}
}
