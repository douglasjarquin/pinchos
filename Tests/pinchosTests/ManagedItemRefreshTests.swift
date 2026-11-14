import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

@MainActor
private final class RefreshTestMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

/// Completes in the same turn so a delay-0 cache timer would race a second run.
private actor InstantSourceRunner: CommandSourceRunner {
    private(set) var runCount = 0
    private var lastExecution: CommandExecution?

    func runIfIdle() async -> CommandRunOutcome {
        runCount += 1
        let execution = CommandExecution(
            terminalReason: .exited(code: 0),
            stdout: "instant\n",
            stderr: "",
            stdoutBytesRead: 8,
            stderrBytesRead: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0
        )
        lastExecution = execution
        return .completed(execution)
    }

    func awaitSettledExecution() async -> CommandExecution? { lastExecution }

    func cancelActive() async {}

    func snapshot() async -> CommandRunnerSnapshot {
        CommandRunnerSnapshot(isRunning: false, lastExecution: lastExecution, skippedRefreshes: 0)
    }
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
        sourceRegistry: CommandSourceRegistry = CommandSourceRegistry(),
        initiallyVisible: Bool = false
    ) -> ManagedItem {
        let item = ManagedItem(
            config: config,
            menuDelegate: RefreshTestMenuDelegate(),
            initiallyVisible: initiallyVisible,
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
        await item.refreshPrimaryForTesting()
        XCTAssertEqual(
            lineCount(log),
            2,
            "primary-only refresh did not mirror into the shared menu row"
        )
        XCTAssertEqual(
            item.menuRowCachedValueForTesting(at: 0)?.state,
            .error,
            "primary-only refresh did not mirror into the shared menu row"
        )
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
    func testUnchangedMenuRowKeepsRetryGateWhenAnotherRowChanges() async throws {
        let log = path("kept-row.log")
        let clock = TestItemClock()
        let kept = counting(log, output: "kept")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [
                    MenuRowConfig(label: "Kept", run: kept, cache: 60),
                    MenuRowConfig(label: "Other", run: "printf other", cache: 60)
                ]
            ),
            clock: clock
        )

        _ = item.menuRowValue(at: 0)
        let first = await waitUntil { item.menuRowValue(at: 0) == "kept" }
        XCTAssertTrue(first)
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)
        XCTAssertEqual(lineCount(log), 1)

        await item.prepareUpdate(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [
                MenuRowConfig(label: "Kept", run: kept, cache: 60),
                MenuRowConfig(label: "Other", run: "printf other-new", cache: 60)
            ]
        ))
        item.commitPreparedUpdate()
        let seeded = await waitForMenuRowIdle(item)
        XCTAssertTrue(seeded)

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(
            lineCount(log),
            1,
            "an unchanged row lost its retry gate across a menu edit and re-ran immediately"
        )
        XCTAssertEqual(item.menuRowValue(at: 0), "kept")
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)
    }

    @MainActor
    func testReloadRefreshesNewAndChangedCachedRowsOnceAndLeavesRetainedIdle() async throws {
        let keptLog = path("reload-kept.log")
        let changedLog = path("reload-changed.log")
        let newLog = path("reload-new.log")
        let manualLog = path("reload-manual.log")
        let clock = TestItemClock()
        let kept = counting(keptLog, output: "kept")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [
                    MenuRowConfig(label: "Kept", run: kept, cache: 60),
                    MenuRowConfig(label: "Old", run: "printf old", cache: 60)
                ]
            ),
            clock: clock
        )

        _ = item.menuRowValue(at: 0)
        let first = await waitUntil { item.menuRowValue(at: 0) == "kept" }
        XCTAssertTrue(first)
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)
        XCTAssertEqual(lineCount(keptLog), 1)

        await item.prepareUpdate(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [
                MenuRowConfig(label: "Kept", run: kept, cache: 60),
                MenuRowConfig(label: "Changed", run: counting(changedLog, output: "changed"), cache: 60),
                MenuRowConfig(label: "New", run: counting(newLog, output: "new"), cache: 60),
                MenuRowConfig(label: "Manual", run: counting(manualLog, output: "manual"))
            ]
        ))
        item.commitPreparedUpdate()

        let changedAndNew = await waitUntil {
            self.lineCount(changedLog) == 1 && self.lineCount(newLog) == 1
        }
        XCTAssertTrue(changedAndNew, "changed or new cached row did not refresh after reload")
        let idleAfter = await waitForMenuRowIdle(item)
        XCTAssertTrue(idleAfter)
        XCTAssertEqual(lineCount(keptLog), 1, "a retained cached row refreshed on reload")
        XCTAssertEqual(lineCount(changedLog), 1, "a changed cached row did not run exactly once")
        XCTAssertEqual(lineCount(newLog), 1, "a new cached row did not run exactly once")
        XCTAssertEqual(lineCount(manualLog), 0, "a new manual row ran on reload commit")
        XCTAssertEqual(item.menuRowValue(at: 0), "kept")

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(lineCount(keptLog), 1, "a retained row lost its retry gate after reload")
        XCTAssertEqual(lineCount(manualLog), 0, "a new manual row ran after reload without an explicit request")
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)
    }

    @MainActor
    func testReloadRunsNewCachedRowOnceWithInstantRunner() async throws {
        let scheduler = CommandScheduler()
        let sourceRegistry = CommandSourceRegistry()
        let runner = InstantSourceRunner()
        let command = "instant-reload-row"
        let lease = sourceRegistry.acquire(
            configuration: CommandSourceConfiguration(
                command: command,
                timeout: ItemConfig.defaultTimeout,
                refreshPolicy: .scheduled(60),
                staleAfter: 60
            ),
            scheduler: scheduler,
            runner: runner
        )
        addTeardownBlock {
            sourceRegistry.release(lease)
        }
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [MenuRowConfig(label: "Old", run: "printf old", cache: 60)]
            ),
            scheduler: scheduler,
            sourceRegistry: sourceRegistry
        )

        await item.prepareUpdate(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [MenuRowConfig(label: "New", run: command, cache: 60)]
        ))
        item.commitPreparedUpdate()

        let ran = await waitUntil { await runner.runCount == 1 }
        XCTAssertTrue(ran, "new cached row with an instant runner did not refresh after reload")
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)
        try? await Task.sleep(for: .milliseconds(200))
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 1, "instant cached row ran more than once on reload")
    }

    @MainActor
    func testSecondReloadRefreshesCachedRowWhoseFirstAttemptWasStillQueued() async throws {
        let log = path("queued-second-reload.log")
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        try await scheduler.acquirePermit()
        let cached = counting(log, output: "cached")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: []
            ),
            scheduler: scheduler
        )

        await item.prepareUpdate(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [MenuRowConfig(label: "Cached", run: cached, cache: 60)]
        ))
        item.commitPreparedUpdate()
        let queued = await waitUntil { await scheduler.diagnostics().queuedSessions == 1 }
        XCTAssertTrue(queued, "first reload did not queue the new cached row behind the occupied permit")
        XCTAssertEqual(lineCount(log), 0)

        await item.prepareUpdate(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [
                MenuRowConfig(label: "Cached", run: cached, cache: 60),
                MenuRowConfig(label: "Other", run: "printf other")
            ]
        ))
        item.commitPreparedUpdate()

        await scheduler.releasePermit()
        let ran = await waitUntil { self.lineCount(log) == 1 }
        XCTAssertTrue(ran, "cached row stranded after a second reload cancelled its queued first attempt")
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lineCount(log), 1, "cached row ran more than once after the second reload")
        XCTAssertEqual(item.menuRowValue(at: 0), "cached")
    }

    @MainActor
    func testStartupRefreshesPrimaryAndCachedRowOnce() async throws {
        let primaryLog = path("startup-primary.log")
        let rowLog = path("startup-row.log")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: counting(primaryLog, output: "primary"),
                interval: .manual,
                menu: [MenuRowConfig(label: "Cached", run: counting(rowLog, output: "row"), cache: 60)]
            ),
            initiallyVisible: true
        )

        let started = await waitUntil {
            self.lineCount(primaryLog) == 1 && item.menuRowValue(at: 0) == "row"
        }
        XCTAssertTrue(started)
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lineCount(primaryLog), 1, "startup ran the primary more than once")
        XCTAssertEqual(lineCount(rowLog), 1, "startup ran the cached row more than once")
    }

    @MainActor
    func testActivateRefreshesPrimaryAndCachedRowOnce() async throws {
        let primaryLog = path("activate-primary.log")
        let rowLog = path("activate-row.log")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: counting(primaryLog, output: "primary"),
                interval: .manual,
                menu: [MenuRowConfig(label: "Cached", run: counting(rowLog, output: "row"), cache: 60)]
            )
        )

        item.activate()
        let started = await waitUntil {
            self.lineCount(primaryLog) == 1 && item.menuRowValue(at: 0) == "row"
        }
        XCTAssertTrue(started)
        let idle = await waitForMenuRowIdle(item)
        XCTAssertTrue(idle)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lineCount(primaryLog), 1, "activate ran the primary more than once")
        XCTAssertEqual(lineCount(rowLog), 1, "activate ran the cached row more than once")
    }

    @MainActor
    func testInFlightKeptRowAttemptSeedsCacheAfterMenuEdit() async throws {
        let log = path("inflight-edit.log")
        let started = path("inflight-edit.started")
        let clock = TestItemClock()
        let kept = "printf 'x' > '\(started.path)'; sleep 0.4; printf 'x\\n' >> '\(log.path)'; printf good"
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [
                    MenuRowConfig(label: "Kept", run: kept, cache: 60),
                    MenuRowConfig(label: "Other", run: "printf other", cache: 60)
                ]
            ),
            clock: clock
        )

        _ = item.menuRowValue(at: 0)
        let began = await waitUntil { self.exists(started) }
        XCTAssertTrue(began)

        await item.prepareUpdate(config: ItemConfig(
            name: "item",
            run: "printf primary",
            interval: .manual,
            menu: [
                MenuRowConfig(label: "Kept", run: kept, cache: 60),
                MenuRowConfig(label: "Other", run: "printf other-new", cache: 60)
            ]
        ))
        item.commitPreparedUpdate()
        XCTAssertEqual(lineCount(log), 0, "commit waited on the in-flight kept-row command")

        let seeded = await waitUntil(timeout: 3) {
            self.lineCount(log) == 1 && item.menuRowCachedValueForTesting(at: 0)?.state == .fresh
        }
        XCTAssertTrue(seeded, "kept row did not seed the settled attempt after the menu edit")
        XCTAssertEqual(item.menuRowValue(at: 0), "good")

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
        }
        XCTAssertEqual(
            lineCount(log),
            1,
            "a never-attempted row that succeeded during a menu edit reran on the next open"
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
