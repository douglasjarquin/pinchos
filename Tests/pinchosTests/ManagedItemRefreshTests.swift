import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

@MainActor
private final class RefreshTestMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

private final class TestItemClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    func now() -> Date { date }
}

/// Refresh Now, retry cadence, duplicate sources, and menu-open behavior
/// for issue #124. Commands append to log files so invocation counts are
/// about processes that actually ran. The item clock is fake; the executor
/// is still the real runner because ManagedItem constructs its own.
final class ManagedItemRefreshTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-item-refresh-\(UUID().uuidString)", isDirectory: true)
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

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Appends one log line, then prints `output` on the first run and fails after.
    private func failAfterFirstSuccess(log: URL, output: String) -> String {
        """
        printf 'x\\n' >> '\(log.path)'; \
        count=$(wc -l < '\(log.path)' | tr -d ' '); \
        if [ "$count" -eq 1 ]; then printf '\(output)'; else exit 1; fi
        """
    }

    private func counting(_ log: URL, output: String) -> String {
        "printf 'x\\n' >> '\(log.path)'; printf '\(output)'"
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
            menuDelegate: RefreshTestMenuDelegate(),
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
    private func waitForMenuRowIdle(_ item: ManagedItem) async -> Bool {
        await waitUntil { item.menuRowRefreshTaskCountForTesting == 0 }
    }

    @MainActor
    func testRefreshNowUpdatesManualSubmenuValueAndSkipsActionRows() async throws {
        let manualLog = path("manual.log")
        let actionSentinel = path("action.sentinel")
        let item = makeItem(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [
                MenuRowConfig(label: "Manual", run: counting(manualLog, output: "manual-value")),
                MenuRowConfig(label: "Act", action: "touch '\(actionSentinel.path)'")
            ]
        ))

        item.refreshNow()
        let updated = await waitUntil { item.menuRowValue(at: 0) == "manual-value" }
        XCTAssertTrue(updated, "Refresh Now did not refresh the manual submenu value")
        XCTAssertEqual(lineCount(manualLog), 1)
        XCTAssertFalse(exists(actionSentinel), "Refresh Now executed an action row")
        let primary = await waitUntil { await item.runtimeSnapshot().fullOutput == "primary" }
        XCTAssertTrue(primary)
    }

    @MainActor
    func testDuplicatePrimaryAndMenuConsumersJoinOneRefresh() async throws {
        let log = path("shared.log")
        let command = counting(log, output: "shared")
        let item = makeItem(config: ItemConfig(
            name: "item",
            run: command,
            interval: .manual,
            menu: [MenuRowConfig(label: "Same", run: command, cache: 60)]
        ))

        item.refreshNow()
        let updated = await waitUntil {
            await item.runtimeSnapshot().fullOutput == "shared" && item.menuRowValue(at: 0) == "shared"
        }
        XCTAssertTrue(updated)
        XCTAssertEqual(lineCount(log), 1, "duplicate primary/menu consumers multiplied executions")
    }

    @MainActor
    func testRapidOpensAfterFailedStaleRefreshDoNotRetryUntilCadence() async throws {
        let log = path("stale-fail.log")
        let clock = TestItemClock()
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [MenuRowConfig(
                    label: "Cached",
                    run: failAfterFirstSuccess(log: log, output: "good"),
                    cache: 60
                )]
            ),
            clock: clock
        )

        _ = item.menuRowValue(at: 0)
        let first = await waitUntil { item.menuRowValue(at: 0) == "good" }
        XCTAssertTrue(first)
        let idleAfterSuccess = await waitForMenuRowIdle(item)
        XCTAssertTrue(idleAfterSuccess)
        XCTAssertEqual(lineCount(log), 1)

        clock.date = clock.date.addingTimeInterval(61)
        _ = item.menuRowValue(at: 0)
        let failed = await waitUntil { self.lineCount(log) == 2 }
        XCTAssertTrue(failed, "stale row did not attempt the failing refresh")
        let idleAfterFailure = await waitForMenuRowIdle(item)
        XCTAssertTrue(idleAfterFailure)
        XCTAssertEqual(item.menuRowValue(at: 0), "good", "last-good value was not preserved")

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(lineCount(log), 2, "rapid opens after a failed stale refresh retried immediately")
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval)
        _ = item.menuRowValue(at: 0)
        let retried = await waitUntil { self.lineCount(log) == 3 }
        XCTAssertTrue(retried, "automatic retry did not run after the documented cadence")
    }

    @MainActor
    func testFailedManualRowRetriesOnCadenceAndRefreshNowBypassesIt() async throws {
        let log = path("manual-fail.log")
        let clock = TestItemClock()
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [MenuRowConfig(
                    label: "Manual",
                    run: failAfterFirstSuccess(log: log, output: "good")
                )]
            ),
            clock: clock
        )

        _ = item.menuRowValue(at: 0)
        let first = await waitUntil { self.lineCount(log) == 1 && item.menuRowValue(at: 0) == "good" }
        XCTAssertTrue(first)
        let idleAfterSuccess = await waitForMenuRowIdle(item)
        XCTAssertTrue(idleAfterSuccess)

        item.refreshNow()
        let second = await waitUntil { self.lineCount(log) == 2 }
        XCTAssertTrue(second, "Refresh Now did not bypass the retry cadence")
        let idleAfterRefreshNow = await waitForMenuRowIdle(item)
        XCTAssertTrue(idleAfterRefreshNow)
        XCTAssertEqual(item.menuRowValue(at: 0), "good")

        for _ in 0..<5 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(lineCount(log), 2, "failed manual row retried on every open")
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval)
        _ = item.menuRowValue(at: 0)
        let cadenceRetry = await waitUntil { self.lineCount(log) == 3 }
        XCTAssertTrue(cadenceRetry)
    }

    @MainActor
    func testFailedWithoutValueDoesNotRetryOnEveryOpen() async throws {
        let log = path("fail.log")
        let clock = TestItemClock()
        let command = "printf 'x\\n' >> '\(log.path)'; exit 1"
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [MenuRowConfig(label: "Broken", run: command, cache: 60)]
            ),
            clock: clock
        )

        _ = item.menuRowValue(at: 0)
        let first = await waitUntil { self.lineCount(log) == 1 }
        XCTAssertTrue(first)
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)
        XCTAssertNil(item.menuRowValue(at: 0))

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(lineCount(log), 1)
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval)
        _ = item.menuRowValue(at: 0)
        let retried = await waitUntil { self.lineCount(log) == 2 }
        XCTAssertTrue(retried)
    }

    @MainActor
    func testQueuedFailingRefreshDoesNotRetryOnReopenUntilCadenceAfterSettlement() async throws {
        let log = path("queued-fail.log")
        let clock = TestItemClock()
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [MenuRowConfig(
                    label: "Broken",
                    run: "printf 'x\\n' >> '\(log.path)'; exit 1",
                    cache: 60
                )]
            ),
            clock: clock,
            scheduler: scheduler
        )

        _ = item.menuRowValue(at: 0)
        let queued = await waitUntil { await scheduler.diagnostics().queuedSessions == 1 }
        XCTAssertTrue(queued, "menu refresh did not wait on the occupied scheduler permit")

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval + 5)
        await scheduler.releasePermit()
        let first = await waitUntil { self.lineCount(log) == 1 }
        XCTAssertTrue(first)
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(
            lineCount(log),
            1,
            "reopens after a queued failure retried before the cadence from settlement"
        )
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval)
        _ = item.menuRowValue(at: 0)
        let retried = await waitUntil { self.lineCount(log) == 2 }
        XCTAssertTrue(retried, "automatic retry did not run after the cadence from settlement")
    }

    @MainActor
    func testIntervalReloadCancelsQueuedPrimaryRefreshWithoutRunningCommand() async throws {
        let log = path("interval-reload.log")
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()
        let command = "printf 'x\\n' >> '\(log.path)'; printf ran"
        let item = makeItem(
            config: ItemConfig(name: "item", run: command, interval: .scheduled(60)),
            scheduler: scheduler
        )

        item.refreshNow()
        let queued = await waitUntil { await scheduler.diagnostics().queuedSessions == 1 }
        XCTAssertTrue(queued, "primary refresh did not wait on the occupied scheduler permit")

        let started = ContinuousClock.now
        await item.prepareUpdate(
            config: ItemConfig(name: "item", run: command, interval: .scheduled(120)),
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, Duration.milliseconds(500), "interval reload drained by waiting on the queued command")
        XCTAssertEqual(lineCount(log), 0)

        await scheduler.releasePermit()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lineCount(log), 0, "interval reload still ran the queued command")
        item.commitPreparedUpdate()
        XCTAssertEqual(lineCount(log), 0)
    }

    @MainActor
    func testIntervalReloadKeepsInFlightMenuRowAttemptForRetryGate() async throws {
        let log = path("row-generation.log")
        let clock = TestItemClock()
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()
        let row = "printf 'x\\n' >> '\(log.path)'; exit 1"
        let menu = [MenuRowConfig(label: "Broken", run: row, cache: 60)]
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .scheduled(60),
                menu: menu
            ),
            clock: clock,
            scheduler: scheduler
        )

        _ = item.menuRowValue(at: 0)
        let queued = await waitUntil { await scheduler.diagnostics().queuedSessions == 1 }
        XCTAssertTrue(queued)

        await item.prepareUpdate(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .scheduled(120),
                menu: menu
            ),
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        item.commitPreparedUpdate()

        await scheduler.releasePermit()
        let first = await waitUntil { self.lineCount(log) == 1 }
        XCTAssertTrue(first)
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(
            lineCount(log),
            1,
            "interval reload dropped the in-flight row attempt so the next open retried immediately"
        )
    }

    @MainActor
    func testPrimaryRefreshMirrorsSharedSourceIntoMenuRowGateAndValue() async throws {
        let log = path("shared-primary.log")
        let clock = TestItemClock()
        let command = failAfterFirstSuccess(log: log, output: "good")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: command,
                interval: .manual,
                menu: [MenuRowConfig(label: "Same", run: command, cache: 60)]
            ),
            clock: clock
        )

        item.refreshNow()
        let first = await waitUntil {
            await item.runtimeSnapshot().fullOutput == "good" && item.menuRowValue(at: 0) == "good"
        }
        XCTAssertTrue(first)
        let idleAfterSuccess = await waitForMenuRowIdle(item)
        XCTAssertTrue(idleAfterSuccess)
        XCTAssertEqual(lineCount(log), 1)

        clock.date = clock.date.addingTimeInterval(61)
        item.refreshPrimaryForTesting()
        let failed = await waitUntil {
            self.lineCount(log) == 2 && item.menuRowCachedValueForTesting(at: 0)?.state == .error
        }
        XCTAssertTrue(failed, "primary-only refresh did not mirror into the shared menu row")
        let idleAfterPrimary = await waitForMenuRowIdle(item)
        XCTAssertTrue(idleAfterPrimary)
        XCTAssertEqual(item.menuRowValue(at: 0), "good")

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(
            lineCount(log),
            2,
            "shared menu row did not inherit the primary's settled attempt and retried immediately"
        )
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)
    }

    @MainActor
    func testMenuRowValueDoesNotWaitOnASlowRefresh() async throws {
        let item = makeItem(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [MenuRowConfig(label: "Slow", run: "sleep 1; printf slow")]
        ))

        let started = Date()
        let value = item.menuRowValue(at: 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertNil(value)
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 1)

        let updated = await waitUntil(timeout: 3) { item.menuRowValue(at: 0) == "slow" }
        XCTAssertTrue(updated)
    }

    @MainActor
    func testRemovalDiscardsInFlightMenuRefreshAndDoesNotRunAction() async throws {
        let refreshLog = path("remove-refresh.log")
        let actionSentinel = path("remove-action.sentinel")
        let item = makeItem(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [
                MenuRowConfig(
                    label: "Slow",
                    run: "printf 'started\\n' > '\(refreshLog.path)'; while :; do sleep 1; done; printf 'late\\n' >> '\(refreshLog.path)'"
                ),
                MenuRowConfig(label: "Act", action: "touch '\(actionSentinel.path)'")
            ]
        ))

        item.refreshNow()
        let started = await waitUntil {
            (try? String(contentsOf: refreshLog, encoding: .utf8))?.contains("started") == true
        }
        XCTAssertTrue(started)
        await item.tearDown()
        try? await Task.sleep(for: .milliseconds(300))
        let log = (try? String(contentsOf: refreshLog, encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("late"), "removal still ran an obsolete menu refresh")
        XCTAssertFalse(exists(actionSentinel))
    }
}
