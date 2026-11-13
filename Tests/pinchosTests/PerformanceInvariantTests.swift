import AppKit
import Darwin
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
final class HeadlessManagedItemFactory: ManagedItemFactory {
    private let scheduler: CommandScheduler
    let sourceRegistry: CommandSourceRegistry
    private(set) var created: [ManagedItem] = []

    init(
        scheduler: CommandScheduler,
        sourceRegistry: CommandSourceRegistry = CommandSourceRegistry()
    ) {
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
            statusItemFactory: { nil }
        )
        created.append(item)
        return item
    }
}

@MainActor
extension HeadlessManagedItemFactory: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

private final class TestPerfClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    func now() -> Date { date }
}

// Deterministic architectural invariants for issue #55/#49: these run in
// ordinary hosted CI (no wall-clock/RSS budgets here, see
// docs/performance.md) and prove that the number of live scheduler timer
// registrations tracks the configured item count exactly -- it must never
// grow unboundedly across reconfiguration, reordering, or removal, and
// manual-interval items must never register one at all (guarding the
// P0/P1 "no runaway timer/poll loop" budget). Before issue #49 this asserted
// against a per-item `DispatchSourceTimer` ledger; it now asserts against
// the single application-scoped `CommandScheduler`'s `registeredTimers`
// diagnostic, injected into the controller so the real
// `startTimer`/`prepareUpdate`/`prepareRemoval` code path is exercised.
@MainActor
final class PerformanceInvariantTests: XCTestCase {
    private func scheduledItem(_ name: String, run: String? = nil, interval: TimeInterval = 60) -> ItemConfig {
        ItemConfig(name: name, run: run ?? "printf ok", interval: .scheduled(interval))
    }

    private func manualItem(_ name: String) -> ItemConfig {
        ItemConfig(name: name, run: "printf ok", interval: .manual)
    }

    private func makeController(
        _ path: String,
        scheduler: CommandScheduler,
        factory: HeadlessManagedItemFactory? = nil
    ) -> StatusItemController {
        StatusItemController(
            configPath: path,
            onReload: {},
            itemFactory: factory ?? HeadlessManagedItemFactory(scheduler: scheduler),
            scheduler: scheduler
        )
    }

    /// Timer (de)registration on the scheduler actor completes asynchronously
    /// relative to the synchronous `startTimer`/`cancelRefreshTimer` call
    /// sites, so tests give it a short, fixed window to settle before
    /// asserting the live count.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    func testTimerSourceCountTracksScheduledItemsAcrossReconfigurationWithoutLeaking() async throws {
        let scheduler = CommandScheduler()
        let controller = makeController("/tmp/pinchos-perf-timer-test.toml", scheduler: scheduler)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("beta"), scheduledItem("gamma")
        ]))
        try await settle()
        var registered = await scheduler.diagnostics().registeredTimers
        XCTAssertEqual(registered, 3, "three scheduled items must hold exactly three live timer registrations")

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("beta", run: "printf changed"), scheduledItem("gamma")
        ]))
        try await settle()
        registered = await scheduler.diagnostics().registeredTimers
        XCTAssertEqual(registered, 3, "reconfiguring one item's runner must replace its timer, not add a second live one")

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("gamma")
        ]))
        try await settle()
        registered = await scheduler.diagnostics().registeredTimers
        XCTAssertEqual(registered, 2, "removing an item must cancel its timer registration, not just stop scheduling it")

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("gamma"), scheduledItem("delta"), scheduledItem("epsilon")
        ]))
        try await settle()
        registered = await scheduler.diagnostics().registeredTimers
        XCTAssertEqual(
            registered, 4,
            "four scheduled items must hold exactly four live timer registrations -- never an accumulation of every timer ever created"
        )
    }

    func testManualIntervalItemsNeverAllocateATimerSource() async throws {
        let scheduler = CommandScheduler()
        let controller = makeController("/tmp/pinchos-perf-timer-test-manual.toml", scheduler: scheduler)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [
            manualItem("alpha"), manualItem("beta"), scheduledItem("gamma")
        ]))
        try await settle()

        let registered = await scheduler.diagnostics().registeredTimers
        XCTAssertEqual(registered, 1, "only the one scheduled item should hold a timer registration")
    }

    func testShutdownCancelsEveryLiveTimerSource() async throws {
        let scheduler = CommandScheduler()
        let controller = makeController("/tmp/pinchos-perf-timer-test-shutdown.toml", scheduler: scheduler)

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("beta"), scheduledItem("gamma")
        ]))
        try await settle()
        var registered = await scheduler.diagnostics().registeredTimers
        XCTAssertEqual(registered, 3)

        await controller.shutdown()
        try await settle()
        registered = await scheduler.diagnostics().registeredTimers
        XCTAssertEqual(registered, 0, "shutdown must cancel every remaining timer registration, leaving none live")
    }

    // MARK: - Issue #129: request counts, non-blocking menus, lifecycle bounds

    func testDuplicateSourcesAcrossItemsShareOneInvocation() async throws {
        let root = try scratchRoot()
        let log = root.appendingPathComponent("shared.log")
        let command = counting(log, output: "shared")
        let scheduler = CommandScheduler(maxActiveSessions: 2)
        let factory = HeadlessManagedItemFactory(scheduler: scheduler)
        let controller = makeController(
            "/tmp/pinchos-129-reuse.toml",
            scheduler: scheduler,
            factory: factory
        )
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            ItemConfig(
                name: "alpha",
                run: command,
                interval: .manual,
                menu: [MenuRowConfig(label: "Same", run: command, cache: 60)]
            ),
            ItemConfig(name: "beta", run: command, interval: .manual)
        ]))

        let updated = await waitUntil {
            guard let alpha = self.item(named: "alpha", in: factory),
                  let beta = self.item(named: "beta", in: factory)
            else { return false }
            let alphaSnap = await alpha.runtimeSnapshot()
            let betaSnap = await beta.runtimeSnapshot()
            return alphaSnap.fullOutput == "shared"
                && betaSnap.fullOutput == "shared"
                && alpha.menuRowValue(at: 0) == "shared"
        }
        XCTAssertTrue(updated)
        XCTAssertEqual(lineCount(log), 1, "duplicate primary/menu/item consumers multiplied executions")
        XCTAssertEqual(factory.sourceRegistry.sourceCount, 1)
    }

    func testFreshMenuOpenDoesNotRefreshAndConstructionNeverWaits() async throws {
        let root = try scratchRoot()
        let cachedLog = root.appendingPathComponent("cached.log")
        let manualLog = root.appendingPathComponent("manual.log")
        let scheduler = CommandScheduler()
        let clock = TestPerfClock()
        let factory = HeadlessManagedItemFactory(scheduler: scheduler)
        let item = ManagedItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [
                    MenuRowConfig(label: "Cached", run: counting(cachedLog, output: "cached"), cache: 60),
                    MenuRowConfig(label: "Manual", run: counting(manualLog, output: "manual"))
                ]
            ),
            menuDelegate: factory,
            initiallyVisible: false,
            scheduler: scheduler,
            sourceRegistry: factory.sourceRegistry,
            now: { clock.now() },
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        _ = item.menuRowValue(at: 0)
        _ = item.menuRowValue(at: 1)
        var ready = await waitUntil { item.menuRowValue(at: 0) == "cached" && item.menuRowValue(at: 1) == "manual" }
        XCTAssertTrue(ready)
        ready = await waitUntil { item.menuRowRefreshTaskCountForTesting == 0 }
        XCTAssertTrue(ready)
        XCTAssertEqual(lineCount(cachedLog), 1)
        XCTAssertEqual(lineCount(manualLog), 1)

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
            _ = item.menuRowValue(at: 1)
        }
        XCTAssertEqual(lineCount(cachedLog), 1, "fresh cached row refreshed on menu open")
        XCTAssertEqual(lineCount(manualLog), 1, "fresh manual row refreshed on menu open")
        XCTAssertEqual(item.menuRowRefreshTaskCountForTesting, 0)

        let controller = makeController(
            "/tmp/pinchos-129-nwait.toml",
            scheduler: scheduler,
            factory: factory
        )
        addTeardownBlock { @MainActor in await controller.shutdown() }
        await controller.apply(config: PinchosConfig(items: [
            ItemConfig(
                name: "slow",
                run: "sleep 2; printf late",
                interval: .manual,
                menu: [MenuRowConfig(label: "Slow", run: "sleep 2; printf slow-row")]
            )
        ]))
        let slow = try XCTUnwrap(self.item(named: "slow", in: factory))
        let started = Date()
        let compact = await controller.makeLifecycleMenu(forManagedItem: slow, revealsDiagnostics: false)
        let collapsed = await controller.makeCollapsedMenu(revealsDiagnostics: false)
        let diagnostics = await controller.makeLifecycleMenu(forManagedItem: slow, revealsDiagnostics: true)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "menu construction waited on background command work")
        XCTAssertFalse(compact.items.isEmpty)
        XCTAssertFalse(collapsed.items.isEmpty)
        XCTAssertFalse(diagnostics.items.isEmpty)
        XCTAssertEqual(slow.menuRowValue(at: 0), nil)
        XCTAssertEqual(slow.menuRowRefreshTaskCountForTesting, 1)
    }

    func testBoundedRetriesAndManualRowRecoveryUseExactInvocationCounts() async throws {
        let root = try scratchRoot()
        let staleLog = root.appendingPathComponent("stale.log")
        let manualLog = root.appendingPathComponent("manual.log")
        let clock = TestPerfClock()
        let scheduler = CommandScheduler()
        let item = ManagedItem(
            config: ItemConfig(
                name: "item",
                run: "printf primary",
                interval: .manual,
                menu: [
                    MenuRowConfig(
                        label: "Cached",
                        run: failAfterFirstSuccess(log: staleLog, output: "good"),
                        cache: 60
                    ),
                    MenuRowConfig(
                        label: "Manual",
                        run: failAfterFirstSuccess(log: manualLog, output: "manual")
                    )
                ]
            ),
            menuDelegate: HeadlessManagedItemFactory(scheduler: scheduler),
            initiallyVisible: false,
            scheduler: scheduler,
            now: { clock.now() },
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        _ = item.menuRowValue(at: 0)
        _ = item.menuRowValue(at: 1)
        var ready = await waitUntil {
            item.menuRowValue(at: 0) == "good" && item.menuRowValue(at: 1) == "manual"
        }
        XCTAssertTrue(ready)
        ready = await waitUntil { item.menuRowRefreshTaskCountForTesting == 0 }
        XCTAssertTrue(ready)
        XCTAssertEqual(lineCount(staleLog), 1)
        XCTAssertEqual(lineCount(manualLog), 1)

        clock.date = clock.date.addingTimeInterval(61)
        _ = item.menuRowValue(at: 0)
        ready = await waitUntil { self.lineCount(staleLog) == 2 }
        XCTAssertTrue(ready)
        ready = await waitUntil { item.menuRowRefreshTaskCountForTesting == 0 }
        XCTAssertTrue(ready)

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
            _ = item.menuRowValue(at: 1)
        }
        XCTAssertEqual(lineCount(staleLog), 2, "stale failed row retried before the 30s gate")
        XCTAssertEqual(lineCount(manualLog), 1, "successful manual row recovered by opening the menu")

        item.refreshNow()
        ready = await waitUntil { self.lineCount(manualLog) == 2 && self.lineCount(staleLog) == 3 }
        XCTAssertTrue(ready)
        ready = await waitUntil { item.menuRowRefreshTaskCountForTesting == 0 }
        XCTAssertTrue(ready)
        XCTAssertEqual(item.menuRowValue(at: 1), "manual")

        for _ in 0..<8 {
            _ = item.menuRowValue(at: 0)
            _ = item.menuRowValue(at: 1)
        }
        XCTAssertEqual(lineCount(staleLog), 3)
        XCTAssertEqual(lineCount(manualLog), 2)

        clock.date = clock.date.addingTimeInterval(CommandSource.retryInterval)
        _ = item.menuRowValue(at: 0)
        _ = item.menuRowValue(at: 1)
        ready = await waitUntil { self.lineCount(staleLog) == 4 && self.lineCount(manualLog) == 3 }
        XCTAssertTrue(ready, "cadence retry did not run both failed rows")
    }

    func testFairBoundedConcurrencyCapsExactInvocations() async throws {
        let root = try scratchRoot()
        let activeDir = root.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("runs.log")
        let scheduler = CommandScheduler(maxActiveSessions: 2)
        let factory = HeadlessManagedItemFactory(scheduler: scheduler)
        let controller = makeController(
            "/tmp/pinchos-129-fair.toml",
            scheduler: scheduler,
            factory: factory
        )
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let items = (0..<5).map { index in
            ItemConfig(
                name: "item-\(index)",
                run: fairCommand(activeDir: activeDir, log: log, index: index),
                interval: .manual
            )
        }
        await controller.apply(config: PinchosConfig(items: items))

        var peak = 0
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            peak = max(peak, activeSlotCount(activeDir))
            let diagnostics = await scheduler.diagnostics()
            if lineCount(log) >= 5, diagnostics.activeSessions == 0, diagnostics.queuedSessions == 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let allRan = await waitUntil(timeout: 6) {
            let diagnostics = await scheduler.diagnostics()
            return self.lineCount(log) == 5
                && diagnostics.activeSessions == 0
                && diagnostics.queuedSessions == 0
        }
        XCTAssertTrue(allRan)
        XCTAssertEqual(lineCount(log), 5, "each item must run exactly once")
        XCTAssertLessThanOrEqual(peak, 2, "peak in-flight commands exceeded the scheduler cap")
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 0)
        XCTAssertEqual(diagnostics.queuedSessions, 0)
    }

    func testRepeatedLifecycleWhileCommandsRunDoesNotAccumulateResources() async throws {
        let root = try scratchRoot()
        let token = UUID().uuidString
        let pidDir = root.appendingPathComponent("pids", isDirectory: true)
        try FileManager.default.createDirectory(at: pidDir, withIntermediateDirectories: true)
        let scheduler = CommandScheduler(maxActiveSessions: 2)
        let factory = HeadlessManagedItemFactory(scheduler: scheduler)
        let controller = makeController(
            "/tmp/pinchos-129-lifecycle.toml",
            scheduler: scheduler,
            factory: factory
        )

        func slowItem(_ name: String) -> ItemConfig {
            let pidFile = pidDir.appendingPathComponent("\(name).pid")
            return ItemConfig(
                name: name,
                run: "printf $$ > '\(pidFile.path)'; sleep 30; printf \(name)-\(token)",
                interval: .scheduled(60)
            )
        }

        let baselineFDs = openDescriptorCount()
        await controller.apply(config: PinchosConfig(items: [
            slowItem("alpha"), slowItem("beta"), slowItem("gamma")
        ]))
        try await settle()
        var timers = await scheduler.diagnostics()
        XCTAssertEqual(timers.registeredTimers, 3)

        await controller.apply(config: PinchosConfig(items: [
            slowItem("alpha"), slowItem("gamma"), slowItem("delta")
        ]))
        try await settle()
        timers = await scheduler.diagnostics()
        XCTAssertEqual(timers.registeredTimers, 3)

        await controller.apply(config: PinchosConfig(items: [
            slowItem("delta"), slowItem("alpha"), slowItem("epsilon"), slowItem("gamma")
        ]))
        try await settle()
        var diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.registeredTimers, 4)

        let menu = await controller.makeLifecycleMenu(
            forManagedItem: factory.created.last,
            revealsDiagnostics: false
        )
        let menuTargets = menu.items.filter { $0.representedObject != nil || $0.target != nil }.count
        XCTAssertGreaterThan(menuTargets, 0)

        await controller.apply(config: PinchosConfig(items: [
            slowItem("alpha"), slowItem("gamma")
        ]))
        try await settle()
        diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.registeredTimers, 2)

        await controller.shutdown()
        try await settle()
        diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.registeredTimers, 0, "shutdown left timers registered")
        XCTAssertEqual(diagnostics.activeSessions, 0)
        XCTAssertEqual(diagnostics.queuedSessions, 0)
        XCTAssertEqual(factory.sourceRegistry.sourceCount, 0, "shutdown left command sources retained")

        let gone = await waitUntil(timeout: 4) { self.leftoverSlowPids(in: pidDir).isEmpty }
        XCTAssertTrue(gone, "shutdown left descendants \(leftoverSlowPids(in: pidDir))")
        let settledFDs = openDescriptorCount()
        XCTAssertLessThanOrEqual(
            settledFDs,
            baselineFDs + 8,
            "repeated reload/add/remove/reorder/shutdown accumulated descriptors (\(settledFDs) vs \(baselineFDs))"
        )
    }

    func testRetainedCacheAndMenuSnapshotSizesAreMeasuredSeparatelyFromActiveBudget() async throws {
        let produced = 32 * 1024
        let scheduler = CommandScheduler()
        let factory = HeadlessManagedItemFactory(scheduler: scheduler)
        let controller = makeController(
            "/tmp/pinchos-129-cache-ui.toml",
            scheduler: scheduler,
            factory: factory
        )
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let items = (0..<5).map { index in
            ItemConfig(
                name: "blob-\(index)",
                run: "head -c \(produced) /dev/zero | tr '\\0' '\(index)'",
                interval: .manual,
                menu: [
                    MenuRowConfig(
                        label: "Copy",
                        run: "head -c \(produced) /dev/zero | tr '\\0' '\(index)'",
                        cache: 60
                    )
                ]
            )
        }
        await controller.apply(config: PinchosConfig(items: items))
        let blobsReady = await waitUntil(timeout: 8) {
            var ready = 0
            for item in factory.created.suffix(5) {
                let snapshot = await item.runtimeSnapshot()
                if snapshot.fullOutput?.utf8.count == produced, item.menuRowValue(at: 0) != nil {
                    ready += 1
                }
            }
            return ready == 5
        }
        XCTAssertTrue(blobsReady)

        var cacheBytes = 0
        var snapshotBytes = 0
        var menuTitleBytes = 0
        for item in factory.created.suffix(5) {
            let snapshot = await item.runtimeSnapshot()
            cacheBytes += retainedSnapshotUTF8Bytes(snapshot)
            if let cached = item.menuRowCachedValueForTesting(at: 0) {
                cacheBytes += retainedCachedValueUTF8Bytes(cached)
            }
            snapshotBytes += snapshot.fullOutput?.utf8.count ?? 0
            let menu = await controller.makeLifecycleMenu(forManagedItem: item, revealsDiagnostics: true)
            menuTitleBytes += menu.items.reduce(0) { $0 + $1.title.utf8.count }
        }

        XCTAssertGreaterThan(cacheBytes, 0)
        XCTAssertLessThan(
            menuTitleBytes,
            16 * 1024,
            "UI snapshot/menu titles must stay a small bound independent of completed-cache Strings"
        )
        XCTAssertLessThan(
            snapshotBytes,
            5 * 64 * 1024 + 1,
            "completed primary values must stay inside the per-runner 64 KiB cap, not the 8 MiB active budget"
        )
        XCTAssertEqual(factory.sourceRegistry.sourceCount, 5, "duplicate primary/menu commands must share one source per item")
    }

    private func item(named name: String, in factory: HeadlessManagedItemFactory) -> ManagedItem? {
        factory.created.last { $0.config.name == name }
    }

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-129-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
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

    private func fairCommand(activeDir: URL, log: URL, index: Int) -> String {
        let slot = activeDir.appendingPathComponent("\(index).slot")
        return """
        printf x > '\(slot.path)'; \
        sleep 0.2; \
        rm -f '\(slot.path)'; \
        printf 'x\\n' >> '\(log.path)'; \
        printf ok-\(index)
        """
    }

    private func activeSlotCount(_ activeDir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: activeDir.path)
            .filter { $0.hasSuffix(".slot") }.count) ?? 0
    }

    private func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    private func leftoverSlowPids(in pidDir: URL) -> [Int32] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pidDir.path)) ?? []
        var live: [Int32] = []
        for name in names {
            guard let text = try? String(
                contentsOf: pidDir.appendingPathComponent(name),
                encoding: .utf8
            ) else { continue }
            guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if kill(pid, 0) == 0 {
                live.append(pid)
            }
        }
        return live
    }

    private func retainedSnapshotUTF8Bytes(_ snapshot: ItemRuntimeSnapshot) -> Int {
        (snapshot.fullOutput?.utf8.count ?? 0)
            + (snapshot.lastExecution?.stdout.utf8.count ?? 0)
            + (snapshot.lastExecution?.stderr.utf8.count ?? 0)
    }

    private func retainedCachedValueUTF8Bytes(_ cached: CachedValue) -> Int {
        (cached.value?.utf8.count ?? 0)
            + (cached.lastExecution?.stdout.utf8.count ?? 0)
            + (cached.lastExecution?.stderr.utf8.count ?? 0)
            + (cached.diagnostic?.utf8.count ?? 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 4,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
