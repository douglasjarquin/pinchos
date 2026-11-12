import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

@MainActor
private final class FreshnessMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

private final class TestItemClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    func now() -> Date { date }
}

/// Presentation-time freshness for issue #123. Retry admission and Refresh Now
/// stay on the #124 paths; these tests only advance the item clock and read
/// the next snapshot/render.
final class ManagedItemFreshnessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-item-freshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    private func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func counting(_ log: URL, output: String) -> String {
        "printf 'x\\n' >> '\(log.path)'; printf '\(output)'"
    }

    private func failAfterFirstSuccess(log: URL, output: String) -> String {
        """
        printf 'x\\n' >> '\(log.path)'; \
        count=$(wc -l < '\(log.path)' | tr -d ' '); \
        if [ "$count" -eq 1 ]; then printf '\(output)'; else exit 1; fi
        """
    }

    @MainActor
    private func makeItem(
        config: ItemConfig,
        clock: TestItemClock = TestItemClock(),
        scheduler: CommandScheduler = CommandScheduler(),
        sourceRegistry: CommandSourceRegistry = CommandSourceRegistry()
    ) -> ManagedItem {
        let item = ManagedItem(
            config: config,
            menuDelegate: FreshnessMenuDelegate(),
            initiallyVisible: false,
            scheduler: scheduler,
            sourceRegistry: sourceRegistry,
            now: { clock.now() },
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }
        return item
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @MainActor
    func testClockJumpAcrossMultipleIntervalsMarksPrimaryStaleWithoutNewSuccess() async throws {
        let clock = TestItemClock()
        let log = path("stale.log")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: counting(log, output: "72"),
                interval: .scheduled(60)
            ),
            clock: clock
        )

        item.refreshNow()
        let ready = await waitUntil { await item.runtimeSnapshot().fullOutput == "72" }
        XCTAssertTrue(ready)
        XCTAssertEqual(item.renderedTitle, "72")
        XCTAssertEqual(item.renderedAccessibilityLabel, "72, fresh")
        let success = await item.runtimeSnapshot()
        let lastSuccess = try XCTUnwrap(success.lastUpdatedAt)
        XCTAssertEqual(lineCount(log), 1)

        clock.date = clock.date.addingTimeInterval(60 * 3)
        let snapshot = await item.runtimeSnapshot()

        XCTAssertEqual(snapshot.fullOutput, "72")
        XCTAssertEqual(snapshot.lastUpdatedAt, lastSuccess)
        XCTAssertEqual(snapshot.freshness.state, .ageStale)
        XCTAssertTrue(snapshot.isStale)
        XCTAssertTrue(snapshot.freshness.isSchedulerDelayed)
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(item.renderedTitle, "72\(ValueFreshness.staleMarker)")
        XCTAssertEqual(item.renderedAccessibilityLabel, "72, stale, scheduler delayed")
        XCTAssertEqual(lineCount(log), 1, "presentation must not start a command")
    }

    @MainActor
    func testFailedRefreshKeepsLastGoodAndStaysDistinctFromAge() async throws {
        let clock = TestItemClock()
        let log = path("fail.log")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: failAfterFirstSuccess(log: log, output: "72"),
                interval: .scheduled(60)
            ),
            clock: clock
        )

        item.refreshNow()
        let ready = await waitUntil { await item.runtimeSnapshot().fullOutput == "72" }
        XCTAssertTrue(ready)
        let successSnapshot = await item.runtimeSnapshot()
        let lastSuccess = try XCTUnwrap(successSnapshot.lastUpdatedAt)

        clock.date = clock.date.addingTimeInterval(90)
        item.refreshNow()
        let failed = await waitUntil {
            await item.runtimeSnapshot().status == .error
                && item.renderedTitle == "72\(ValueFreshness.warningMarker)"
        }
        XCTAssertTrue(failed)
        let snapshot = await item.runtimeSnapshot()
        XCTAssertEqual(snapshot.fullOutput, "72")
        XCTAssertEqual(snapshot.lastUpdatedAt, lastSuccess)
        XCTAssertEqual(snapshot.freshness.state, .failedWithValue)
        XCTAssertTrue(snapshot.isStale)
        XCTAssertFalse(snapshot.freshness.isSchedulerDelayed)
        XCTAssertEqual(item.renderedAccessibilityLabel, "72, failed, showing last good value")
        XCTAssertEqual(lineCount(log), 2)
    }

    @MainActor
    func testInitialFailureDoesNotFabricateASuccessTimestampOrValue() async throws {
        let clock = TestItemClock()
        let item = makeItem(
            config: ItemConfig(name: "item", run: "printf 'nope\\n' >&2; exit 7", interval: .scheduled(60)),
            clock: clock
        )

        item.refreshNow()
        let failed = await waitUntil { await item.runtimeSnapshot().status == .error }
        XCTAssertTrue(failed)
        let snapshot = await item.runtimeSnapshot()
        XCTAssertNil(snapshot.fullOutput)
        XCTAssertNil(snapshot.lastUpdatedAt)
        XCTAssertNotNil(snapshot.lastAttemptedAt)
        XCTAssertEqual(snapshot.freshness.state, .failedWithoutValue)
        XCTAssertFalse(snapshot.isStale)
        XCTAssertEqual(item.renderedTitle, "–\(ValueFreshness.warningMarker)")
        XCTAssertEqual(item.renderedAccessibilityLabel, "failed")
    }

    @MainActor
    func testSharedConsumersWithDifferentIntervalsFollowTheSharedSuccessTimestamp() async throws {
        let command = counting(path("shared.log"), output: "72")
        try await assertSharedFreshness(firstInterval: 60, secondInterval: 300, command: command)
        try await assertSharedFreshness(firstInterval: 300, secondInterval: 60, command: command)
    }

    @MainActor
    func testMenuRowsFollowConsumerCacheAgainstSharedSuccessTimestamp() async throws {
        let clock = TestItemClock()
        let command = counting(path("rows.log"), output: "72")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: command,
                interval: .scheduled(10),
                menu: [
                    MenuRowConfig(label: "Short", run: command, cache: 10),
                    MenuRowConfig(label: "Long", run: command, cache: 300)
                ]
            ),
            clock: clock
        )

        item.refreshNow()
        let ready = await waitUntil {
            await item.runtimeSnapshot().fullOutput == "72"
                && item.menuRowValue(at: 0) == "72"
                && item.menuRowValue(at: 1) == "72"
        }
        XCTAssertTrue(ready)

        // Past the short window, still inside the 30s retry gate, so reading
        // the row must not start a new command and flip this into refreshing.
        clock.date = clock.date.addingTimeInterval(25)
        let snapshot = await item.runtimeSnapshot()
        let short = item.menuRowFreshness(at: 0)
        let long = item.menuRowFreshness(at: 1)

        XCTAssertEqual(snapshot.freshness.state, .ageStale)
        XCTAssertEqual(short.state, .ageStale)
        XCTAssertEqual(long.state, .fresh)
        XCTAssertEqual(snapshot.lastUpdatedAt, item.menuRowCachedValueForTesting(at: 0)?.lastSuccessfulAt)
        XCTAssertEqual(snapshot.lastUpdatedAt, item.menuRowCachedValueForTesting(at: 1)?.lastSuccessfulAt)
    }

    @MainActor
    func testRefreshingKeepsLastGoodWithoutAFailureMarker() async throws {
        let clock = TestItemClock()
        let marker = path("hold")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "if [ ! -e '\(marker.path)' ]; then printf '72'; touch '\(marker.path)'; else sleep 0.4; printf '99'; fi",
                interval: .scheduled(60)
            ),
            clock: clock
        )

        item.refreshNow()
        let ready = await waitUntil { await item.runtimeSnapshot().fullOutput == "72" }
        XCTAssertTrue(ready)
        XCTAssertEqual(item.renderedTitle, "72")

        item.refreshNow()
        let refreshing = await waitUntil {
            await item.runtimeSnapshot().freshness.state == .refreshing
                && item.renderedTitle == "72"
        }
        XCTAssertTrue(refreshing)
        XCTAssertEqual(item.renderedAccessibilityLabel, "72, refreshing")
        let settled = await waitUntil { await item.runtimeSnapshot().fullOutput == "99" }
        XCTAssertTrue(settled)
        XCTAssertEqual(item.renderedTitle, "99")
    }

    @MainActor
    private func assertSharedFreshness(
        firstInterval: TimeInterval,
        secondInterval: TimeInterval,
        command: String
    ) async throws {
        let clock = TestItemClock()
        let registry = CommandSourceRegistry()
        let first = makeItem(
            config: ItemConfig(name: "first", run: command, interval: .scheduled(firstInterval)),
            clock: clock,
            sourceRegistry: registry
        )
        let second = makeItem(
            config: ItemConfig(name: "second", run: command, interval: .scheduled(secondInterval)),
            clock: clock,
            sourceRegistry: registry
        )

        first.refreshNow()
        second.refreshNow()
        let ready = await waitUntil {
            let firstReady = await first.runtimeSnapshot().fullOutput == "72"
            let secondReady = await second.runtimeSnapshot().fullOutput == "72"
            return firstReady && secondReady
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(registry.sourceCount, 1)

        clock.date = clock.date.addingTimeInterval(90)
        let firstSnapshot = await first.runtimeSnapshot()
        let secondSnapshot = await second.runtimeSnapshot()
        XCTAssertEqual(firstSnapshot.lastUpdatedAt, secondSnapshot.lastUpdatedAt)

        let expectedShort: ValueFreshness.State = firstInterval < secondInterval ? .ageStale : .fresh
        let expectedLong: ValueFreshness.State = firstInterval < secondInterval ? .fresh : .ageStale
        XCTAssertEqual(firstSnapshot.freshness.state, expectedShort)
        XCTAssertEqual(secondSnapshot.freshness.state, expectedLong)
    }
}
