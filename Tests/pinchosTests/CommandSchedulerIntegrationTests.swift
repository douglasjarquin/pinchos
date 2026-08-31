import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
final class HeadlessManagedItemFactory: ManagedItemFactory {
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

    @MainActor
    private func makeController(_ label: String, scheduler: CommandScheduler) -> StatusItemController {
        StatusItemController(
            configPath: "/tmp/pinchos-scheduler-\(label)-\(UUID().uuidString).toml",
            onReload: {},
            itemFactory: HeadlessManagedItemFactory(scheduler: scheduler),
            scheduler: scheduler
        )
    }

    @MainActor
    func testManyItemsShareTheFixedGlobalConcurrencyLimit() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 2)
        let controller = makeController("limit", scheduler: scheduler)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let items = (0..<6).map { manualItem("item\($0)", run: "sleep 0.3; printf ok") }
        await controller.apply(config: PinchosConfig(items: items))

        var observedPeak = 0
        var reachedLimit = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let diagnostics = await scheduler.diagnostics()
            observedPeak = max(observedPeak, diagnostics.activeSessions)
            reachedLimit = reachedLimit || diagnostics.activeSessions == 2
            XCTAssertLessThanOrEqual(
                diagnostics.queuedSessions,
                items.count - diagnostics.activeSessions,
                "each item may hold at most one outstanding refresh request"
            )
            if diagnostics.activeSessions == 0, reachedLimit { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertLessThanOrEqual(observedPeak, 2)
        XCTAssertTrue(reachedLimit, "the fixed limit should permit real parallelism")
    }

    @MainActor
    func testRemovingAnItemQueuedForAPermitCancelsWithoutRunningIt() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-scheduler-victim-\(UUID().uuidString)")
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        let controller = makeController("remove", scheduler: scheduler)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
            try? FileManager.default.removeItem(at: marker)
        }

        let hog = manualItem("hog", run: "sleep 1")
        let victim = manualItem("victim", run: "touch '\(marker.path)'")
        await controller.apply(config: PinchosConfig(items: [hog, victim]))

        let deadline = Date().addingTimeInterval(2)
        var saturated = false
        while Date() < deadline {
            let diagnostics = await scheduler.diagnostics()
            if diagnostics.activeSessions == 1, diagnostics.queuedSessions == 1 {
                saturated = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(saturated)

        let clock = ContinuousClock()
        let start = clock.now
        await controller.apply(config: PinchosConfig(items: [hog]))
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))

        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testShutdownDrainsActiveAndQueuedPermits() async throws {
        let scheduler = CommandScheduler(maxActiveSessions: 1)
        let controller = makeController("shutdown", scheduler: scheduler)
        let items = (0..<5).map { manualItem("item\($0)", run: "sleep 1") }
        await controller.apply(config: PinchosConfig(items: items))

        let deadline = Date().addingTimeInterval(2)
        var saturated = false
        while Date() < deadline {
            let diagnostics = await scheduler.diagnostics()
            if diagnostics.activeSessions == 1, diagnostics.queuedSessions == 4 {
                saturated = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(saturated)

        await controller.shutdown()

        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.activeSessions, 0)
        XCTAssertEqual(diagnostics.queuedSessions, 0)
    }
}
