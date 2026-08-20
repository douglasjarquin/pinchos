import XCTest
@testable import pinchos

/// Deterministic proofs for issue #54's core primitive: firing many
/// cancellation operations concurrently and bounding the wait by one shared,
/// monotonic deadline instead of summing each operation's own settle time.
@MainActor
final class LifecycleSettlementTests: XCTestCase {
    private actor Recorder {
        private(set) var startTimestamps: [String: ContinuousClock.Instant] = [:]
        private(set) var settleTimestamps: [String: ContinuousClock.Instant] = [:]
        private let clock = ContinuousClock()

        func recordStart(_ identity: String) {
            startTimestamps[identity] = clock.now
        }

        func recordSettle(_ identity: String) {
            settleTimestamps[identity] = clock.now
        }

        var startSpread: Duration {
            let instants = startTimestamps.values.sorted()
            guard let first = instants.first, let last = instants.last else { return .zero }
            return first.duration(to: last)
        }
    }

    /// N operations that each take T to settle must complete in
    /// approximately T (plus small coordination overhead), never in
    /// approximately N*T -- proving cancellation across many runners/items is
    /// awaited concurrently, not one after another.
    func testManySlowOperationsSettleNearTheSlowestNotTheSum() async throws {
        let recorder = Recorder()
        let perOperationSettle: Duration = .milliseconds(150)
        let operationCount = 6
        let operations = (0..<operationCount).map { index in
            (identity: "op-\(index)", run: { () async -> Void in
                await recorder.recordStart("op-\(index)")
                try? await Task.sleep(for: perOperationSettle)
                await recorder.recordSettle("op-\(index)")
            })
        }

        let clock = ContinuousClock()
        let started = clock.now
        await settleConcurrently(
            operations,
            deadline: LifecycleDeadline.makeInstant(budget: .seconds(5))
        )
        let elapsed = started.duration(to: clock.now)

        let sequentialSum = perOperationSettle * operationCount
        XCTAssertLessThan(
            elapsed, sequentialSum / 2,
            "6 operations at 150ms each must not sum to ~900ms if they run concurrently"
        )
        XCTAssertLessThan(
            elapsed, perOperationSettle + .milliseconds(300),
            "concurrent settlement should land near the single 150ms settle time, not accumulate"
        )
    }

    /// Every operation must be initiated before this function waits for any
    /// of them to settle: none of the slow operations should delay another
    /// operation's own start.
    func testAllOperationsStartBeforeAnySlowSettlementCompletes() async throws {
        let recorder = Recorder()
        let operations = (0..<5).map { index in
            (identity: "op-\(index)", run: { () async -> Void in
                await recorder.recordStart("op-\(index)")
                try? await Task.sleep(for: .milliseconds(100))
            })
        }

        await settleConcurrently(operations, deadline: LifecycleDeadline.makeInstant(budget: .seconds(5)))

        let spread = await recorder.startSpread
        XCTAssertLessThan(
            spread, .milliseconds(50),
            "all operations should start within a small window of each other, not staggered by prior settlement"
        )
    }

    /// A single shared deadline bounds the whole batch: an operation that
    /// never settles must not make the caller wait indefinitely, and the
    /// still-outstanding identity must be reported for diagnostics.
    func testDeadlineBoundsTheWaitAndReportsOutstandingIdentities() async throws {
        let fastSettled = expectation(description: "fast operation settled")
        let operations: [(identity: String, run: () async -> Void)] = [
            (identity: "fast", run: {
                try? await Task.sleep(for: .milliseconds(10))
                fastSettled.fulfill()
            }),
            (identity: "stuck", run: {
                // Simulates a runner/session that settles far later than the
                // deadline (e.g. a process that is slow to be reaped); long
                // enough to guarantee it outlives the 150ms deadline below.
                try? await Task.sleep(for: .seconds(2))
            })
        ]

        var reportedTimeouts: [LifecycleSettlementTimeout] = []
        let clock = ContinuousClock()
        let started = clock.now
        await settleConcurrently(
            operations,
            deadline: LifecycleDeadline.makeInstant(budget: .milliseconds(150)),
            onTimeout: { timeouts in reportedTimeouts = timeouts }
        )
        let elapsed = started.duration(to: clock.now)

        await fulfillment(of: [fastSettled], timeout: 1)
        XCTAssertLessThan(elapsed, .seconds(2), "the wait must be bounded by the deadline, not the stuck operation")
        XCTAssertEqual(reportedTimeouts.map(\.identity), ["stuck"])
    }

    /// No timeout is reported when every operation settles before the
    /// deadline, even if some are slow.
    func testNoTimeoutReportedWhenEverythingSettlesInTime() async throws {
        let operations = (0..<3).map { index in
            (identity: "op-\(index)", run: { () async -> Void in
                try? await Task.sleep(for: .milliseconds(30))
            })
        }

        var timeoutCallbackInvoked = false
        await settleConcurrently(
            operations,
            deadline: LifecycleDeadline.makeInstant(budget: .seconds(2)),
            onTimeout: { _ in timeoutCallbackInvoked = true }
        )

        XCTAssertFalse(timeoutCallbackInvoked)
    }

    /// An operation that settles at essentially the same moment the deadline
    /// passes must resolve the wait exactly once (no crash from a double
    /// continuation resume) regardless of which side wins the race.
    func testNaturalSettlementRacingTheDeadlineResolvesExactlyOnce() async throws {
        for _ in 0..<25 {
            let operations = [
                (identity: "racer", run: { () async -> Void in
                    try? await Task.sleep(for: .milliseconds(20))
                })
            ]
            await settleConcurrently(
                operations,
                deadline: LifecycleDeadline.makeInstant(budget: .milliseconds(20))
            )
        }
        // Reaching this point without a trap/crash proves the tracker never
        // double-resumes its continuation under this race.
    }

    func testEmptyOperationListReturnsImmediately() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        await settleConcurrently([], deadline: LifecycleDeadline.makeInstant(budget: .seconds(5)))
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(50))
    }
}
