import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
private final class FakeManagedItem: ManagedItemLifecycle {
    private let eventLog: EventLog
    private var pendingConfig: ItemConfig?
    private(set) var config: ItemConfig
    let initiallyVisible: Bool

    init(config: ItemConfig, eventLog: EventLog, initiallyVisible: Bool) {
        self.config = config
        self.eventLog = eventLog
        self.initiallyVisible = initiallyVisible
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        false
    }

    func activate() {
        eventLog.append("activate:\(config.name)")
    }

    func prepareUpdate(config: ItemConfig) async {
        pendingConfig = config
        eventLog.append("prepare-update:\(config.name)")
    }

    func commitPreparedUpdate() {
        config = pendingConfig!
        pendingConfig = nil
        eventLog.append("commit-update:\(config.name)")
    }

    func prepareRemoval() async {
        eventLog.append("prepare-removal:\(config.name)")
    }

    func commitRemoval() {
        eventLog.append("commit-removal:\(config.name)")
    }

    func tearDown() async {
        await prepareRemoval()
        commitRemoval()
    }

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        CommandRunnerSnapshot(isRunning: false, lastExecution: nil, skippedRefreshes: 0)
    }
}

@MainActor
private final class EventLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func clear() {
        events.removeAll()
    }
}

@MainActor
private final class FakeManagedItemFactory: ManagedItemFactory {
    let eventLog = EventLog()
    private(set) var created: [FakeManagedItem] = []

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        let item = FakeManagedItem(
            config: config,
            eventLog: eventLog,
            initiallyVisible: initiallyVisible
        )
        created.append(item)
        return item
    }
}

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private func item(_ name: String, run: String? = nil) -> ItemConfig {
        ItemConfig(name: name, run: run ?? "echo \(name)", interval: 60)
    }

    private func makeController(factory: FakeManagedItemFactory) -> StatusItemController {
        StatusItemController(
            configPath: "/tmp/pinchos-test.toml",
            onReload: {},
            itemFactory: factory
        )
    }

    func testNoOpReloadLeavesManagedItemsUntouched() async {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        let config = PinchosConfig(items: [item("alpha"), item("beta")])

        await controller.apply(config: config)
        let initialItems = factory.created
        factory.eventLog.clear()

        await controller.apply(config: config)

        XCTAssertEqual(factory.created.count, initialItems.count)
        XCTAssertTrue(factory.eventLog.events.isEmpty)
        XCTAssertTrue(zip(initialItems, factory.created).allSatisfy { $0 === $1 })
    }

    func testModifyUpdatesOnlyTheChangedManagedItem() async {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [item("alpha"), item("beta")]))
        let alpha = factory.created[0]
        let beta = factory.created[1]
        factory.eventLog.clear()

        await controller.apply(
            config: PinchosConfig(items: [item("alpha"), item("beta", run: "echo changed")])
        )

        XCTAssertTrue(factory.created[0] === alpha)
        XCTAssertTrue(factory.created[1] === beta)
        XCTAssertEqual(factory.eventLog.events, [
            "prepare-update:beta",
            "commit-update:beta"
        ])
        XCTAssertEqual(beta.config.run, "echo changed")
    }

    func testAddAndRemoveCommitAfterAllPreparation() async {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [item("alpha"), item("beta")]))
        let alpha = factory.created[0]
        let beta = factory.created[1]
        factory.eventLog.clear()

        await controller.apply(
            config: PinchosConfig(items: [item("alpha", run: "echo changed"), item("gamma")])
        )

        XCTAssertTrue(factory.created[0] === alpha)
        XCTAssertTrue(beta !== factory.created[2])
        XCTAssertEqual(factory.created[2].config.name, "gamma")
        XCTAssertFalse(factory.created[2].initiallyVisible)
        XCTAssertEqual(factory.eventLog.events, [
            "prepare-update:alpha",
            "prepare-removal:beta",
            "commit-removal:beta",
            "commit-update:alpha",
            "activate:gamma"
        ])
    }

    func testReorderRebuildsAllManagedItemsInOneCommit() async {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [item("alpha"), item("beta")]))
        let oldItems = factory.created
        factory.eventLog.clear()

        await controller.apply(config: PinchosConfig(items: [item("beta"), item("alpha")]))

        let newItems = Array(factory.created.dropFirst(2))
        XCTAssertFalse(newItems[0] === oldItems[0])
        XCTAssertFalse(newItems[1] === oldItems[1])
        XCTAssertEqual(newItems.map(\.config.name), ["beta", "alpha"])
        XCTAssertTrue(newItems.allSatisfy { !$0.initiallyVisible })
        XCTAssertEqual(factory.eventLog.events, [
            "prepare-removal:alpha",
            "prepare-removal:beta",
            "commit-removal:alpha",
            "commit-removal:beta",
            "activate:beta",
            "activate:alpha"
        ])
    }
}
