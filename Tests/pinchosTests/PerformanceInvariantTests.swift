import AppKit
import Dispatch
import XCTest
@testable import PinchosCore
@testable import pinchos

// Deterministic architectural invariants for issue #55: these run in ordinary
// hosted CI (no wall-clock/RSS budgets here, see docs/performance.md) and prove
// that the number of live `DispatchSourceTimer` sources tracks the configured
// item count exactly -- it must never grow unboundedly across reconfiguration,
// reordering, or removal, and manual-interval items must never allocate one at
// all (guarding the P0/P1 "no runaway timer/poll loop" budget).

/// Counts live vs. ever-created timer sources so tests can assert both "no
/// leak" (live count settles back down) and "no accumulation" (live count
/// never exceeds the number of currently scheduled items).
private final class TimerSourceLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var liveCount = 0
    private var totalCreated = 0
    private var peakLiveCount = 0

    var live: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveCount
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCreated
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakLiveCount
    }

    func recordCreated() {
        lock.lock()
        totalCreated += 1
        liveCount += 1
        peakLiveCount = max(peakLiveCount, liveCount)
        lock.unlock()
    }

    func recordCancelled() {
        lock.lock()
        liveCount -= 1
        lock.unlock()
    }
}

private func ledgeredTimerFactory(_ ledger: TimerSourceLedger) -> (DispatchQueue) -> DispatchSourceTimer {
    { queue in
        let timer = DispatchSource.makeTimerSource(queue: queue)
        ledger.recordCreated()
        timer.setCancelHandler { ledger.recordCancelled() }
        return timer
    }
}

@MainActor
private final class NoopStatusItemMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

/// Builds real `ManagedItem`s (not a fake) so the timer bookkeeping under
/// test is the production `startTimer`/`prepareUpdate`/`prepareRemoval` code
/// path, with the timer source and status item swapped for headless-safe
/// test doubles.
@MainActor
private final class LedgeredManagedItemFactory: ManagedItemFactory {
    private let ledger: TimerSourceLedger

    init(ledger: TimerSourceLedger) {
        self.ledger = ledger
    }

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        ManagedItem(
            config: config,
            menuDelegate: menuDelegate,
            initiallyVisible: initiallyVisible,
            timerFactory: ledgeredTimerFactory(ledger),
            statusItemFactory: { nil }
        )
    }
}

@MainActor
final class PerformanceInvariantTests: XCTestCase {
    private func scheduledItem(_ name: String, run: String? = nil, interval: TimeInterval = 60) -> ItemConfig {
        ItemConfig(name: name, run: run ?? "printf ok", interval: .scheduled(interval))
    }

    private func manualItem(_ name: String) -> ItemConfig {
        ItemConfig(name: name, run: "printf ok", interval: .manual)
    }

    /// Timer cancellation runs its handler asynchronously on the item's timer
    /// queue, so tests give it a short, fixed window to settle before
    /// asserting the live count -- the same pattern already used by
    /// RecoveryLifecycleTests for timer-factory-invocation assertions.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    func testTimerSourceCountTracksScheduledItemsAcrossReconfigurationWithoutLeaking() async throws {
        let ledger = TimerSourceLedger()
        let controller = StatusItemController(
            configPath: "/tmp/pinchos-perf-timer-test.toml",
            onReload: {},
            itemFactory: LedgeredManagedItemFactory(ledger: ledger)
        )
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("beta"), scheduledItem("gamma")
        ]))
        try await settle()
        XCTAssertEqual(ledger.live, 3, "three scheduled items must hold exactly three live timer sources")

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("beta", run: "printf changed"), scheduledItem("gamma")
        ]))
        try await settle()
        XCTAssertEqual(ledger.live, 3, "reconfiguring one item's runner must replace its timer, not add a second live one")

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("gamma")
        ]))
        try await settle()
        XCTAssertEqual(ledger.live, 2, "removing an item must cancel its timer source, not just stop scheduling it")

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("gamma"), scheduledItem("delta"), scheduledItem("epsilon")
        ]))
        try await settle()
        XCTAssertEqual(
            ledger.live, 4,
            "four scheduled items must hold exactly four live timer sources -- never an accumulation of every timer ever created"
        )
        XCTAssertGreaterThan(ledger.total, ledger.live, "reconfiguration and removal above must have created and cancelled timers along the way")
    }

    func testManualIntervalItemsNeverAllocateATimerSource() async throws {
        let ledger = TimerSourceLedger()
        let controller = StatusItemController(
            configPath: "/tmp/pinchos-perf-timer-test-manual.toml",
            onReload: {},
            itemFactory: LedgeredManagedItemFactory(ledger: ledger)
        )
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [
            manualItem("alpha"), manualItem("beta"), scheduledItem("gamma")
        ]))
        try await settle()

        XCTAssertEqual(ledger.live, 1, "only the one scheduled item should hold a timer source")
        XCTAssertEqual(ledger.total, 1, "manual-interval items must never call the timer factory at all")
    }

    func testShutdownCancelsEveryLiveTimerSource() async throws {
        let ledger = TimerSourceLedger()
        let controller = StatusItemController(
            configPath: "/tmp/pinchos-perf-timer-test-shutdown.toml",
            onReload: {},
            itemFactory: LedgeredManagedItemFactory(ledger: ledger)
        )

        await controller.apply(config: PinchosConfig(items: [
            scheduledItem("alpha"), scheduledItem("beta"), scheduledItem("gamma")
        ]))
        try await settle()
        XCTAssertEqual(ledger.live, 3)

        await controller.shutdown()
        try await settle()
        XCTAssertEqual(ledger.live, 0, "shutdown must cancel every remaining timer source, leaving none live")
    }
}
