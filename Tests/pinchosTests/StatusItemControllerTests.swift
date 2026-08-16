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
    let ownedStatusItem: NSStatusItem?
    var runtimeSnapshotValue: ItemRuntimeSnapshot?

    init(
        config: ItemConfig,
        eventLog: EventLog,
        initiallyVisible: Bool,
        ownedStatusItem: NSStatusItem?
    ) {
        self.config = config
        self.eventLog = eventLog
        self.initiallyVisible = initiallyVisible
        self.ownedStatusItem = ownedStatusItem
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        ownedStatusItem === statusItem
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

    func runtimeSnapshot() async -> ItemRuntimeSnapshot {
        runtimeSnapshotValue ?? ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: nil,
            lastAttemptedAt: nil,
            lastUpdatedAt: nil,
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )
    }

    func refreshNow() {
        eventLog.append("refresh-now:\(config.name)")
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
    var statusItemToOwn: NSStatusItem?

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        let item = FakeManagedItem(
            config: config,
            eventLog: eventLog,
            initiallyVisible: initiallyVisible,
            ownedStatusItem: statusItemToOwn
        )
        statusItemToOwn = nil
        created.append(item)
        return item
    }
}

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private func item(_ name: String, run: String? = nil) -> ItemConfig {
        ItemConfig(name: name, run: run ?? "echo \(name)", interval: .scheduled(60))
    }

    private func makeController(factory: FakeManagedItemFactory) -> StatusItemController {
        StatusItemController(
            configPath: "/tmp/pinchos-test.toml",
            onReload: {},
            itemFactory: factory
        )
    }

    func testLifecycleMenuOffersRefreshNowAndDelegatesToItem() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        factory.eventLog.clear()

        let refresh = try XCTUnwrap(menu.items.first(where: { $0.title == "Refresh Now" }))
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertNotNil(refresh.representedObject)
        XCTAssertTrue(NSApplication.shared.sendAction(refresh.action!, to: refresh.target, from: refresh))
        XCTAssertEqual(factory.eventLog.events, ["refresh-now:alpha"])
    }

    func testLifecycleMenuShowsRuntimeStateAndRunnerDiagnostics() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let attempt = Date(timeIntervalSince1970: 1_700_000_000)
        let execution = CommandExecution(
            terminalReason: .exited(code: 7),
            stdout: "full\nvalue\n",
            stderr: "diagnostic\n",
            stdoutBytesRead: 11,
            stderrBytesRead: 11,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.25
        )
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "full\nvalue\n",
            lastAttemptedAt: attempt,
            lastUpdatedAt: attempt.addingTimeInterval(-60),
            lastExecution: execution,
            staleAfter: 60,
            skippedRefreshes: 2,
            now: attempt
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("State: error"))
        XCTAssertTrue(titles.contains("Value: full\nvalue\n"))
        XCTAssertTrue(titles.contains("Last attempt: 2023-11-14T22:13:20Z"))
        XCTAssertTrue(titles.contains("Last success: 2023-11-14T22:12:20Z"))
        XCTAssertTrue(titles.contains("Stale: yes"))
        XCTAssertTrue(titles.contains("Last duration: 0.250s"))
        XCTAssertTrue(titles.contains("Last exit: 7"))
        XCTAssertTrue(titles.contains("Error: diagnostic"))
        XCTAssertTrue(titles.contains("Last exit code: 7"))
        XCTAssertTrue(titles.contains("stderr: diagnostic"))
        XCTAssertTrue(titles.contains("Skipped ticks: 2"))
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
