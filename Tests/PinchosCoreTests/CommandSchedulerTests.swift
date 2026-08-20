import XCTest
@testable import PinchosCore

final class CommandSchedulerTests: XCTestCase {
    func testAcquirePermitGrantsImmediatelyUpToTheLimit() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 2, clock: ManualSchedulerClock())
        try await scheduler.acquirePermit()
        try await scheduler.acquirePermit()

        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 2)
        XCTAssertEqual(diagnostics.queuedSessions, 0)
        XCTAssertEqual(diagnostics.delayedAcquisitions, 0)
    }

    func testThirdAcquireQueuesUntilAPermitIsReleased() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 1, clock: ManualSchedulerClock())
        try await scheduler.acquirePermit()

        let grantedThirdPermit = expectation(description: "third permit granted")
        let waiterTask = Task {
            try await scheduler.acquirePermit()
            grantedThirdPermit.fulfill()
        }

        try await Task.sleep(for: .milliseconds(50))
        var diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 1)
        XCTAssertEqual(diagnostics.queuedSessions, 1)
        XCTAssertEqual(diagnostics.delayedAcquisitions, 1)

        await scheduler.releasePermit()
        await fulfillment(of: [grantedThirdPermit], timeout: 2)
        diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 1)
        XCTAssertEqual(diagnostics.queuedSessions, 0)

        await scheduler.releasePermit()
        waiterTask.cancel()
    }

    func testWaitersAreGrantedInFIFOOrderNotLastRequestedFirst() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()

        actor Order {
            var sequence: [Int] = []
            func record(_ value: Int) { sequence.append(value) }
        }
        let order = Order()

        var tasks: [Task<Void, Never>] = []
        for index in 1...3 {
            try await Task.sleep(for: .milliseconds(5))
            tasks.append(Task {
                try? await scheduler.acquirePermit()
                await order.record(index)
            })
        }

        try await Task.sleep(for: .milliseconds(50))
        await scheduler.releasePermit()
        try await Task.sleep(for: .milliseconds(30))
        await scheduler.releasePermit()
        try await Task.sleep(for: .milliseconds(30))
        await scheduler.releasePermit()
        try await Task.sleep(for: .milliseconds(30))

        let recorded = await order.sequence
        XCTAssertEqual(recorded, [1, 2, 3])
        for task in tasks { task.cancel() }
    }

    func testCancellingAQueuedAcquireDoesNotConsumeAPermitOrWedgeTheQueue() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()

        let waiterStarted = expectation(description: "second waiter started")
        let secondGranted = expectation(description: "second waiter granted after cancellation of first")
        let firstWaiter = Task {
            waiterStarted.fulfill()
            try await scheduler.acquirePermit()
        }
        try await Task.sleep(for: .milliseconds(20))
        let secondWaiter = Task {
            try await scheduler.acquirePermit()
            secondGranted.fulfill()
        }
        await fulfillment(of: [waiterStarted], timeout: 1)
        try await Task.sleep(for: .milliseconds(20))

        firstWaiter.cancel()
        await scheduler.releasePermit()

        await fulfillment(of: [secondGranted], timeout: 2)
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 1)
        XCTAssertEqual(diagnostics.queuedSessions, 0)

        await scheduler.releasePermit()
        secondWaiter.cancel()
    }

    func testRaisingTheLimitAtRuntimeAdmitsQueuedWaitersImmediately() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()

        let granted = expectation(description: "waiter granted after limit raised")
        let waiter = Task {
            try await scheduler.acquirePermit()
            granted.fulfill()
        }
        try await Task.sleep(for: .milliseconds(30))
        var diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.queuedSessions, 1)

        await scheduler.updateMaxActiveSessions(2)
        await fulfillment(of: [granted], timeout: 2)
        diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 2)
        XCTAssertEqual(diagnostics.queuedSessions, 0)

        await scheduler.releasePermit()
        await scheduler.releasePermit()
        waiter.cancel()
    }

    func testLoweringTheLimitDoesNotForciblyRevokeAlreadyActivePermits() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 3)
        try await scheduler.acquirePermit()
        try await scheduler.acquirePermit()
        try await scheduler.acquirePermit()

        await scheduler.updateMaxActiveSessions(1)
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 3, "already-granted permits must not be revoked")
        XCTAssertEqual(diagnostics.maxActiveSessions, 1)

        await scheduler.releasePermit()
        await scheduler.releasePermit()
        await scheduler.releasePermit()
    }

    func testConstructorClampsOutOfRangeLimitsToTheAllowedRange() async throws {
        let tooLow = CommandScheduler(maxActiveSessions: 0)
        let tooHigh = CommandScheduler(maxActiveSessions: 1000)
        let lowDiagnostics = await tooLow.diagnostics()
        let highDiagnostics = await tooHigh.diagnostics()
        XCTAssertEqual(lowDiagnostics.maxActiveSessions, CommandScheduler.allowedMaxActiveSessionsRange.lowerBound)
        XCTAssertEqual(highDiagnostics.maxActiveSessions, CommandScheduler.allowedMaxActiveSessionsRange.upperBound)
    }

    func testRecordCoalescedIncrementsTheDiagnosticCounterOnly() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 4)
        await scheduler.recordCoalesced()
        await scheduler.recordCoalesced()
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.coalescedCount, 2)
        XCTAssertEqual(diagnostics.activeSessions, 0)
    }

    // MARK: - Shared timing

    func testRecurringRegistrationFiresRepeatedlyAtTheConfiguredInterval() async throws {
        let clock = ManualSchedulerClock()
        let scheduler = CommandScheduler(clock: clock)
        actor FireCount {
            var count = 0
            func increment() { count += 1 }
        }
        let fires = FireCount()
        let token = CommandScheduler.ItemToken()
        await scheduler.registerRecurring(token: token, interval: 1) {
            Task { await fires.increment() }
        }

        clock.advance(by: .seconds(1))
        try await waitUntil { await fires.count == 1 }
        clock.advance(by: .seconds(1))
        try await waitUntil { await fires.count == 2 }
        clock.advance(by: .seconds(1))
        try await waitUntil { await fires.count == 3 }

        await scheduler.cancelTimer(token)
    }

    func testCancellingATimerStopsFurtherFiring() async throws {
        let clock = ManualSchedulerClock()
        let scheduler = CommandScheduler(clock: clock)
        actor FireCount {
            var count = 0
            func increment() { count += 1 }
        }
        let fires = FireCount()
        let token = CommandScheduler.ItemToken()
        await scheduler.registerRecurring(token: token, interval: 1) {
            Task { await fires.increment() }
        }
        clock.advance(by: .seconds(1))
        try await waitUntil { await fires.count == 1 }

        await scheduler.cancelTimer(token)
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        let finalCount = await fires.count
        XCTAssertEqual(finalCount, 1)
    }

    func testSleepingPastMultipleIntervalsFiresOnceNotOncePerMissedInterval() async throws {
        let clock = ManualSchedulerClock()
        let scheduler = CommandScheduler(clock: clock)
        actor FireCount {
            var count = 0
            func increment() { count += 1 }
        }
        let fires = FireCount()
        let token = CommandScheduler.ItemToken()
        await scheduler.registerRecurring(token: token, interval: 1) {
            Task { await fires.increment() }
        }

        // Simulate the system sleeping through five missed 1-second intervals
        // in one jump; this must fire exactly once when it wakes, not five
        // times ("replay every missed interval" is an explicit non-goal).
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        let count = await fires.count
        XCTAssertEqual(count, 1, "waking past several missed intervals must fire once, not replay each one")

        await scheduler.cancelTimer(token)
    }

    func testManyRecurringRegistrationsShareOneDriverAndAllFireOnTheSameDeadline() async throws {
        let clock = ManualSchedulerClock()
        let scheduler = CommandScheduler(clock: clock)
        actor FireCount {
            var count = 0
            func increment() { count += 1 }
        }
        let fires = FireCount()
        // `initialDelay: 1` (rather than the immediate-first-fire default) keeps
        // every registration's first deadline at the same future instant instead
        // of "now", so all 25 can be registered before any of them are due -
        // otherwise the driver could legitimately fire the first few
        // registrations before the loop below finishes registering the rest.
        var tokens: [CommandScheduler.ItemToken] = []
        for _ in 0..<25 {
            let token = CommandScheduler.ItemToken()
            tokens.append(token)
            await scheduler.registerRecurring(token: token, interval: 1, initialDelay: 1) {
                Task { await fires.increment() }
            }
        }

        clock.advance(by: .seconds(1))
        try await waitUntil { await fires.count == 25 }

        for token in tokens {
            await scheduler.cancelTimer(token)
        }
    }

    // MARK: - Fairness / bounded-queue integration

    func testPeakActiveSessionsNeverExceedsTheConfiguredLimitUnderManyConcurrentRequests() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 3)
        actor PeakTracker {
            private var current = 0
            private(set) var peak = 0
            func enter() {
                current += 1
                peak = max(peak, current)
            }
            func leave() { current -= 1 }
        }
        let tracker = PeakTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    try await scheduler.acquirePermit()
                    await tracker.enter()
                    try await Task.sleep(for: .milliseconds(15))
                    await tracker.leave()
                    await scheduler.releasePermit()
                }
            }
            try await group.waitForAll()
        }

        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 3)
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 0)
        XCTAssertEqual(diagnostics.queuedSessions, 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not become true within \(timeout)s")
    }
}
