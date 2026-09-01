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

    init(outcomes: [CommandRunOutcome], delay: Duration = .zero) {
        self.outcomes = outcomes
        self.delay = delay
    }

    func runIfIdle() async -> CommandRunOutcome {
        runCount += 1
        activeRuns += 1
        maxActiveRuns = max(maxActiveRuns, activeRuns)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        activeRuns -= 1
        let outcome = outcomes.isEmpty ? .skipped : outcomes.removeFirst()
        if case .completed(let execution) = outcome {
            lastExecution = execution
        }
        return outcome
    }

    func awaitSettledExecution() async -> CommandExecution? { lastExecution }

    func cancelActive() async {}

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
        delay: Duration = .zero
    ) -> (CommandSource, FakeSourceRunner, TestSourceClock) {
        let runner = FakeSourceRunner(outcomes: outcomes, delay: delay)
        let source = CommandSource(
            configuration: CommandSourceConfiguration(
                command: "ignored",
                timeout: 1,
                maxOutputBytes: 1024,
                staleAfter: staleAfter
            ),
            scheduler: CommandScheduler(maxActiveSessions: 1),
            clock: clock,
            runner: runner
        )
        return (source, runner, clock)
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
}
