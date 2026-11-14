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

/// Copy of `PinchosCore.ManualSchedulerClock` that parks even `sleep(until: now)`.
/// The production double returns immediately when the deadline is already
/// elapsed, so a delay-0 restart tick would fire without `advance(by:)`.
private final class ManualSchedulerClock: SchedulerClock, @unchecked Sendable {
    private let origin = ContinuousClock.now
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let slot: ManualClockSlot
    }
    private var waiters: [Waiter] = []

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return origin.advanced(by: elapsed)
    }

    func sleep(until instant: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let targetElapsed = origin.duration(to: instant)
        let id = UUID()
        let slot = ManualClockSlot()
        addWaiter(id: id, deadline: targetElapsed, slot: slot)

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    slot.install(continuation)
                }
            },
            onCancel: { [weak self] in
                slot.fail(CancellationError())
                self?.removeWaiter(id)
            }
        )
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero, "ManualSchedulerClock only advances forward")
        lock.lock()
        elapsed += duration
        let due = waiters.filter { $0.deadline <= elapsed }.sorted { $0.deadline < $1.deadline }
        waiters.removeAll { $0.deadline <= elapsed }
        lock.unlock()
        for waiter in due {
            waiter.slot.succeed()
        }
    }

    private func removeWaiter(_ id: UUID) {
        lock.lock()
        waiters.removeAll { $0.id == id }
        lock.unlock()
    }

    private func addWaiter(id: UUID, deadline: Duration, slot: ManualClockSlot) {
        lock.lock()
        waiters.append(Waiter(id: id, deadline: deadline, slot: slot))
        lock.unlock()
    }
}

private final class ManualClockSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var pendingError: Error?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if settled {
            let error = pendingError
            lock.unlock()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func succeed() -> Bool { settle(error: nil) }

    @discardableResult
    func fail(_ error: Error) -> Bool { settle(error: error) }

    @discardableResult
    private func settle(error: Error?) -> Bool {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return false
        }
        settled = true
        pendingError = error
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return true }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
        return true
    }
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
        let ready = await waitUntil {
            item.renderedTitle == "72"
                && item.renderedAccessibilityLabel == "72, fresh"
        }
        XCTAssertTrue(ready)
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
        let ready = await waitUntil {
            let snapshot = await item.runtimeSnapshot()
            return snapshot.fullOutput == "72" && snapshot.freshness.state == .fresh
        }
        XCTAssertTrue(ready)
        await item.awaitPrimaryRefreshForTesting()
        let successSnapshot = await item.runtimeSnapshot()
        let lastSuccess = try XCTUnwrap(successSnapshot.lastUpdatedAt)

        clock.date = clock.date.addingTimeInterval(90)
        item.refreshNow()
        await item.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(item.renderedTitle, "72\(ValueFreshness.warningMarker)")
        let snapshot = await item.runtimeSnapshot()
        XCTAssertEqual(snapshot.status, .error)
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
    func testFailedWithoutValueThenRefreshingSpeaksWithoutGlyphs() async throws {
        let clock = TestItemClock()
        let hold = path("fail-then-refresh")
        let item = makeItem(
            config: ItemConfig(
                name: "item",
                run: "if [ ! -e '\(hold.path)' ]; then touch '\(hold.path)'; printf 'nope' >&2; exit 1; else sleep 0.4; printf '99'; fi",
                interval: .manual
            ),
            clock: clock
        )

        item.refreshNow()
        let failed = await waitUntil {
            await item.runtimeSnapshot().freshness.state == .failedWithoutValue
                && item.renderedTitle == "–\(ValueFreshness.warningMarker)"
        }
        XCTAssertTrue(failed)
        await item.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(item.renderedAccessibilityLabel, "failed")

        item.refreshNow()
        let refreshing = await waitUntil {
            await item.runtimeSnapshot().freshness.state == .refreshing
                && item.renderedAccessibilityLabel == "refreshing"
        }
        XCTAssertTrue(refreshing)
        XCTAssertFalse(item.renderedAccessibilityLabel.contains(ValueFreshness.warningMarker))
        XCTAssertFalse(item.renderedAccessibilityLabel.contains(ValueFreshness.staleMarker))
        XCTAssertFalse(item.renderedAccessibilityLabel.contains("–"))
        XCTAssertFalse(item.renderedAccessibilityLabel.contains("⚠"))
        XCTAssertFalse(item.renderedAccessibilityLabel.contains("⌛"))

        await item.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(item.renderedTitle, "99")
        XCTAssertEqual(item.renderedAccessibilityLabel, "99, fresh")
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
        let shortRuntime = try XCTUnwrap(item.menuRowRuntimeSnapshot(at: 0))
        let longRuntime = try XCTUnwrap(item.menuRowRuntimeSnapshot(at: 1))
        XCTAssertEqual(shortRuntime.freshness.state, .ageStale)
        XCTAssertTrue(shortRuntime.freshness.isSchedulerDelayed)
        XCTAssertEqual(longRuntime.freshness.state, .fresh)
        XCTAssertFalse(longRuntime.freshness.isSchedulerDelayed)
        XCTAssertEqual(shortRuntime.lastUpdatedAt, snapshot.lastUpdatedAt)
        XCTAssertEqual(longRuntime.lastUpdatedAt, snapshot.lastUpdatedAt)
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
        let ready = await waitUntil { item.renderedTitle == "72" }
        XCTAssertTrue(ready)
        await item.awaitPrimaryRefreshForTesting()

        item.refreshNow()
        let refreshing = await waitUntil {
            item.renderedTitle == "72"
                && item.renderedAccessibilityLabel == "72, refreshing"
        }
        XCTAssertTrue(refreshing)
        await item.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(item.renderedTitle, "99")
    }

    @MainActor
    func testAgedValueKeepsStaleMarkerWhileARefreshIsInFlight() async throws {
        let clock = TestItemClock()
        let scheduler = CommandScheduler()
        let factory = FreshnessItemFactory(clock: clock, scheduler: scheduler)
        let controller = StatusItemController(
            configPath: "/tmp/pinchos-freshness-\(UUID().uuidString).toml",
            onReload: {},
            itemFactory: factory,
            scheduler: scheduler,
            statusItemHost: FreshnessStatusItemHost()
        )
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let hold = path("stale-refresh-hold")
        let command = "if [ ! -e '\(hold.path)' ]; then printf '72'; touch '\(hold.path)'; else sleep 0.6; printf '99'; fi"
        let config = ItemConfig(
            name: "item",
            run: command,
            interval: .scheduled(60),
            menu: [MenuRowConfig(label: "Usage", run: command, cache: 60)]
        )
        await controller.apply(config: PinchosConfig(items: [config]))
        let item = try XCTUnwrap(factory.created.first)

        let ready = await waitUntil {
            item.renderedTitle == "72" && item.menuRowValue(at: 0) == "72"
        }
        XCTAssertTrue(ready)
        await item.awaitPrimaryRefreshForTesting()

        // Wake, then a tick starts a slow refresh. The bar must pick up
        // stale-while-refreshing without runtimeSnapshot() painting it.
        clock.date = clock.date.addingTimeInterval(180)
        item.refreshNow()
        let refreshing = await waitUntil {
            item.renderedTitle == "72\(ValueFreshness.staleMarker)"
                && item.renderedAccessibilityLabel == "72, stale, refreshing"
        }
        XCTAssertTrue(refreshing)

        let menu = await controller.makeLifecycleMenu(forManagedItem: item)
        let titles = menu.items.map(\.title)
        let usage = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Usage:") }))
        XCTAssertEqual(usage.title, "Usage: 72\(ValueFreshness.staleMarker)")
        XCTAssertEqual(usage.accessibilityLabel(), "Usage, 72, stale, refreshing")
        XCTAssertTrue(titles.contains("State: running"))
        XCTAssertTrue(titles.contains("Stale: yes"))
        XCTAssertFalse(titles.contains("Delay: scheduler"))
        XCTAssertTrue(titles.contains("Value \"Usage\": State: running"))
        XCTAssertTrue(titles.contains("Value \"Usage\": Stale: yes"))
        XCTAssertTrue(titles.contains("Value \"Usage\": Refresh: queued or active"))
        XCTAssertFalse(titles.contains("Value \"Usage\": Delay: scheduler"))

        let collapsed = await controller.makeCollapsedMenu()
        let collapsedRow = try XCTUnwrap(collapsed.items.first(where: { $0.submenu != nil }))
        XCTAssertEqual(collapsedRow.title, "72\(ValueFreshness.staleMarker)")
        XCTAssertEqual(collapsedRow.accessibilityLabel(), "item, 72, stale, refreshing")

        await item.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(item.renderedTitle, "99")
        XCTAssertEqual(item.renderedAccessibilityLabel, "99, fresh")
    }

    @MainActor
    func testAbandonedQueuedRefreshDoesNotStayRefreshing() async throws {
        let clock = TestItemClock()
        let schedulerClock = ManualSchedulerClock()
        let log = path("abandon.log")
        let scheduler = CommandScheduler(maxActiveSessions: 1, clock: schedulerClock)
        let command = counting(log, output: "72")
        let item = makeItem(
            config: ItemConfig(name: "item", run: command, interval: .scheduled(60)),
            clock: clock,
            scheduler: scheduler
        )

        await item.refreshPrimaryForTesting()
        let successSnapshot = await item.runtimeSnapshot()
        XCTAssertEqual(successSnapshot.fullOutput, "72")
        let successAt = try XCTUnwrap(successSnapshot.lastUpdatedAt)
        XCTAssertEqual(lineCount(log), 1)

        try await scheduler.acquirePermit()
        item.refreshNow()
        let queued = await waitUntil { await scheduler.diagnostics().queuedSessions == 1 }
        XCTAssertTrue(queued)

        // Identity change drops the last lease, so the queued flight is
        // cancelled before it can acquire a permit. Interval-only edits keep
        // the shared source (#124) and are not this path.
        await item.prepareUpdate(
            config: ItemConfig(name: "item", run: counting(log, output: "99"), interval: .scheduled(60)),
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        item.commitPreparedUpdate()
        await scheduler.releasePermit()
        await item.awaitPrimaryRefreshForTesting()
        await item.awaitPresentationUpdateForTesting()

        let afterCancel = await item.runtimeSnapshot()
        XCTAssertNotEqual(afterCancel.freshness.state, .refreshing)
        XCTAssertEqual(afterCancel.fullOutput, "72")
        XCTAssertEqual(afterCancel.lastUpdatedAt, successAt)
        XCTAssertEqual(afterCancel.lastAttemptedAt, successAt)
        XCTAssertEqual(item.renderedTitle, "72")
        XCTAssertEqual(lineCount(log), 1)

        clock.date = clock.date.addingTimeInterval(180)
        let aged = await item.runtimeSnapshot()
        XCTAssertEqual(aged.freshness.state, .ageStale)
        XCTAssertTrue(aged.freshness.isSchedulerDelayed)
        XCTAssertEqual(item.renderedTitle, "72\(ValueFreshness.staleMarker)")
        XCTAssertEqual(item.renderedAccessibilityLabel, "72, stale, scheduler delayed")
        XCTAssertEqual(lineCount(log), 1)

        let registered = await waitUntil { await scheduler.diagnostics().registeredTimers == 1 }
        XCTAssertTrue(registered)
        schedulerClock.advance(by: .zero)
        let started = await waitUntil { item.hasPrimaryRefreshForTesting }
        XCTAssertTrue(started)
        await item.awaitPrimaryRefreshForTesting()
        let settled = await item.runtimeSnapshot()
        XCTAssertNotEqual(settled.freshness.state, .refreshing)
        XCTAssertEqual(settled.fullOutput, "99")
        XCTAssertEqual(item.renderedTitle, "99")
        XCTAssertEqual(item.renderedAccessibilityLabel, "99, fresh")
        XCTAssertEqual(lineCount(log), 2)
    }

    @MainActor
    func testSharedConsumerAdoptsTheSameSuccessTextAndTimestamp() async throws {
        let clock = TestItemClock()
        let registry = CommandSourceRegistry()
        let hold = path("shared-adopt")
        let command = "if [ ! -e '\(hold.path)' ]; then printf '72'; touch '\(hold.path)'; else printf '99'; fi"
        let short = makeItem(
            config: ItemConfig(name: "short", run: command, interval: .scheduled(60)),
            clock: clock,
            sourceRegistry: registry
        )
        let long = makeItem(
            config: ItemConfig(name: "long", run: command, interval: .scheduled(300)),
            clock: clock,
            sourceRegistry: registry
        )

        short.refreshNow()
        long.refreshNow()
        let ready = await waitUntil { short.renderedTitle == "72" && long.renderedTitle == "72" }
        XCTAssertTrue(ready)
        await short.awaitPrimaryRefreshForTesting()
        await long.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(registry.sourceCount, 1)

        short.refreshNow()
        await short.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(short.renderedTitle, "99")

        let longSnapshot = await long.runtimeSnapshot()
        let shortSnapshot = await short.runtimeSnapshot()
        XCTAssertEqual(longSnapshot.fullOutput, "99")
        XCTAssertEqual(long.renderedTitle, "99")
        XCTAssertEqual(longSnapshot.lastUpdatedAt, shortSnapshot.lastUpdatedAt)
        XCTAssertEqual(longSnapshot.freshness.state, .fresh)
    }

    @MainActor
    func testSharedFailureAfterPeerSuccessUsesLastGoodValueForTitle() async throws {
        let clock = TestItemClock()
        let registry = CommandSourceRegistry()
        let log = path("peer-fail.log")
        let command = """
        printf 'x\\n' >> '\(log.path)'; \
        count=$(wc -l < '\(log.path)' | tr -d ' '); \
        if [ "$count" -eq 1 ]; then printf '72'; \
        elif [ "$count" -eq 2 ]; then printf '99'; \
        else exit 1; fi
        """
        let peer = makeItem(
            config: ItemConfig(name: "peer", run: command, interval: .scheduled(60), format: "{output}%"),
            clock: clock,
            sourceRegistry: registry
        )
        let item = makeItem(
            config: ItemConfig(name: "item", run: command, interval: .scheduled(60), format: "{output}%"),
            clock: clock,
            sourceRegistry: registry
        )

        peer.refreshNow()
        item.refreshNow()
        let first = await waitUntil { peer.renderedTitle == "72%" && item.renderedTitle == "72%" }
        XCTAssertTrue(first)
        await peer.awaitPrimaryRefreshForTesting()
        await item.awaitPrimaryRefreshForTesting()

        peer.refreshNow()
        await peer.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(peer.renderedTitle, "99%")

        peer.refreshNow()
        await peer.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(peer.renderedTitle, "99%\(ValueFreshness.warningMarker)")

        let snapshot = await item.runtimeSnapshot()
        XCTAssertEqual(snapshot.freshness.state, .failedWithValue)
        XCTAssertEqual(snapshot.fullOutput, "99")
        XCTAssertEqual(item.renderedTitle, "99%\(ValueFreshness.warningMarker)")
        XCTAssertEqual(item.renderedAccessibilityLabel, "99%, failed, showing last good value")
    }

    @MainActor
    func testNewSharedConsumerShowsLastGoodValueWhileSourceIsFailed() async throws {
        let clock = TestItemClock()
        let registry = CommandSourceRegistry()
        let log = path("late-join.log")
        let command = failAfterFirstSuccess(log: log, output: "72")
        let peer = makeItem(
            config: ItemConfig(name: "peer", run: command, interval: .scheduled(60)),
            clock: clock,
            sourceRegistry: registry
        )

        peer.refreshNow()
        let first = await waitUntil { peer.renderedTitle == "72" }
        XCTAssertTrue(first)
        await peer.awaitPrimaryRefreshForTesting()

        peer.refreshNow()
        await peer.awaitPrimaryRefreshForTesting()
        XCTAssertEqual(peer.renderedTitle, "72\(ValueFreshness.warningMarker)")

        let added = makeItem(
            config: ItemConfig(name: "added", run: command, interval: .scheduled(60)),
            clock: clock,
            sourceRegistry: registry
        )
        let snapshot = await added.runtimeSnapshot()
        XCTAssertEqual(snapshot.freshness.state, .failedWithValue)
        XCTAssertEqual(snapshot.fullOutput, "72")
        XCTAssertEqual(added.renderedTitle, "72\(ValueFreshness.warningMarker)")
        XCTAssertEqual(added.renderedAccessibilityLabel, "72, failed, showing last good value")
    }

    @MainActor
    func testSourceReplacementClearsForcedRefreshingWithoutWaitingForATick() async throws {
        let clock = TestItemClock()
        let schedulerClock = ManualSchedulerClock()
        let scheduler = CommandScheduler(maxActiveSessions: 1, clock: schedulerClock)
        let log = path("replace-source.log")
        let command = counting(log, output: "72")
        let item = makeItem(
            config: ItemConfig(name: "item", run: command, interval: .scheduled(60), timeout: 5),
            clock: clock,
            scheduler: scheduler
        )

        await item.refreshPrimaryForTesting()
        XCTAssertEqual(item.renderedTitle, "72")
        XCTAssertEqual(lineCount(log), 1)

        try await scheduler.acquirePermit()
        item.refreshNow()
        let refreshing = await waitUntil {
            item.renderedTitle == "72"
                && item.renderedAccessibilityLabel == "72, refreshing"
        }
        XCTAssertTrue(refreshing)

        await item.prepareUpdate(
            config: ItemConfig(name: "item", run: command, interval: .scheduled(60), timeout: 30),
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        item.commitPreparedUpdate()
        await scheduler.releasePermit()
        await item.awaitPrimaryRefreshForTesting()
        await item.awaitPresentationUpdateForTesting()

        XCTAssertEqual(item.renderedTitle, "72")
        XCTAssertEqual(item.renderedAccessibilityLabel, "72, fresh")
        XCTAssertEqual(lineCount(log), 1)
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
        await first.awaitPrimaryRefreshForTesting()
        await second.awaitPrimaryRefreshForTesting()
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

@MainActor
private final class FreshnessItemFactory: ManagedItemFactory {
    let clock: TestItemClock
    let scheduler: CommandScheduler
    let sourceRegistry: CommandSourceRegistry
    private(set) var created: [ManagedItem] = []

    init(
        clock: TestItemClock,
        scheduler: CommandScheduler,
        sourceRegistry: CommandSourceRegistry = CommandSourceRegistry()
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.sourceRegistry = sourceRegistry
    }

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        let item = ManagedItem(
            config: config,
            menuDelegate: menuDelegate,
            initiallyVisible: initiallyVisible,
            scheduler: scheduler,
            sourceRegistry: sourceRegistry,
            now: { self.clock.now() },
            statusItemFactory: { nil }
        )
        created.append(item)
        return item
    }
}

@MainActor
private final class FreshnessStatusItemHost: StatusItemHost {
    func makeStatusItem() -> NSStatusItem? { NSStatusItem() }
    func removeStatusItem(_ item: NSStatusItem) { item.menu = nil }
    func present(menu: NSMenu, on statusItem: NSStatusItem) {}
}
