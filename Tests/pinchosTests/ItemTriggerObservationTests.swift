import AppKit
import XCTest
import PinchosCore
@testable import pinchos

@MainActor
private final class FakeTriggerObserver: ItemTriggerObserver {
    let source: ItemTriggerSource
    private let onEvent: () -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(source: ItemTriggerSource, onEvent: @escaping () -> Void) {
        self.source = source
        self.onEvent = onEvent
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit() {
        onEvent()
    }
}

@MainActor
private final class FakeTriggerObserverFactory: ItemTriggerObserverFactory {
    private(set) var observers: [ItemTriggerSource: FakeTriggerObserver] = [:]

    func makeObserver(
        for source: ItemTriggerSource,
        onEvent: @escaping @MainActor () -> Void
    ) -> any ItemTriggerObserver {
        let observer = FakeTriggerObserver(source: source, onEvent: onEvent)
        observers[source] = observer
        return observer
    }
}

@MainActor
final class ItemTriggerObservationTests: XCTestCase {
    private final class NoopMenuDelegate: StatusItemMenuDelegate {
        func showLifecycleMenu(for statusItem: NSStatusItem) {}
    }

    private func config(
        triggers: Set<ItemTrigger> = [],
        watch: [String] = []
    ) -> CommandItemConfig {
        CommandItemConfig(
            name: "example",
            run: "echo status",
            interval: .manual,
            triggers: triggers,
            watch: watch
        )
    }

    func testEquivalentEventsAreDebouncedPerSource() async throws {
        let factory = FakeTriggerObserverFactory()
        var refreshCount = 0
        let coordinator = ItemTriggerCoordinator(
            config: config(watch: ["/tmp/status.json"]),
            observerFactory: factory,
            debounce: .milliseconds(20),
            onRefresh: { refreshCount += 1 }
        )
        coordinator.start()

        let watcher = try XCTUnwrap(factory.observers[.file("/tmp/status.json")])
        watcher.emit()
        watcher.emit()
        watcher.emit()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(refreshCount, 1)
    }

    func testDistinctSourcesCanRequestIndependentRefreshes() async throws {
        let factory = FakeTriggerObserverFactory()
        var refreshCount = 0
        let coordinator = ItemTriggerCoordinator(
            config: config(triggers: [.wake], watch: ["/tmp/status.json"]),
            observerFactory: factory,
            debounce: .milliseconds(20),
            onRefresh: { refreshCount += 1 }
        )
        coordinator.start()

        factory.observers[.wake]?.emit()
        factory.observers[.file("/tmp/status.json")]?.emit()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(refreshCount, 2)
    }

    func testInstallsEveryConfiguredInitialTriggerSource() throws {
        let factory = FakeTriggerObserverFactory()
        let coordinator = ItemTriggerCoordinator(
            config: config(
                triggers: [.startup, .wake, .networkChange],
                watch: ["/tmp/status.json"]
            ),
            observerFactory: factory,
            debounce: .milliseconds(20),
            onRefresh: {}
        )
        coordinator.start()

        XCTAssertEqual(
            Set(factory.observers.keys),
            [.startup, .wake, .networkChange, .file("/tmp/status.json")]
        )
        XCTAssertEqual(factory.observers[.startup]?.startCount, 1)
        XCTAssertEqual(factory.observers[.wake]?.startCount, 1)
        XCTAssertEqual(factory.observers[.networkChange]?.startCount, 1)
        XCTAssertEqual(factory.observers[.file("/tmp/status.json")]?.startCount, 1)
    }

    func testUpdateRetainsUnchangedObserversAndStopsRemovedOnes() throws {
        let factory = FakeTriggerObserverFactory()
        let coordinator = ItemTriggerCoordinator(
            config: config(triggers: [.wake], watch: ["/tmp/old.json", "/tmp/kept.json"]),
            observerFactory: factory,
            debounce: .milliseconds(20),
            onRefresh: {}
        )
        coordinator.start()

        let kept = try XCTUnwrap(factory.observers[.file("/tmp/kept.json")])
        let removed = try XCTUnwrap(factory.observers[.file("/tmp/old.json")])
        coordinator.update(config: config(triggers: [.networkChange], watch: ["/tmp/kept.json", "/tmp/new.json"]))

        XCTAssertTrue(factory.observers[.file("/tmp/kept.json")] === kept)
        XCTAssertEqual(removed.stopCount, 1)
        XCTAssertEqual(factory.observers[.wake]?.stopCount, 1)
        XCTAssertEqual(factory.observers[.networkChange]?.startCount, 1)
        XCTAssertEqual(factory.observers[.file("/tmp/new.json")]?.startCount, 1)
    }

    func testStopUnregistersObserversAndSuppressesPendingRefresh() async throws {
        let factory = FakeTriggerObserverFactory()
        var refreshCount = 0
        let coordinator = ItemTriggerCoordinator(
            config: config(watch: ["/tmp/status.json"]),
            observerFactory: factory,
            debounce: .milliseconds(20),
            onRefresh: { refreshCount += 1 }
        )
        coordinator.start()

        let watcher = try XCTUnwrap(factory.observers[.file("/tmp/status.json")])
        watcher.emit()
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(watcher.stopCount, 1)
        XCTAssertEqual(refreshCount, 0)
    }

    func testManagedItemEventRefreshUsesTheExistingRunnerGate() async throws {
        let factory = FakeTriggerObserverFactory()
        let item = ManagedItem(
            config: .command(config(watch: ["/tmp/status.json"])),
            menuDelegate: NoopMenuDelegate(),
            initiallyVisible: false,
            triggerObserverFactory: factory,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.activate()
        let watcher = try XCTUnwrap(factory.observers[.file("/tmp/status.json")])
        watcher.emit()

        for _ in 0..<100 {
            if (await item.runnerSnapshot()).lastExecution != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("event trigger did not reach the managed item's refresh runner")
    }

    func testEventRefreshCoexistsWithPollingWithoutOverlappingRuns() async throws {
        let factory = FakeTriggerObserverFactory()
        let item = ManagedItem(
            config: .command(
                CommandItemConfig(
                    name: "example",
                    run: "sleep 0.3; printf event",
                    interval: .scheduled(0.05),
                    watch: ["/tmp/status.json"]
                )
            ),
            menuDelegate: NoopMenuDelegate(),
            initiallyVisible: false,
            triggerObserverFactory: factory,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.activate()
        let watcher = try XCTUnwrap(factory.observers[.file("/tmp/status.json")])
        watcher.emit()

        for _ in 0..<120 {
            let snapshot = await item.runnerSnapshot()
            if snapshot.lastExecution != nil {
                XCTAssertGreaterThan(snapshot.skippedRefreshes, 0)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("polling and event refresh did not settle")
    }

    func testManagedItemReloadReconfiguresOnlyChangedObservers() async throws {
        let factory = FakeTriggerObserverFactory()
        let initialConfig = config(watch: ["/tmp/old.json", "/tmp/kept.json"])
        let item = ManagedItem(
            config: .command(initialConfig),
            menuDelegate: NoopMenuDelegate(),
            initiallyVisible: false,
            triggerObserverFactory: factory,
            statusItemFactory: { nil }
        )
        item.activate()

        let kept = try XCTUnwrap(factory.observers[.file("/tmp/kept.json")])
        let removed = try XCTUnwrap(factory.observers[.file("/tmp/old.json")])
        let updatedConfig = config(watch: ["/tmp/kept.json", "/tmp/new.json"])

        await item.prepareUpdate(config: .command(updatedConfig))
        item.commitPreparedUpdate()

        XCTAssertTrue(factory.observers[.file("/tmp/kept.json")] === kept)
        XCTAssertEqual(removed.stopCount, 1)
        XCTAssertEqual(factory.observers[.file("/tmp/new.json")]?.startCount, 1)
        await item.tearDown()
    }

    func testManagedItemRemovalStopsAllObservers() async throws {
        let factory = FakeTriggerObserverFactory()
        let item = ManagedItem(
            config: .command(config(triggers: [.wake], watch: ["/tmp/status.json"])),
            menuDelegate: NoopMenuDelegate(),
            initiallyVisible: false,
            triggerObserverFactory: factory,
            statusItemFactory: { nil }
        )
        item.activate()

        let wake = try XCTUnwrap(factory.observers[.wake])
        let watcher = try XCTUnwrap(factory.observers[.file("/tmp/status.json")])
        await item.tearDown()

        XCTAssertEqual(wake.stopCount, 1)
        XCTAssertEqual(watcher.stopCount, 1)
    }
}
