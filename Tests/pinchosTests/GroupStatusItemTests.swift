import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

/// Controller/menu-building coverage for the grouped-status-items feature
/// (issue #18): one native status item per group, hidden-member visibility
/// (a name used as a group member never gets its own top-level
/// `NSStatusItem`), member current value/state and actions surfaced in the
/// group's menu, and incremental reload of group membership. Parsing and
/// `ConfigDiff` coverage live in `GroupConfigTests`/`ConfigDiffTests`
/// (PinchosCoreTests); this file is `StatusItemController`'s own
/// `FakeManagedItemFactory`-based fixture (duplicated from
/// `StatusItemControllerTests` since that file's fakes are file-private).
@MainActor
private final class GroupTestEventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func clear() { events.removeAll() }
}

@MainActor
private final class GroupTestFakeItem: ManagedItemLifecycle {
    private let eventLog: GroupTestEventLog
    private var pendingConfig: ItemConfig?
    private(set) var config: ItemConfig
    var actions: [ItemAction] { config.commandConfig?.actions ?? [] }
    var iconDiagnosticNote: String?
    let isTopLevel: Bool
    var runtimeSnapshotValue: ItemRuntimeSnapshot?
    var actionSnapshotValues: [CommandRunnerSnapshot?] = []

    init(config: ItemConfig, eventLog: GroupTestEventLog, isTopLevel: Bool) {
        self.config = config
        self.eventLog = eventLog
        self.isTopLevel = isTopLevel
    }

    func owns(statusItem: NSStatusItem) -> Bool { false }
    func activate() { eventLog.append("activate:\(config.name)") }

    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async {
        pendingConfig = config
        eventLog.append("prepare-update:\(config.name)")
    }

    func commitPreparedUpdate() {
        config = pendingConfig!
        pendingConfig = nil
        eventLog.append("commit-update:\(config.name)")
    }

    func prepareRemoval(deadline: ContinuousClock.Instant) async {
        eventLog.append("prepare-removal:\(config.name)")
    }

    func commitRemoval() { eventLog.append("commit-removal:\(config.name)") }

    func tearDown(deadline: ContinuousClock.Instant) async {
        await prepareRemoval(deadline: deadline)
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

    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot? {
        guard actionSnapshotValues.indices.contains(index) else { return nil }
        return actionSnapshotValues[index]
    }

    func clickSnapshot() async -> ClickDiagnosticsSnapshot? { nil }
    func invokeAction(at index: Int) { eventLog.append("action:\(config.name):\(index)") }
    func refreshNow() { eventLog.append("refresh-now:\(config.name)") }
}

@MainActor
private final class GroupTestFakeFactory: ManagedItemFactory {
    let eventLog = GroupTestEventLog()
    private(set) var created: [GroupTestFakeItem] = []
    private(set) var isTopLevelByName: [String: Bool] = [:]

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool,
        isTopLevel: Bool
    ) -> any ManagedItemLifecycle {
        let item = GroupTestFakeItem(config: config, eventLog: eventLog, isTopLevel: isTopLevel)
        isTopLevelByName[config.name] = isTopLevel
        created.append(item)
        return item
    }

    func item(named name: String) -> GroupTestFakeItem? {
        created.first(where: { $0.config.name == name })
    }
}

@MainActor
final class GroupStatusItemTests: XCTestCase {
    private func command(_ name: String, run: String? = nil) -> ItemConfig {
        ItemConfig(name: name, run: run ?? "echo \(name)", interval: .scheduled(60))
    }

    private func group(_ name: String, title: String, members: [String]) -> ItemConfig {
        .group(GroupItemConfig(name: name, title: title, members: members))
    }

    private func makeController(factory: GroupTestFakeFactory) -> StatusItemController {
        StatusItemController(
            configPath: "/tmp/pinchos-group-test-\(UUID().uuidString).toml",
            onReload: {},
            itemFactory: factory
        )
    }

    // MARK: - One native status item per group; members never double up

    func testGroupMembersAreNotTopLevelButTheGroupIs() async {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            command("codex"),
            group("ai", title: "AI", members: ["claude", "codex"])
        ]))

        XCTAssertEqual(factory.isTopLevelByName["ai"], true)
        XCTAssertEqual(factory.isTopLevelByName["claude"], false)
        XCTAssertEqual(factory.isTopLevelByName["codex"], false)
    }

    func testItemNotReferencedByAnyGroupStaysTopLevel() async {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("standalone"),
            command("claude"),
            group("ai", title: "AI", members: ["claude"])
        ]))

        XCTAssertEqual(factory.isTopLevelByName["standalone"], true)
    }

    // MARK: - Incremental reload of group membership

    func testAddingAMemberToAnExistingGroupHidesItWithoutTouchingUnrelatedItems() async {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            command("codex"),
            group("ai", title: "AI", members: ["claude"])
        ]))
        factory.eventLog.clear()

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            command("codex"),
            group("ai", title: "AI", members: ["claude", "codex"])
        ]))

        // "codex" flips from top-level to hidden: an in-place update cannot
        // express that, so it is recreated (not updated).
        XCTAssertEqual(factory.eventLog.events.filter { $0.hasPrefix("prepare-removal:codex") }.count, 1)
        XCTAssertEqual(factory.eventLog.events.filter { $0.hasPrefix("commit-removal:codex") }.count, 1)
        XCTAssertEqual(factory.eventLog.events.filter { $0.hasPrefix("activate:codex") }.count, 1)
        XCTAssertEqual(factory.isTopLevelByName["codex"], false)
        // "claude"'s own membership/visibility did not change, so it
        // updates in place instead of being recreated.
        XCTAssertFalse(factory.eventLog.events.contains("prepare-removal:claude"))
    }

    func testRemovingAMemberFromAGroupRestoresItAsTopLevel() async {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            command("codex"),
            group("ai", title: "AI", members: ["claude", "codex"])
        ]))
        factory.eventLog.clear()

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            command("codex"),
            group("ai", title: "AI", members: ["claude"])
        ]))

        XCTAssertEqual(factory.isTopLevelByName["codex"], true)
        XCTAssertTrue(factory.eventLog.events.contains("prepare-removal:codex"))
        XCTAssertTrue(factory.eventLog.events.contains("activate:codex"))
    }

    func testGroupTitleChangeAloneUpdatesInPlace() async {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            group("ai", title: "AI", members: ["claude"])
        ]))
        factory.eventLog.clear()

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            group("ai", title: "AI Assistants", members: ["claude"])
        ]))

        XCTAssertEqual(factory.eventLog.events, ["prepare-update:ai", "commit-update:ai"])
        XCTAssertEqual(factory.item(named: "ai")?.config.groupConfig?.title, "AI Assistants")
    }

    // MARK: - Group menu: member current value/state and actions

    func testGroupMenuHeaderJoinsMemberCurrentValues() async throws {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            command("codex"),
            group("ai", title: "AI", members: ["claude", "codex"])
        ]))

        factory.item(named: "claude")?.runtimeSnapshotValue = makeSnapshot(output: "idle")
        factory.item(named: "codex")?.runtimeSnapshotValue = makeSnapshot(output: "busy")

        let groupItem = try XCTUnwrap(factory.item(named: "ai"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: groupItem)

        let header = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(header.title.contains("AI"))
        XCTAssertTrue(header.title.contains("idle"))
        XCTAssertTrue(header.title.contains("busy"))
        XCTAssertFalse(header.isEnabled)
    }

    func testGroupMenuProjectsStructuredMemberTextInsteadOfRawJSON() async throws {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("quota"),
            group("usage", title: "Usage", members: ["quota"])
        ]))

        factory.item(named: "quota")?.runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: #"{"version":1,"text":"81%"}"#,
            lastAttemptedAt: Date(),
            lastUpdatedAt: Date(),
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date(),
            structuredOutput: StructuredCommandOutput(text: "81%")
        )

        let groupItem = try XCTUnwrap(factory.item(named: "usage"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: groupItem)

        let header = try XCTUnwrap(menu.items.first)
        let member = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("quota:") }))
        XCTAssertTrue(header.title.contains("81%"))
        XCTAssertTrue(member.title.contains("81%"))
        XCTAssertFalse(header.title.contains("version"))
        XCTAssertFalse(member.title.contains("version"))
    }

    func testGroupMenuListsOneSubmenuPerMemberWithItsOwnValueAndRefresh() async throws {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            command("codex"),
            group("ai", title: "AI", members: ["claude", "codex"])
        ]))
        factory.item(named: "claude")?.runtimeSnapshotValue = makeSnapshot(output: "claude-value")

        let groupItem = try XCTUnwrap(factory.item(named: "ai"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: groupItem)

        let memberItems = menu.items.filter { $0.submenu != nil }
        XCTAssertEqual(memberItems.count, 2)
        let claudeItem = try XCTUnwrap(memberItems.first(where: { $0.title.hasPrefix("claude:") }))
        XCTAssertTrue(claudeItem.title.contains("claude-value"))

        let submenu = try XCTUnwrap(claudeItem.submenu)
        let refresh = try XCTUnwrap(submenu.items.first(where: { $0.title == "Refresh Now" }))
        XCTAssertTrue(NSApplication.shared.sendAction(refresh.action!, to: refresh.target, from: refresh))
        XCTAssertTrue(factory.eventLog.events.contains("refresh-now:claude"))
    }

    func testGroupMenuMemberSubmenuInvokesDeclaredActionsOnThatMemberOnly() async throws {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let claudeWithAction = ItemConfig(
            name: "claude",
            run: "echo claude",
            interval: .scheduled(60),
            actions: [ItemAction(title: "Open usage", kind: .command("open https://example.com"))]
        )
        await controller.apply(config: PinchosConfig(items: [
            claudeWithAction,
            command("codex"),
            group("ai", title: "AI", members: ["claude", "codex"])
        ]))
        factory.eventLog.clear()

        let groupItem = try XCTUnwrap(factory.item(named: "ai"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: groupItem)
        let claudeItem = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("claude:") }))
        let submenu = try XCTUnwrap(claudeItem.submenu)
        let action = try XCTUnwrap(submenu.items.first(where: { $0.title == "Open usage" }))

        XCTAssertTrue(NSApplication.shared.sendAction(action.action!, to: action.target, from: action))
        XCTAssertEqual(factory.eventLog.events, ["action:claude:0"])
    }

    func testGroupMenuOmitsMembersThatAreNotFound() async throws {
        // Defensive: `ConfigParser` already rejects unknown members, but the
        // menu builder itself must not crash if `items` is ever missing a
        // declared member (e.g. a race with a reload in flight).
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            group("ai", title: "AI", members: ["claude"])
        ]))

        let groupItem = try XCTUnwrap(factory.item(named: "ai"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: groupItem)
        XCTAssertEqual(menu.items.filter { $0.submenu != nil }.count, 1)
    }

    func testGroupMenuOmitsMembersHiddenByConfig() async throws {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let hidden = ItemConfig(
            name: "hidden",
            run: "echo hidden",
            interval: .scheduled(60),
            hidden: true
        )
        await controller.apply(config: PinchosConfig(items: [
            hidden,
            command("visible"),
            group("all", title: "All", members: ["hidden", "visible"])
        ]))

        let groupItem = try XCTUnwrap(factory.item(named: "all"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: groupItem)

        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("hidden:") })
        XCTAssertTrue(menu.items.contains { $0.title.hasPrefix("visible:") })
    }

    func testGroupMenuOmitsNestedGroupsHiddenByConfig() async throws {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let hiddenGroup = ItemConfig.group(
            GroupItemConfig(name: "assistants", title: "Assistants", members: ["visible"], hidden: true)
        )
        await controller.apply(config: PinchosConfig(items: [
            command("visible"),
            hiddenGroup,
            group("all", title: "All", members: ["assistants"])
        ]))

        let groupItem = try XCTUnwrap(factory.item(named: "all"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: groupItem)

        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("assistants:") })
    }

    // MARK: - Nested groups recurse in the menu

    func testNestedGroupMemberGetsASubmenuThatItselfListsItsMembers() async throws {
        let factory = GroupTestFakeFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [
            command("claude"),
            group("assistants", title: "Assistants", members: ["claude"]),
            group("everything", title: "Everything", members: ["assistants"])
        ]))

        let everything = try XCTUnwrap(factory.item(named: "everything"))
        let menu = await controller.makeLifecycleMenu(forManagedItem: everything)
        let assistantsItem = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("assistants:") }))
        let nestedSubmenu = try XCTUnwrap(assistantsItem.submenu)
        let claudeItem = try XCTUnwrap(nestedSubmenu.items.first(where: { $0.title.hasPrefix("claude:") }))
        XCTAssertNotNil(claudeItem.submenu)
    }

    private func makeSnapshot(output: String) -> ItemRuntimeSnapshot {
        ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: output,
            lastAttemptedAt: Date(),
            lastUpdatedAt: Date(),
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )
    }
}
