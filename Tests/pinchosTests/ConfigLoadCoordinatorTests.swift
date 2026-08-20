import XCTest
@testable import PinchosCore
@testable import pinchos

/// Lets a test hold a loader call open until it explicitly opens the gate, so
/// completion order can be controlled deterministically instead of via sleeps.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor ResultRecorder {
    private(set) var outcomes: [ConfigLoadOutcome] = []

    func record(_ outcome: ConfigLoadOutcome) {
        outcomes.append(outcome)
    }
}

private actor InvocationLog {
    private(set) var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }
}

private func testConfig(_ name: String) -> PinchosConfig {
    PinchosConfig(items: [ItemConfig(name: name, run: "printf \(name)", interval: .manual)])
}

final class ConfigLoadCoordinatorTests: XCTestCase {
    private func config(_ name: String) -> PinchosConfig {
        testConfig(name)
    }

    func testSuccessfulLoadIsApplied() async throws {
        let recorder = ResultRecorder()
        let expected = config("a")
        let coordinator = ConfigLoadCoordinator(
            loader: { [expected] _ in .success(expected) },
            resultHandler: { outcome in await recorder.record(outcome) }
        )

        await coordinator.requestLoad(path: "/tmp/a.toml")

        let outcomes = try await waitForOutcomes(recorder, count: 1)
        XCTAssertEqual(outcomes, [.success(expected)])
    }

    func testMissingFileIsReportedAsMissingFile() async throws {
        let recorder = ResultRecorder()
        let coordinator = ConfigLoadCoordinator(
            loader: { _ in .missingFile },
            resultHandler: { outcome in await recorder.record(outcome) }
        )

        await coordinator.requestLoad(path: "/tmp/missing.toml")

        let outcomes = try await waitForOutcomes(recorder, count: 1)
        XCTAssertEqual(outcomes, [.missingFile])
    }

    /// If parse A starts first but parse B is requested later, only B's outcome is ever
    /// handed to the result handler -- A is discarded whether it would have succeeded
    /// or failed, and regardless of whether A or B's underlying load finishes "first".
    func testStaleSuccessIsDiscardedOnceNewerRequestArrives() async throws {
        let recorder = ResultRecorder()
        let gate = Gate()
        let coordinator = ConfigLoadCoordinator(
            loader: { [config = config("stale")] path in
                if path == "old" {
                    await gate.wait()
                    return .success(config)
                }
                return .success(testConfig("fresh"))
            },
            resultHandler: { outcome in await recorder.record(outcome) }
        )

        await coordinator.requestLoad(path: "old")
        // Give the first load a moment to enter the gate before superseding it.
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.requestLoad(path: "new")
        await gate.open()

        let outcomes = try await waitForOutcomes(recorder, count: 1)
        XCTAssertEqual(outcomes, [.success(config("fresh"))])
        let finalOutcomes = await recorder.outcomes
        XCTAssertEqual(finalOutcomes, [.success(config("fresh"))], "stale success must not be applied after the newer revision")
    }

    /// A stale parse error must never show a recovery warning over a newer valid config.
    func testStaleFailureIsDiscardedOnceNewerSuccessArrives() async throws {
        let recorder = ResultRecorder()
        let gate = Gate()
        let coordinator = ConfigLoadCoordinator(
            loader: { path in
                if path == "bad" {
                    await gate.wait()
                    return .parseFailure("stale error")
                }
                return .success(testConfig("good"))
            },
            resultHandler: { outcome in await recorder.record(outcome) }
        )

        await coordinator.requestLoad(path: "bad")
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.requestLoad(path: "good")
        await gate.open()

        let outcomes = try await waitForOutcomes(recorder, count: 1)
        XCTAssertEqual(outcomes, [.success(config("good"))])
        let finalOutcomes = await recorder.outcomes
        XCTAssertEqual(finalOutcomes, [.success(config("good"))], "stale failure must not clear the newer successful config")
    }

    /// A stale success must never resurrect obsolete items over the latest requested
    /// (invalid) revision's warning.
    func testStaleSuccessIsDiscardedOnceNewerFailureArrives() async throws {
        let recorder = ResultRecorder()
        let gate = Gate()
        let coordinator = ConfigLoadCoordinator(
            loader: { path in
                if path == "old-good" {
                    await gate.wait()
                    return .success(testConfig("obsolete"))
                }
                return .parseFailure("latest is broken")
            },
            resultHandler: { outcome in await recorder.record(outcome) }
        )

        await coordinator.requestLoad(path: "old-good")
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.requestLoad(path: "new-bad")
        await gate.open()

        let outcomes = try await waitForOutcomes(recorder, count: 1)
        XCTAssertEqual(outcomes, [.parseFailure("latest is broken")])
        let finalOutcomes = await recorder.outcomes
        XCTAssertEqual(finalOutcomes, [.parseFailure("latest is broken")], "stale success must not clear the newer failure warning")
    }

    /// A burst of reload requests received while a load is already in flight must
    /// coalesce into a single pending slot, not an unbounded backlog, and only the
    /// last one requested is ever actually parsed and applied.
    func testBurstOfRequestsWhileLoadingCoalescesToLatestOnly() async throws {
        let recorder = ResultRecorder()
        let invocations = InvocationLog()
        let gate = Gate()
        let coordinator = ConfigLoadCoordinator(
            loader: { path in
                await invocations.record(path)
                if path == "1" {
                    await gate.wait()
                }
                return .success(testConfig(path))
            },
            resultHandler: { outcome in await recorder.record(outcome) }
        )

        await coordinator.requestLoad(path: "1")
        for path in ["2", "3", "4", "5"] {
            await coordinator.requestLoad(path: path)
        }

        try await waitForInvocationCount(invocations, count: 1)
        let firstPaths = await invocations.paths
        XCTAssertEqual(firstPaths, ["1"], "no burst request should start loading while one is already in flight")

        await gate.open()

        let outcomes = try await waitForOutcomes(recorder, count: 1)
        XCTAssertEqual(outcomes, [.success(config("5"))], "only the latest coalesced request should ever be applied")
        let finalPaths = await invocations.paths
        XCTAssertEqual(finalPaths, ["1", "5"], "intermediate requests 2-4 must never trigger their own parse")
    }

    /// Beginning shutdown must prevent all later load results from applying, drop any
    /// pending coalesced request, and never accept further requests.
    func testShutdownDiscardsInFlightResultAndFuturePendingRequests() async throws {
        let recorder = ResultRecorder()
        let gate = Gate()
        let coordinator = ConfigLoadCoordinator(
            loader: { path in
                if path == "in-flight" {
                    await gate.wait()
                }
                return .success(testConfig(path))
            },
            resultHandler: { outcome in await recorder.record(outcome) }
        )

        await coordinator.requestLoad(path: "in-flight")
        await coordinator.requestLoad(path: "queued-before-shutdown")
        await coordinator.shutdown()
        await coordinator.requestLoad(path: "after-shutdown")

        await gate.open()
        try await Task.sleep(for: .milliseconds(50))

        let outcomes = await recorder.outcomes
        XCTAssertTrue(outcomes.isEmpty, "shutdown must discard the in-flight result and ignore all later requests")
        let applied = await coordinator.appliedCount
        XCTAssertEqual(applied, 0)
    }

    /// `requestLoad` must return as soon as it hands work off, without waiting for the
    /// loader itself -- the caller (e.g. the AppKit main actor) must stay responsive
    /// even while a slow parse is in flight.
    func testRequestLoadReturnsWithoutWaitingForSlowLoader() async throws {
        let gate = Gate()
        let coordinator = ConfigLoadCoordinator(
            loader: { _ in
                await gate.wait()
                return .missingFile
            },
            resultHandler: { _ in }
        )
        let start = Date()
        await coordinator.requestLoad(path: "slow")
        let elapsed = Date().timeIntervalSince(start)
        await gate.open()

        XCTAssertLessThan(elapsed, 1.0, "requestLoad must not block on the loader completing")
    }

    private func waitForOutcomes(
        _ recorder: ResultRecorder,
        count: Int,
        timeout: TimeInterval = 2
    ) async throws -> [ConfigLoadOutcome] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let outcomes = await recorder.outcomes
            if outcomes.count >= count {
                return outcomes
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "ConfigLoadCoordinatorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(count) applied outcome(s)"]
        )
    }

    private func waitForInvocationCount(
        _ log: InvocationLog,
        count: Int,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await log.paths.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "ConfigLoadCoordinatorTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(count) loader invocation(s)"]
        )
    }
}
