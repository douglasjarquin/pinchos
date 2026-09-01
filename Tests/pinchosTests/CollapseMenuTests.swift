import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
private final class CollapseFakeItem: ManagedItemLifecycle {
    private var pendingConfig: ItemConfig?
    private var runtimeSnapshotStartWaiter: CheckedContinuation<Void, Never>?
    private var runtimeSnapshotRelease: CheckedContinuation<Void, Never>?
    private(set) var config: ItemConfig
    private(set) var isVisible: Bool
    private(set) var statusItemVisible = false
    var blocksRuntimeSnapshot = false
    /// When non-nil, returned as the item's rendered value (the collapsed
    /// first-level row and the value shown in its menu). `nil` means "not yet
    /// run", which collapses the row back to the item name.
    var runtimeValue: String?
    private(set) var runtimeSnapshotStarted = false

    init(config: ItemConfig) {
        self.config = config
        self.isVisible = true
    }

    var iconDiagnosticNote: String?

    func owns(statusItem: NSStatusItem) -> Bool { false }

    func activate() {
        isVisible = true
        statusItemVisible = isVisible
    }

    func setStatusItemVisible(_ visible: Bool) {
        statusItemVisible = visible && isVisible
    }

    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async {
        pendingConfig = config
    }

    func commitPreparedUpdate() {
        config = pendingConfig!
        pendingConfig = nil
        isVisible = true
    }

    func prepareRemoval(deadline: ContinuousClock.Instant) async {}
    func commitRemoval() {}
    func tearDown(deadline: ContinuousClock.Instant) async {}

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        CommandRunnerSnapshot(isRunning: false, lastExecution: nil, skippedRefreshes: 0)
    }

    func runtimeSnapshot() async -> ItemRuntimeSnapshot {
        if blocksRuntimeSnapshot {
            blocksRuntimeSnapshot = false
            runtimeSnapshotStarted = true
            runtimeSnapshotStartWaiter?.resume()
            runtimeSnapshotStartWaiter = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                runtimeSnapshotRelease = continuation
            }
        }
        return ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: runtimeValue,
            lastAttemptedAt: nil,
            lastUpdatedAt: nil,
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )
    }

    func waitForRuntimeSnapshotStart() async {
        if runtimeSnapshotStarted { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            runtimeSnapshotStartWaiter = continuation
        }
    }

    func releaseRuntimeSnapshot() {
        runtimeSnapshotRelease?.resume()
        runtimeSnapshotRelease = nil
    }

    func menuRowSnapshot(at index: Int) async -> CommandRunnerSnapshot? { nil }
    func invokeMenuRow(at index: Int) {}
    func refreshNow() {}
}

@MainActor
private final class CollapseFakeFactory: ManagedItemFactory {
    private(set) var created: [CollapseFakeItem] = []

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        let item = CollapseFakeItem(config: config)
        created.append(item)
        return item
    }
}

@MainActor
private final class CollapseFakeStatusItemHost: StatusItemHost {
    private(set) var created = 0
    private(set) var removed = 0
    private(set) var presented = 0

    func makeStatusItem() -> NSStatusItem? {
        created += 1
        return NSStatusItem()
    }

    func removeStatusItem(_ item: NSStatusItem) {
        removed += 1
        item.menu = nil
    }

    func present(menu: NSMenu, on statusItem: NSStatusItem) {
        presented += 1
    }
}

@MainActor
final class CollapseMenuTests: XCTestCase {
    private func command(_ name: String) -> ItemConfig {
        ItemConfig(name: name, run: "echo \(name)", interval: .manual)
    }

    private func makeController(
        factory: CollapseFakeFactory,
        host: CollapseFakeStatusItemHost
    ) -> StatusItemController {
        StatusItemController(
            configPath: "/tmp/pinchos-collapse-test-\(UUID().uuidString).toml",
            onReload: {},
            itemFactory: factory,
            statusItemHost: host
        )
    }

    private func createdItem(_ name: String, in factory: CollapseFakeFactory) throws -> CollapseFakeItem {
        try XCTUnwrap(factory.created.first(where: { $0.config.name == name }))
    }

    func testAnyPinchoMenuCanCollapseToOnePinchosIcon() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("alpha"), command("beta")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: try createdItem("alpha", in: factory))
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))

        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))
        XCTAssertEqual(host.created, 1)
        XCTAssertTrue(factory.created.allSatisfy { !$0.statusItemVisible })
    }

    func testCollapsedRootUsesTopLevelRowsInDeclarationOrder() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("alpha"),
            command("beta"),
            command("standalone")
        ]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: try createdItem("alpha", in: factory))
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        let collapsed = await controller.makeCollapsedMenu()
        let firstLevelTitles = collapsed.items.filter { !$0.isSeparatorItem }.map(\.title)
        let schedulerTitle = "Scheduler: 0/\(CommandScheduler.defaultMaxActiveSessions) active"
        XCTAssertEqual(firstLevelTitles, ["–", "–", "–", schedulerTitle, "Expand Pinchos", "Open Config", "Reload Config", "Quit Pinchos"])

        let standalone = try XCTUnwrap(collapsed.items.first(where: { $0.title == "–" && $0.submenu != nil }))
        let standaloneMenu = try XCTUnwrap(standalone.submenu)
        XCTAssertNotNil(standaloneMenu.items.first(where: { $0.title == "Refresh Now" }))

        // Collapsed submenus carry no global
        // footer; it appears exactly once, at the collapsed tray's top level.
        for submenu in [standaloneMenu] {
            XCTAssertNil(submenu.items.first(where: { $0.title == "Collapse Pinchos" || $0.title == "Expand Pinchos" }))
            XCTAssertNil(submenu.items.first(where: { $0.title == "Open Config" }))
            XCTAssertNil(submenu.items.first(where: { $0.title == "Reload Config" }))
            XCTAssertNil(submenu.items.first(where: { $0.title == "Quit Pinchos" }))
        }
        XCTAssertNotNil(collapsed.items.first(where: { $0.title == "Expand Pinchos" }))
    }

    func testCollapsedFirstLevelShowsCommandValueInsteadOfName() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("disk")]))
        factory.created[0].runtimeValue = "12"

        let collapsed = await controller.makeCollapsedMenu()
        let firstLevelTitles = collapsed.items.filter { !$0.isSeparatorItem }.map(\.title)

        // What normally shows in the disk item's menu bar is the value, so the
        // collapsed first level is that value -- not "disk" or "disk: 12".
        XCTAssertEqual(firstLevelTitles.first, "12")
        let diskRows = firstLevelTitles.filter { $0 == "disk" || $0.hasPrefix("disk:") }
        XCTAssertTrue(diskRows.isEmpty)

        // The submenu is still the item's normal menu (handles reachable).
        let row = try XCTUnwrap(collapsed.items.first(where: { $0.submenu != nil }))
        XCTAssertNotNil(row.submenu?.items.first(where: { $0.title == "Refresh Now" }))
    }

    func testCollapsedFirstLevelRowCarriesTheItemsIconAndValue() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        // Bar shows [heart icon] + "11%" (format `{output}%`); the collapsed
        // first level must mirror that: value with the same icon, not a bare
        // number and never the config name.
        let withIcon = ItemConfig(
            name: "disk",
            run: "echo 11",
            interval: .manual,
            format: "{output}%",
            symbol: "checkmark"
        )
        await controller.apply(config: PinchosConfig(items: [withIcon]))
        factory.created[0].runtimeValue = "11"

        let collapsed = await controller.makeCollapsedMenu()
        let row = try XCTUnwrap(collapsed.items.first(where: { $0.submenu != nil }))
        XCTAssertEqual(row.title, "11%")
        XCTAssertNotNil(row.image, "the collapsed row should show the item's menu-bar icon alongside its value")
    }

    func testExpandRestoresTopLevelVisibilityAndRemovesCollapsedIcon() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("alpha"), command("beta")]))
        let visibleItem = try createdItem("alpha", in: factory)
        let secondItem = try createdItem("beta", in: factory)
        let menu = await controller.makeLifecycleMenu(forManagedItem: visibleItem)
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        let collapsed = await controller.makeCollapsedMenu()
        let expand = try XCTUnwrap(collapsed.items.first(where: { $0.title == "Expand Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(expand.action!, to: expand.target, from: expand))

        XCTAssertEqual(host.created, 1)
        XCTAssertEqual(host.removed, 1)
        XCTAssertTrue(visibleItem.statusItemVisible)
        XCTAssertTrue(secondItem.statusItemVisible)
    }

    func testRecoveryWarningReappearsAfterExpanding() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("alpha")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        await controller.showParseError("parse failed")
        XCTAssertEqual(host.created, 1)

        let collapsed = await controller.makeCollapsedMenu()
        let expand = try XCTUnwrap(collapsed.items.first(where: { $0.title == "Expand Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(expand.action!, to: expand.target, from: expand))

        XCTAssertEqual(host.created, 2)
        XCTAssertTrue(factory.created[0].statusItemVisible)
    }

    func testCollapsedMenuKeepsRecoveryActionsReachable() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: []))
        await controller.showParseError("parse failed")

        let collapsed = await controller.makeCollapsedMenu()
        let recovery = try XCTUnwrap(collapsed.items.first(where: { $0.title.contains("pinchos") }))
        let recoveryMenu = try XCTUnwrap(recovery.submenu)
        XCTAssertNotNil(recoveryMenu.items.first(where: { $0.title == "Open Config" }))
        XCTAssertNotNil(recoveryMenu.items.first(where: { $0.title == "Reload" }))
        XCTAssertNotNil(recoveryMenu.items.first(where: { $0.title == "Quit" }))
    }

    func testCollapsedMenuDoesNotPresentAfterIconIsRemovedWhileBuilding() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("alpha")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        let item = factory.created[0]
        item.blocksRuntimeSnapshot = true
        let snapshotStarted = Task { @MainActor in
            await item.waitForRuntimeSnapshotStart()
        }
        let menuTask = try XCTUnwrap(controller.requestCollapsedMenu())
        await snapshotStarted.value

        await controller.shutdown()
        item.releaseRuntimeSnapshot()
        await menuTask.value

        XCTAssertEqual(host.removed, 1)
        XCTAssertEqual(host.presented, 0)
    }

    func testCollapsedMenuDoesNotPresentAfterConfigChangesWhileBuilding() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("alpha")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        let item = factory.created[0]
        item.blocksRuntimeSnapshot = true
        let snapshotStarted = Task { @MainActor in
            await item.waitForRuntimeSnapshotStart()
        }
        let menuTask = try XCTUnwrap(controller.requestCollapsedMenu())
        await snapshotStarted.value

        await controller.apply(config: PinchosConfig(items: [command("beta")]))
        item.releaseRuntimeSnapshot()
        await menuTask.value

        XCTAssertEqual(host.presented, 0)
    }
}
