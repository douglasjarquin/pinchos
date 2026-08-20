import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

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

    private func makeController(_ path: String, scheduler: CommandScheduler) -> StatusItemController {
        StatusItemController(
            configPath: path,
            onReload: {},
            itemFactory: HeadlessManagedItemFactory(scheduler: scheduler),
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
}
