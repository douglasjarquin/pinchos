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
    let isTopLevel: Bool
    private(set) var isVisible: Bool
    private(set) var statusItemVisible = false
    var blocksRuntimeSnapshot = false

    init(config: ItemConfig, isTopLevel: Bool) {
        self.config = config
        self.isTopLevel = isTopLevel
        self.isVisible = !config.hidden
    }

    var actions: [ItemAction] { config.commandConfig?.actions ?? [] }
    var iconDiagnosticNote: String?

    func owns(statusItem: NSStatusItem) -> Bool { false }

    func activate() {
        isVisible = !config.hidden
        statusItemVisible = isTopLevel && isVisible
    }

    func setStatusItemVisible(_ visible: Bool) {
        statusItemVisible = visible && isTopLevel && isVisible
    }

    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async {
        pendingConfig = config
    }

    func commitPreparedUpdate() {
        config = pendingConfig!
        pendingConfig = nil
        isVisible = !config.hidden
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
            runtimeSnapshotStartWaiter?.resume()
            runtimeSnapshotStartWaiter = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                runtimeSnapshotRelease = continuation
            }
        }
        return ItemRuntimeSnapshot(
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

    func waitForRuntimeSnapshotStart() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            runtimeSnapshotStartWaiter = continuation
        }
    }

    func releaseRuntimeSnapshot() {
        runtimeSnapshotRelease?.resume()
        runtimeSnapshotRelease = nil
    }

    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot? { nil }
    func clickSnapshot() async -> ClickDiagnosticsSnapshot? { nil }
    func invokeAction(at index: Int) {}
    func refreshNow() {}
}

@MainActor
private final class CollapseFakeFactory: ManagedItemFactory {
    private(set) var created: [CollapseFakeItem] = []

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool,
        isTopLevel: Bool
    ) -> any ManagedItemLifecycle {
        let item = CollapseFakeItem(config: config, isTopLevel: isTopLevel)
        created.append(item)
        return item
    }
}

@MainActor
private final class CollapseFakeStatusItemHost: StatusItemHost {
    private(set) var created = 0
    private(set) var removed = 0
    private(set) var presented = 0
    private(set) var statusItems: [NSStatusItem] = []

    func makeStatusItem() -> NSStatusItem? {
        created += 1
        let statusItem = NSStatusItem()
        statusItems.append(statusItem)
        return statusItem
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
    private func command(_ name: String, hidden: Bool = false) -> ItemConfig {
        ItemConfig(name: name, run: "echo \(name)", interval: .manual, hidden: hidden)
    }

    private func group(_ name: String, title: String, members: [String]) -> ItemConfig {
        .group(GroupItemConfig(name: name, title: title, members: members))
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

    func testAnyPinchoMenuCanCollapseToOnePinchosIcon() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("alpha"), command("beta")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[1])
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))

        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))
        XCTAssertEqual(host.created, 1)
        XCTAssertTrue(factory.created.allSatisfy { !$0.statusItemVisible })
    }

    func testCollapsedRootUsesTopLevelRowsWithOriginalNestedMenus() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("alpha"),
            command("beta"),
            group("team", title: "Team", members: ["alpha", "beta"]),
            command("standalone")
        ]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[3])
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        let collapsed = await controller.makeCollapsedMenu()
        let firstLevelTitles = collapsed.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(firstLevelTitles.prefix(2), ["Team", "standalone"])
        XCTAssertFalse(firstLevelTitles.contains("alpha"))
        XCTAssertFalse(firstLevelTitles.contains("beta"))

        let team = try XCTUnwrap(collapsed.items.first(where: { $0.title == "Team" }))
        let nested = try XCTUnwrap(team.submenu)
        XCTAssertNotNil(nested.items.first(where: { $0.title == "alpha: –" }))
        XCTAssertNotNil(nested.items.first(where: { $0.title == "beta: –" }))

        let standalone = try XCTUnwrap(collapsed.items.first(where: { $0.title == "standalone" }))
        let standaloneMenu = try XCTUnwrap(standalone.submenu)
        XCTAssertNotNil(standaloneMenu.items.first(where: { $0.title == "Run standalone" }))
        XCTAssertNotNil(standaloneMenu.items.first(where: { $0.title == "Refresh Now" }))
        XCTAssertNotNil(standaloneMenu.items.first(where: { $0.title == "Expand Pinchos" }))
    }

    func testGroupMemberMenuCanCollapseTheWholeBar() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("alpha"),
            group("team", title: "Team", members: ["alpha"])
        ]))

        let groupItem = try XCTUnwrap(factory.created.first(where: { $0.config.name == "team" }))
        let groupMenu = await controller.makeLifecycleMenu(forManagedItem: groupItem)
        let memberMenu = try XCTUnwrap(groupMenu.items.first(where: { $0.title == "alpha: –" })?.submenu)
        let collapse = try XCTUnwrap(memberMenu.items.first(where: { $0.title == "Collapse Pinchos" }))

        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))
        XCTAssertEqual(host.created, 1)
        XCTAssertTrue(factory.created.allSatisfy { !$0.statusItemVisible })
    }

    func testExpandRestoresTopLevelVisibilityAndRemovesCollapsedIcon() async throws {
        let factory = CollapseFakeFactory()
        let host = CollapseFakeStatusItemHost()
        let controller = makeController(factory: factory, host: host)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [command("alpha"), command("hidden", hidden: true)]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        let collapsed = await controller.makeCollapsedMenu()
        let expand = try XCTUnwrap(collapsed.items.first(where: { $0.title == "Expand Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(expand.action!, to: expand.target, from: expand))

        XCTAssertEqual(host.created, 1)
        XCTAssertEqual(host.removed, 1)
        XCTAssertTrue(factory.created[0].statusItemVisible)
        XCTAssertFalse(factory.created[1].statusItemVisible)
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
        let collapsedStatusItem = try XCTUnwrap(host.statusItems.first)
        let snapshotStarted = Task { @MainActor in
            await item.waitForRuntimeSnapshotStart()
        }
        XCTAssertTrue(NSApplication.shared.sendAction(
            NSSelectorFromString("handleCollapsedClick"),
            to: controller,
            from: collapsedStatusItem
        ))
        await snapshotStarted.value

        await controller.shutdown()
        item.releaseRuntimeSnapshot()
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(host.removed, 1)
        XCTAssertEqual(host.presented, 0)
    }
}
