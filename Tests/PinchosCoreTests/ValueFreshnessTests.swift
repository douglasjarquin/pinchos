import XCTest
@testable import PinchosCore

final class ValueFreshnessTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testUnavailableHasNoFabricatedTimestamp() {
        let freshness = interpret(value: nil, lastSuccessfulAt: nil, lastAttemptedAt: nil)
        XCTAssertEqual(freshness.state, .unavailable)
        XCTAssertFalse(freshness.isAgeExpired)
        XCTAssertFalse(freshness.isSchedulerDelayed)
        XCTAssertEqual(freshness.spokenState, "unavailable")
        XCTAssertEqual(freshness.runtimeStatus, .unavailable)
        XCTAssertEqual(freshness.marker, "")
    }

    func testFreshValueInsideTheConsumerInterval() {
        let freshness = interpret(
            value: "72%",
            lastSuccessfulAt: t0,
            lastAttemptedAt: t0,
            now: t0.addingTimeInterval(59)
        )
        XCTAssertEqual(freshness.state, .fresh)
        XCTAssertFalse(freshness.isAgeExpired)
        XCTAssertEqual(freshness.marker, "")
        XCTAssertEqual(freshness.spokenDescription(valueText: "72%"), "72%, fresh")
    }

    func testClockJumpAcrossMultipleIntervalsIsAgeStaleAndSchedulerDelayed() {
        let freshness = interpret(
            value: "72%",
            lastSuccessfulAt: t0,
            lastAttemptedAt: t0,
            now: t0.addingTimeInterval(60 * 5)
        )
        XCTAssertEqual(freshness.state, .ageStale)
        XCTAssertTrue(freshness.isAgeExpired)
        XCTAssertTrue(freshness.isSchedulerDelayed)
        XCTAssertEqual(freshness.marker, ValueFreshness.staleMarker)
        XCTAssertEqual(freshness.spokenState, "stale, scheduler delayed")
        XCTAssertEqual(freshness.runtimeStatus, .stale)
    }

    func testRefreshingKeepsLastGoodAndDoesNotLookFailed() {
        let freshness = interpret(
            value: "72%",
            isRefreshing: true,
            lastSuccessfulAt: t0,
            lastAttemptedAt: t0.addingTimeInterval(60),
            now: t0.addingTimeInterval(61)
        )
        XCTAssertEqual(freshness.state, .refreshing)
        XCTAssertTrue(freshness.isAgeExpired)
        XCTAssertFalse(freshness.isSchedulerDelayed)
        XCTAssertEqual(freshness.marker, "")
        XCTAssertEqual(freshness.spokenDescription(valueText: "72%"), "72%, refreshing")
    }

    func testFailedWithValueIsDistinctFromAgeExpiry() {
        let freshness = interpret(
            value: "72%",
            lastSuccessfulAt: t0,
            lastAttemptedAt: t0.addingTimeInterval(90),
            lastExecutionFailed: true,
            now: t0.addingTimeInterval(90)
        )
        XCTAssertEqual(freshness.state, .failedWithValue)
        XCTAssertTrue(freshness.isAgeExpired)
        XCTAssertFalse(freshness.isSchedulerDelayed)
        XCTAssertEqual(freshness.marker, ValueFreshness.warningMarker)
        XCTAssertEqual(freshness.spokenState, "failed, showing last good value")
        XCTAssertEqual(freshness.runtimeStatus, .error)
    }

    func testInitialFailureDoesNotAgeAndDoesNotInventSuccess() {
        let attempted = t0.addingTimeInterval(1)
        let freshness = interpret(
            value: nil,
            lastSuccessfulAt: nil,
            lastAttemptedAt: attempted,
            lastExecutionFailed: true,
            now: attempted.addingTimeInterval(120)
        )
        XCTAssertEqual(freshness.state, .failedWithoutValue)
        XCTAssertFalse(freshness.isAgeExpired)
        XCTAssertFalse(freshness.isSchedulerDelayed)
        XCTAssertEqual(freshness.spokenState, "failed")
        XCTAssertEqual(freshness.rowValueText(current: nil), "–")
        XCTAssertEqual(freshness.marker, ValueFreshness.warningMarker)
    }

    func testSharedConsumersDeriveAgeFromTheSameSuccessTimestamp() {
        let now = t0.addingTimeInterval(90)
        let short = interpret(
            value: "72%",
            lastSuccessfulAt: t0,
            lastAttemptedAt: t0,
            freshnessInterval: 60,
            now: now
        )
        let long = interpret(
            value: "72%",
            lastSuccessfulAt: t0,
            lastAttemptedAt: t0,
            freshnessInterval: 300,
            now: now
        )
        XCTAssertEqual(short.state, .ageStale)
        XCTAssertEqual(long.state, .fresh)
    }

    func testManualConsumerNeverAgeStales() {
        let freshness = interpret(
            value: "72%",
            lastSuccessfulAt: t0,
            lastAttemptedAt: t0,
            freshnessInterval: nil,
            now: t0.addingTimeInterval(10_000)
        )
        XCTAssertEqual(freshness.state, .fresh)
        XCTAssertFalse(freshness.isAgeExpired)
    }

    func testSnapshotUsesTheSamePolicy() {
        let snapshot = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "72%",
            lastAttemptedAt: t0,
            lastUpdatedAt: t0,
            lastExecution: nil,
            staleAfter: 60,
            skippedRefreshes: 0,
            now: t0.addingTimeInterval(180)
        )
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertTrue(snapshot.isStale)
        XCTAssertTrue(snapshot.freshness.isSchedulerDelayed)
        XCTAssertEqual(snapshot.freshness.state, .ageStale)
    }

    private func interpret(
        value: String?,
        isRefreshing: Bool = false,
        lastSuccessfulAt: Date?,
        lastAttemptedAt: Date?,
        lastExecutionFailed: Bool = false,
        freshnessInterval: TimeInterval? = 60,
        now: Date? = nil
    ) -> ValueFreshness {
        ValueFreshness.interpret(
            value: value,
            isRefreshing: isRefreshing,
            lastSuccessfulAt: lastSuccessfulAt,
            lastAttemptedAt: lastAttemptedAt,
            lastExecutionFailed: lastExecutionFailed,
            freshnessInterval: freshnessInterval,
            now: now ?? t0
        )
    }
}
