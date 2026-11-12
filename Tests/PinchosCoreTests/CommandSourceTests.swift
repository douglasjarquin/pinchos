import Foundation
import XCTest
@testable import PinchosCore

private actor FakeSourceRunner: CommandSourceRunner {
    private var outcomes: [CommandRunOutcome]
    private var lastExecution: CommandExecution?
    private(set) var runCount = 0
    private(set) var activeRuns = 0
    private(set) var maxActiveRuns = 0
    private let delay: Duration
    private let holdUntilReleased: Bool
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        outcomes: [CommandRunOutcome],
        delay: Duration = .zero,
        holdUntilReleased: Bool = false
    ) {
        self.outcomes = outcomes
        self.delay = delay
        self.holdUntilReleased = holdUntilReleased
    }

    func runIfIdle() async -> CommandRunOutcome {
        runCount += 1
        activeRuns += 1
        maxActiveRuns = max(maxActiveRuns, activeRuns)
        let started = startedWaiters
        startedWaiters.removeAll()
        for waiter in started {
            waiter.resume()
        }
        if holdUntilReleased {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseWaiters.append(continuation)
            }
        } else if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        activeRuns -= 1
        let outcome = outcomes.isEmpty ? .skipped : outcomes.removeFirst()
        if case .completed(let execution) = outcome {
            lastExecution = execution
        }
        return outcome
    }

    func waitUntilRunStarts() async {
        if activeRuns > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func awaitSettledExecution() async -> CommandExecution? { lastExecution }

    func cancelActive() async {
        release()
    }

    func snapshot() async -> CommandRunnerSnapshot {
        CommandRunnerSnapshot(isRunning: activeRuns > 0, lastExecution: lastExecution, skippedRefreshes: 0)
    }
}

private final class TestSourceClock: CommandSourceClock, @unchecked Sendable {
    var date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date { date }
}

final class CommandSourceTests: XCTestCase {
    private let success = CommandExecution(
        terminalReason: .exited(code: 0),
        stdout: "72%\n",
        stderr: "",
        stdoutBytesRead: 4,
        stderrBytesRead: 0,
        stdoutTruncated: false,
        stderrTruncated: false,
        duration: 0.1
    )

    private let failure = CommandExecution(
        terminalReason: .exited(code: 7),
        stdout: "new value\n",
        stderr: "backend unavailable\n",
        stdoutBytesRead: 11,
        stderrBytesRead: 20,
        stdoutTruncated: false,
        stderrTruncated: false,
        duration: 0.2
    )

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            try await Task.sleep(for: .milliseconds(10))
            if ContinuousClock.now >= deadline {
                throw NSError(domain: "CommandSourceTests", code: 1)
            }
        }
    }

    private func source(
        outcomes: [CommandRunOutcome],
        clock: TestSourceClock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000)),
        staleAfter: TimeInterval? = nil,
        delay: Duration = .zero,
        holdUntilReleased: Bool = false,
        refreshPolicy: CommandSourceRefreshPolicy = .manual
    ) -> (CommandSource, FakeSourceRunner, TestSourceClock) {
        let runner = FakeSourceRunner(
            outcomes: outcomes,
            delay: delay,
            holdUntilReleased: holdUntilReleased
        )
        let source = CommandSource(
            configuration: CommandSourceConfiguration(
                command: "ignored",
                timeout: 1,
                maxOutputBytes: 1024,
                refreshPolicy: refreshPolicy,
                staleAfter: staleAfter
            ),
            scheduler: CommandScheduler(maxActiveSessions: 1),
            clock: clock,
            runner: runner
        )
        return (source, runner, clock)
    }

    private func execution(_ stdout: String, code: Int32 = 0, stderr: String = "") -> CommandExecution {
        CommandExecution(
            terminalReason: .exited(code: code),
            stdout: stdout,
            stderr: stderr,
            stdoutBytesRead: stdout.utf8.count,
            stderrBytesRead: stderr.utf8.count,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.1
        )
    }

    func testCancellingWhileWaitingForPermitDoesNotLaunchQueuedSource() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()
        let runner = FakeSourceRunner(outcomes: [.completed(success)])
        let source = CommandSource(
            configuration: CommandSourceConfiguration(command: "ignored", timeout: 1),
            scheduler: scheduler,
            runner: runner
        )

        let refresh = Task { await source.refresh() }
        try await waitUntil {
            await scheduler.diagnostics().queuedSessions == 1
        }

        await source.cancel()
        await scheduler.releasePermit()
        _ = await refresh.value

        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 0)
        XCTAssertEqual(diagnostics.queuedSessions, 0)
    }

    func testCancellingLastRefreshJoinerAbortsQueuedPermitAndDoesNotRun() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()
        let runner = FakeSourceRunner(outcomes: [.completed(success)])
        let source = CommandSource(
            configuration: CommandSourceConfiguration(command: "ignored", timeout: 1),
            scheduler: scheduler,
            runner: runner
        )

        let refresh = Task { await source.refresh() }
        try await waitUntil { await scheduler.diagnostics().queuedSessions == 1 }
        refresh.cancel()
        _ = await refresh.value
        await scheduler.releasePermit()
        try await Task.sleep(for: .milliseconds(50))

        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.queuedSessions, 0)
        XCTAssertEqual(diagnostics.activeSessions, 0)
    }

    func testCancellingOneJoinerLeavesSharedRefreshRunning() async throws {
        let (source, runner, _) = source(
            outcomes: [.completed(success)],
            holdUntilReleased: true
        )

        let first = Task { await source.refresh() }
        await runner.waitUntilRunStarts()
        let second = Task { await source.refresh() }
        first.cancel()
        _ = await first.value
        let runCountWhileHeld = await runner.runCount
        XCTAssertEqual(runCountWhileHeld, 1)
        await runner.release()
        let secondValue = await second.value
        let runCount = await runner.runCount
        XCTAssertEqual(secondValue.value, "72%\n")
        XCTAssertEqual(runCount, 1)
    }

    func testCancellingLastJoinerAfterRunnerStartsStillRecordsResult() async throws {
        let (source, runner, _) = source(
            outcomes: [.completed(success)],
            holdUntilReleased: true
        )

        let refresh = Task { await source.refresh() }
        await runner.waitUntilRunStarts()
        refresh.cancel()
        let cancelled = await refresh.value
        XCTAssertEqual(cancelled.state, .refreshing)

        await runner.release()
        try await waitUntil { await source.snapshot().state == .fresh }
        let cached = await source.snapshot()
        let runCount = await runner.runCount
        XCTAssertEqual(cached.value, "72%\n")
        XCTAssertEqual(cached.state, .fresh)
        XCTAssertEqual(runCount, 1)
    }

    func testRefreshJoinsCancelledFlightThatAlreadyStartedTheRunner() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 2)
        let runner = FakeSourceRunner(
            outcomes: [.completed(success), .completed(execution("second\n"))],
            holdUntilReleased: true
        )
        let source = CommandSource(
            configuration: CommandSourceConfiguration(command: "ignored", timeout: 1),
            scheduler: scheduler,
            runner: runner
        )

        let first = Task { await source.refresh() }
        await runner.waitUntilRunStarts()
        first.cancel()
        _ = await first.value

        let second = Task { await source.refresh() }
        try await waitUntil {
            await scheduler.diagnostics().activeSessions >= 1
        }
        try await Task.sleep(for: .milliseconds(50))
        let diagnostics = await scheduler.diagnostics()
        let runCountWhileHeld = await runner.runCount
        let maxActiveRuns = await runner.maxActiveRuns
        XCTAssertEqual(diagnostics.activeSessions, 1, "a second flight took another permit")
        XCTAssertEqual(runCountWhileHeld, 1)
        XCTAssertEqual(maxActiveRuns, 1)

        await runner.release()
        let secondValue = await second.value
        let runCount = await runner.runCount
        XCTAssertEqual(secondValue.value, "72%\n")
        XCTAssertEqual(secondValue.state, .fresh)
        XCTAssertEqual(runCount, 1)
        let diagnosticsAfter = await scheduler.diagnostics()
        XCTAssertEqual(diagnosticsAfter.activeSessions, 0)
    }

    func testCancellingLastJoinerWhileDescendantLingersNeitherSpinsNorDropsResult() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-linger-\(UUID().uuidString)")
        let command = "(sleep 0.8; printf late) & printf '%s' \"$!\" > '\(pidFile.path)'; exit 0"
        let runner = CommandRunner(command: command, timeout: 5)
        let source = CommandSource(
            configuration: CommandSourceConfiguration(command: command, timeout: 5),
            scheduler: CommandScheduler(maxActiveSessions: 1),
            runner: runner
        )
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidFile)
        }

        let refresh = Task { await source.refresh() }
        try await waitUntil {
            let snapshot = await runner.snapshot()
            return snapshot.isRunning && snapshot.lastExecution?.terminalReason == .exited(code: 0)
        }
        refresh.cancel()
        let cancelled = await refresh.value
        XCTAssertEqual(cancelled.state, .refreshing)

        let cpuBefore = processCPUSeconds()
        try await Task.sleep(for: .milliseconds(200))
        let cpuDelta = processCPUSeconds() - cpuBefore
        XCTAssertLessThan(cpuDelta, 0.15, "lingering settlement busy-spun after the last joiner cancelled")

        try await waitUntil { await source.snapshot().state == .fresh }
        let cached = await source.snapshot()
        XCTAssertEqual(cached.value, "late")
        XCTAssertEqual(cached.state, .fresh)
    }

    func testRefreshPublishesBoundedCachedValueAndTerminalState() async {
        let (source, _, _) = source(outcomes: [.completed(success)])

        let value = await source.refresh()

        XCTAssertEqual(value.value, "72%\n")
        XCTAssertEqual(value.state, .fresh)
        XCTAssertEqual(value.lastExecution, success)
        XCTAssertNil(value.diagnostic)
    }

    func testFailureRetainsLastSuccessfulValueAndExposesDiagnostic() async {
        let (source, _, _) = source(outcomes: [.completed(success), .completed(failure)])

        _ = await source.refresh()
        let failed = await source.refresh()

        XCTAssertEqual(failed.value, "72%\n")
        XCTAssertEqual(failed.state, .error)
        XCTAssertEqual(failed.lastExecution, failure)
        XCTAssertEqual(failed.diagnostic, "backend unavailable")
    }

    func testFirstRunFailureDoesNotFabricateAValue() async {
        let (source, _, _) = source(outcomes: [.completed(failure)])

        let value = await source.refresh()

        XCTAssertNil(value.value)
        XCTAssertEqual(value.state, .error)
        XCTAssertEqual(value.diagnostic, "backend unavailable")
    }

    func testSourceDoesNotOverlapItsOwnExecution() async {
        let (source, runner, _) = source(
            outcomes: [.completed(success)],
            delay: .milliseconds(50)
        )

        let first = Task { await source.refresh() }
        try? await Task.sleep(for: .milliseconds(5))
        let duringRefresh = await source.refresh()
        _ = await first.value
        let maxActiveRuns = await runner.maxActiveRuns

        XCTAssertEqual(duringRefresh.state, .fresh)
        XCTAssertEqual(maxActiveRuns, 1)
    }

    func testSuccessfulValueBecomesStaleAccordingToClock() async {
        let clock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (source, _, _) = source(outcomes: [.completed(success)], clock: clock, staleAfter: 60)

        _ = await source.refresh()
        clock.date = clock.date.addingTimeInterval(61)

        let value = await source.snapshot()

        XCTAssertEqual(value.value, "72%\n")
        XCTAssertEqual(value.state, .stale)
    }

    func testRegistrySharesExecutionIdentityAndReleasesLastConsumer() async {
        let registry = CommandSourceRegistry()
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        let configuration = CommandSourceConfiguration(
            command: "echo same",
            timeout: 1,
            maxOutputBytes: 1024,
            refreshPolicy: .scheduled(60)
        )
        let first = registry.acquire(configuration: configuration, scheduler: scheduler)
        let second = registry.acquire(
            configuration: CommandSourceConfiguration(
                command: "echo same",
                timeout: 1,
                maxOutputBytes: 1024,
                refreshPolicy: .manual
            ),
            scheduler: scheduler
        )

        XCTAssertTrue(first.source === second.source)
        XCTAssertEqual(registry.sourceCount, 1)
        XCTAssertEqual(registry.consumerCount(for: CommandSourceIdentity(configuration: configuration)), 2)

        registry.release(first)
        XCTAssertEqual(registry.sourceCount, 1)
        registry.release(second)
        XCTAssertEqual(registry.sourceCount, 0)
    }

    func testReleasingOneConsumerDoesNotCancelSharedSource() async {
        let runner = FakeSourceRunner(
            outcomes: [.completed(success)],
            delay: .milliseconds(100)
        )
        let registry = CommandSourceRegistry()
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        let configuration = CommandSourceConfiguration(
            command: "echo shared",
            timeout: 1,
            maxOutputBytes: 1024
        )
        let first = registry.acquire(
            configuration: configuration,
            scheduler: scheduler,
            runner: runner
        )
        let second = registry.acquire(configuration: configuration, scheduler: scheduler)

        let refresh = Task { await first.source.refresh() }
        try? await Task.sleep(for: .milliseconds(10))
        await registry.releaseAndCancelIfLast(first)

        let activeRuns = await runner.activeRuns
        XCTAssertEqual(activeRuns, 1)
        _ = await refresh.value
        let cachedValue = await first.source.snapshot()
        XCTAssertEqual(cachedValue.state, .fresh)

        await registry.releaseAndCancelIfLast(second)
    }

    func testFreshValueIsNotAutomaticallyDue() async {
        let clock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (source, runner, _) = source(
            outcomes: [.completed(success)],
            clock: clock,
            staleAfter: 60
        )

        _ = await source.refresh()
        clock.date = clock.date.addingTimeInterval(10)
        let snapshot = await source.snapshot()
        let due = CommandSource.isAutomaticRefreshDue(snapshot: snapshot, now: clock.date)
        let runCount = await runner.runCount

        XCTAssertFalse(due)
        XCTAssertEqual(snapshot.state, .fresh)
        XCTAssertEqual(runCount, 1)
    }

    func testStaleValueIsDueOnlyAfterRetryInterval() async {
        let clock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (source, runner, _) = source(
            outcomes: [.completed(success), .completed(execution("stale-refresh\n"))],
            clock: clock,
            staleAfter: 10
        )

        _ = await source.refresh()
        clock.date = clock.date.addingTimeInterval(11)
        let stale = await source.snapshot()
        let dueBeforeCadence = CommandSource.isAutomaticRefreshDue(snapshot: stale, now: clock.date)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertFalse(dueBeforeCadence)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval - 11)
        let dueAfterCadence = CommandSource.isAutomaticRefreshDue(
            snapshot: await source.snapshot(),
            now: clock.date
        )
        XCTAssertTrue(dueAfterCadence)
        let refreshed = await source.refresh()
        let runCount = await runner.runCount

        XCTAssertEqual(refreshed.value, "stale-refresh\n")
        XCTAssertEqual(runCount, 2)
    }

    func testFailedWithValueDoesNotRetryUntilRetryIntervalElapses() async {
        let clock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (source, runner, _) = source(
            outcomes: [.completed(success), .completed(failure), .completed(execution("recovered\n"))],
            clock: clock,
            staleAfter: 60
        )

        _ = await source.refresh()
        clock.date = clock.date.addingTimeInterval(61)
        let failed = await source.refresh()
        XCTAssertEqual(failed.value, "72%\n")
        XCTAssertEqual(failed.state, .error)

        clock.date = clock.date.addingTimeInterval(1)
        let dueImmediately = CommandSource.isAutomaticRefreshDue(
            snapshot: await source.snapshot(),
            now: clock.date
        )
        XCTAssertFalse(dueImmediately)
        let runCountAfterIgnored = await runner.runCount
        XCTAssertEqual(runCountAfterIgnored, 2)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval)
        let dueAfterCadence = CommandSource.isAutomaticRefreshDue(
            snapshot: await source.snapshot(),
            now: clock.date
        )
        XCTAssertTrue(dueAfterCadence)
        let recovered = await source.refresh()
        let runCount = await runner.runCount
        XCTAssertEqual(recovered.value, "recovered\n")
        XCTAssertEqual(runCount, 3)
    }

    func testFailedWithoutValueRetriesAfterCadenceIncludingManual() async {
        let clock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (source, runner, _) = source(
            outcomes: [.completed(failure), .completed(success)],
            clock: clock
        )

        let failed = await source.refresh()
        let dueImmediately = CommandSource.isAutomaticRefreshDue(snapshot: failed, now: clock.date)
        XCTAssertNil(failed.value)
        XCTAssertEqual(failed.state, .error)
        XCTAssertFalse(dueImmediately)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval)
        let dueAfterCadence = CommandSource.isAutomaticRefreshDue(
            snapshot: await source.snapshot(),
            now: clock.date
        )
        XCTAssertTrue(dueAfterCadence)
        let recovered = await source.refresh()
        let runCount = await runner.runCount
        XCTAssertEqual(recovered.value, "72%\n")
        XCTAssertEqual(runCount, 2)
    }

    func testManualSuccessIsNotAutomaticallyDue() async {
        let clock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (source, runner, _) = source(
            outcomes: [.completed(success)],
            clock: clock
        )

        _ = await source.refresh()
        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval * 4)
        let due = CommandSource.isAutomaticRefreshDue(
            snapshot: await source.snapshot(),
            now: clock.date
        )
        XCTAssertFalse(due)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 1)
    }

    func testDuplicateConsumersJoinOneRefresh() async {
        let (source, runner, _) = source(
            outcomes: [.completed(success)],
            holdUntilReleased: true
        )

        let first = Task { await source.refresh() }
        await runner.waitUntilRunStarts()
        let second = Task { await source.refresh() }
        let third = Task { await source.refresh() }
        await runner.release()
        let firstValue = await first.value
        let secondValue = await second.value
        let thirdValue = await third.value
        let runCount = await runner.runCount
        let maxActiveRuns = await runner.maxActiveRuns

        XCTAssertEqual(Set([firstValue.value, secondValue.value, thirdValue.value]), ["72%\n"])
        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(maxActiveRuns, 1)
    }

    func testQueuedFailingRefreshIsNotDueUntilRetryIntervalAfterSettlement() async throws {
        let clock = TestSourceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()
        let runner = FakeSourceRunner(outcomes: [.completed(failure)])
        let source = CommandSource(
            configuration: CommandSourceConfiguration(
                command: "ignored",
                timeout: 1,
                maxOutputBytes: 1024
            ),
            scheduler: scheduler,
            clock: clock,
            runner: runner
        )

        let refresh = Task { await source.refresh() }
        try await waitUntil { await scheduler.diagnostics().queuedSessions == 1 }

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval + 5)
        await scheduler.releasePermit()
        let failed = await refresh.value
        let runCountAfterFailure = await runner.runCount
        XCTAssertEqual(failed.state, .error)
        XCTAssertEqual(runCountAfterFailure, 1)

        let dueOnCompletion = CommandSource.isAutomaticRefreshDue(snapshot: failed, now: clock.date)
        XCTAssertFalse(dueOnCompletion, "queueing plus run time must not elapse the retry gate")

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval - 1)
        let dueBeforeCadence = CommandSource.isAutomaticRefreshDue(
            snapshot: await source.snapshot(),
            now: clock.date
        )
        XCTAssertFalse(dueBeforeCadence)
        let runCountBeforeCadence = await runner.runCount
        XCTAssertEqual(runCountBeforeCadence, 1)

        clock.date = clock.date.addingTimeInterval(1)
        let dueAfterCadence = CommandSource.isAutomaticRefreshDue(
            snapshot: await source.snapshot(),
            now: clock.date
        )
        XCTAssertTrue(dueAfterCadence)
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
