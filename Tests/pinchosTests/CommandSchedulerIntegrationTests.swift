import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

/// Issue #49: integration coverage for the one application-scoped
/// `CommandScheduler` wired through `StatusItemController`/`ManagedItem`,
/// using real `ManagedItem`s through a headless factory and real shell
/// commands rather than a fake, complementing `CommandSchedulerTests` (which
/// exercises the scheduler actor itself in isolation).
@MainActor
private final class HeadlessManagedItemFactory: ManagedItemFactory {
    private let scheduler: CommandScheduler

    init(scheduler: CommandScheduler) {
        self.scheduler = scheduler
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
            scheduler: scheduler,
            statusItemFactory: { nil }
        )
    }
}

final class CommandSchedulerIntegrationTests: XCTestCase {
    private func manualItem(_ name: String, run: String) -> ItemConfig {
        ItemConfig(name: name, run: run, interval: .manual)
    }

    private func uniqueConfigPath(_ label: String) -> String {
        "/tmp/pinchos-scheduler-integration-\(label)-\(UUID().uuidString).toml"
    }

    @MainActor
    private func makeController(_ label: String, scheduler: CommandScheduler) -> StatusItemController {
        StatusItemController(
            configPath: uniqueConfigPath(label),
            onReload: {},
            itemFactory: HeadlessManagedItemFactory(scheduler: scheduler),
            scheduler: scheduler
        )
    }

    /// Six manual items, each triggering an initial refresh on activation,
    /// share one two-permit scheduler. This proves both halves of bounded
    /// concurrency: the peak never exceeds the configured limit, and the
    /// limit is actually reached (real parallelism), not silently
    /// serialized down to one.
    @MainActor
    func testManyItemsAcrossOneControllerNeverExceedTheConfiguredActiveSessionLimit() async throws {
        let scheduler = CommandScheduler()
        let controller = makeController("fairness", scheduler: scheduler)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        // `apply(config:)` always applies `config.scheduler` (see the
        // "reload-with-only-scheduler-change" tests below), so the limit
        // for this test is set through the config, the same path a real
        // `[scheduler]` override in `pinchos.toml` would take.
        let items = (0..<6).map { manualItem("item\($0)", run: "sleep 0.3; printf ok") }
        await controller.apply(config: PinchosConfig(items: items, scheduler: SchedulerConfig(maxActiveSessions: 2)))

        var observedPeak = 0
        var reachedTheLimit = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let diagnostics = await scheduler.diagnostics()
            observedPeak = max(observedPeak, diagnostics.activeSessions)
            if diagnostics.activeSessions >= 2 {
                reachedTheLimit = true
            }
            // Fairness: at most one outstanding permit request per item, so
            // the queue can never grow past (item count - active sessions).
            XCTAssertLessThanOrEqual(
                diagnostics.queuedSessions, items.count - diagnostics.activeSessions,
                "queue depth must stay bounded by one outstanding request per item"
            )
            if diagnostics.activeSessions == 0 && reachedTheLimit {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertLessThanOrEqual(observedPeak, 2, "six items sharing one scheduler must never exceed the configured limit")
        XCTAssertTrue(reachedTheLimit, "the configured limit should actually be reached, proving real concurrency")
    }

    /// A config reload that only touches `[scheduler]` (no item added,
    /// removed, or changed) must still take effect: `StatusItemController`
    /// applies the scheduler limit unconditionally, ahead of the item diff.
    @MainActor
    func testConfigReloadAppliesANewSchedulerLimitEvenWhenNoItemChanges() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 4)
        let controller = makeController("limit-only-reload", scheduler: scheduler)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        let items = [manualItem("alpha", run: "printf ok")]
        await controller.apply(config: PinchosConfig(items: items, scheduler: SchedulerConfig(maxActiveSessions: 4)))
        var diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.maxActiveSessions, 4)

        await controller.apply(config: PinchosConfig(items: items, scheduler: SchedulerConfig(maxActiveSessions: 1)))
        diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.maxActiveSessions, 1, "the same, unchanged item list must not block the scheduler-only change")
    }

    /// Omitting `[scheduler]` on a later reload is "no override", not
    /// "keep whatever the previous reload set" -- it must revert to the
    /// documented default.
    @MainActor
    func testConfigReloadWithoutASchedulerSectionRevertsToTheDefaultLimit() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 4)
        let controller = makeController("revert-to-default", scheduler: scheduler)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        let items = [manualItem("alpha", run: "printf ok")]
        await controller.apply(config: PinchosConfig(items: items, scheduler: SchedulerConfig(maxActiveSessions: 1)))
        var diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.maxActiveSessions, 1)

        await controller.apply(config: PinchosConfig(items: items))
        diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.maxActiveSessions, CommandScheduler.defaultMaxActiveSessions)
    }

    /// Removing an item whose refresh is only queued for a permit (another
    /// item is occupying the sole permit) must cancel that queued request
    /// promptly -- bounded by cancellation/settlement overhead, not by
    /// whatever is holding the permit -- and the removed item's command
    /// must never run.
    @MainActor
    func testRemovingAnItemQueuedForAPermitCancelsPromptlyAndNeverRunsItsCommand() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-scheduler-removed-queued-\(UUID().uuidString)")
        let scheduler = CommandScheduler()
        let controller = makeController("removed-while-queued", scheduler: scheduler)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
            try? FileManager.default.removeItem(at: marker)
        }

        let hog = manualItem("hog", run: "sleep 1")
        let victim = manualItem("victim", run: "touch '\(marker.path)'")
        let schedulerConfig = SchedulerConfig(maxActiveSessions: 1)
        await controller.apply(config: PinchosConfig(items: [hog, victim], scheduler: schedulerConfig))

        // Wait for the hog to occupy the only permit and the victim to be
        // queued behind it.
        let saturatedDeadline = Date().addingTimeInterval(2)
        var saturated = false
        while Date() < saturatedDeadline {
            let diagnostics = await scheduler.diagnostics()
            if diagnostics.activeSessions == 1, diagnostics.queuedSessions == 1 {
                saturated = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(saturated, "expected the hog to hold the permit with the victim queued behind it")

        let clock = ContinuousClock()
        let started = clock.now
        await controller.apply(config: PinchosConfig(items: [hog], scheduler: schedulerConfig))
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(
            elapsed, .milliseconds(500),
            "removing a queued item must not block on the hog's ~1s permit hold"
        )

        // Give the hog's sleep time to finish (and, if this regressed, time
        // for a wrongly-un-cancelled victim to run) before asserting.
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a queued refresh must not run after its item was removed"
        )
    }

    /// Shutdown must drain every item's queued scheduler permit request as
    /// well as its active one, leaving the scheduler itself completely
    /// idle -- not just each item's own runner quiesced.
    @MainActor
    func testShutdownDrainsQueuedAndActiveSchedulerPermitsAcrossAllItems() async throws {
        let scheduler = CommandScheduler()
        let controller = makeController("shutdown-drains-queue", scheduler: scheduler)

        let items = (0..<5).map { manualItem("item\($0)", run: "sleep 1") }
        await controller.apply(config: PinchosConfig(items: items, scheduler: SchedulerConfig(maxActiveSessions: 1)))

        let saturatedDeadline = Date().addingTimeInterval(2)
        var saturated = false
        while Date() < saturatedDeadline {
            let diagnostics = await scheduler.diagnostics()
            if diagnostics.activeSessions == 1, diagnostics.queuedSessions == 4 {
                saturated = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(saturated, "expected one item active and the other four queued behind it")

        await controller.shutdown()

        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 0, "shutdown must release the active permit")
        XCTAssertEqual(diagnostics.queuedSessions, 0, "shutdown must cancel every queued permit request")
    }
}
