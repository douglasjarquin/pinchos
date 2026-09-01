import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
private final class FakeManagedItem: ManagedItemLifecycle {
    private let eventLog: EventLog
    private var pendingConfig: ItemConfig?
    private(set) var config: ItemConfig
    var actions: [ItemAction] {
        config.commandConfig?.actions ?? []
    }
    var iconDiagnosticNote: String?
    private(set) var isVisible: Bool
    let initiallyVisible: Bool
    let isTopLevel: Bool
    let ownedStatusItem: NSStatusItem?
    var runtimeSnapshotValue: ItemRuntimeSnapshot?
    var actionSnapshotValues: [CommandRunnerSnapshot?] = []
    /// When set, `prepareUpdate`/`prepareRemoval` sleep for this duration
    /// after logging, letting tests prove operations across many fake items
    /// are fired and awaited concurrently (bounded by the slowest one) under
    /// one shared deadline instead of being summed sequentially.
    var settlementDelay: Duration?

    init(
        config: ItemConfig,
        eventLog: EventLog,
        initiallyVisible: Bool,
        isTopLevel: Bool,
        ownedStatusItem: NSStatusItem?
    ) {
        self.config = config
        self.eventLog = eventLog
        self.initiallyVisible = initiallyVisible
        self.isTopLevel = isTopLevel
        self.ownedStatusItem = ownedStatusItem
        self.isVisible = initiallyVisible && !config.hidden
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        ownedStatusItem === statusItem
    }

    func activate() {
        isVisible = !config.hidden
        eventLog.append("activate:\(config.name)")
    }

    func setStatusItemVisible(_ visible: Bool) {}

    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async {
        pendingConfig = config
        eventLog.append("prepare-update:\(config.name)")
        if let settlementDelay {
            try? await Task.sleep(until: .now.advanced(by: settlementDelay))
        }
    }

    func commitPreparedUpdate() {
        config = pendingConfig!
        pendingConfig = nil
        isVisible = !config.hidden
        eventLog.append("commit-update:\(config.name)")
    }

    func prepareRemoval(deadline: ContinuousClock.Instant) async {
        eventLog.append("prepare-removal:\(config.name)")
        if let settlementDelay {
            try? await Task.sleep(until: .now.advanced(by: settlementDelay))
        }
    }

    func commitRemoval() {
        eventLog.append("commit-removal:\(config.name)")
    }

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

    func invokeAction(at index: Int) {
        eventLog.append("action:\(index)")
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
        initiallyVisible: Bool,
        isTopLevel: Bool
    ) -> any ManagedItemLifecycle {
        let item = FakeManagedItem(
            config: config,
            eventLog: eventLog,
            initiallyVisible: initiallyVisible,
            isTopLevel: isTopLevel,
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

    private func makeController(
        factory: FakeManagedItemFactory,
        configPath: String = "/tmp/pinchos-test.toml",
        onReload: @escaping () -> Void = {}
    ) -> StatusItemController {
        StatusItemController(
            configPath: configPath,
            onReload: onReload,
            itemFactory: factory
        )
    }

    func testLifecycleMenuRendersConfiguredInfoRows() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        let config = ItemConfig(
            name: "alpha",
            run: "echo alpha",
            interval: .manual,
            info: [
                ItemInfoRow(title: "Reset", run: "echo 2026-09-07"),
                // A failing info command must fall back to the `–` value.
                ItemInfoRow(title: "Pace", run: "exit 3")
            ]
        )
        await controller.apply(config: PinchosConfig(items: [config]))

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0], revealsDiagnostics: false)
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Reset: Loading…") || titles.contains("Reset: 2026-09-07"))
        XCTAssertTrue(titles.contains("Pace: Loading…") || titles.contains("Pace: –"))
        // Info rows are read-only: the row rendering must not be a clickable action.
        let infoTitle = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Reset:") }))
        XCTAssertFalse(infoTitle.isEnabled)
        XCTAssertNil(infoTitle.action)
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
        XCTAssertEqual(menu.items.first?.title, "Refresh Now")
        XCTAssertEqual(Array(menu.items.suffix(3).map(\.title)), ["Open Config", "Reload Config", "Quit Pinchos"])
    }

    func testLifecycleMenuOmitsDeprecatedHideAction() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        XCTAssertFalse(menu.items.contains { $0.title == "Hide" })
    }

    func testHiddenConfigUpdatesTheExistingManagedItemInPlace() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        let visible = item("alpha")
        let hidden = ItemConfig(name: "alpha", run: "echo alpha", interval: .scheduled(60), hidden: true)
        await controller.apply(config: PinchosConfig(items: [visible]))
        let managedItem = factory.created[0]
        factory.eventLog.clear()

        await controller.apply(config: PinchosConfig(items: [hidden]))

        XCTAssertTrue(factory.created[0] === managedItem)
        XCTAssertEqual(factory.eventLog.events, ["prepare-update:alpha", "commit-update:alpha"])
        XCTAssertTrue(factory.created[0].config.hidden)
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
        // Menu titles use DiagnosticPreviewFormatter: newlines collapse to U+240A.
        XCTAssertTrue(titles.contains("Value: full \u{240A} value"))
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

    func testCompactLifecycleMenuShowsOnlyActions() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let attempt = Date(timeIntervalSince1970: 1_700_000_000)
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "full\nvalue\n",
            lastAttemptedAt: attempt,
            lastUpdatedAt: attempt.addingTimeInterval(-60),
            lastExecution: CommandExecution(
                terminalReason: .exited(code: 7),
                stdout: "full\nvalue\n",
                stderr: "diagnostic\n",
                stdoutBytesRead: 11,
                stderrBytesRead: 11,
                stdoutTruncated: false,
                stderrTruncated: false,
                duration: 0.25
            ),
            staleAfter: 60,
            skippedRefreshes: 2,
            now: attempt
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0], revealsDiagnostics: false)
        let titles = menu.items.map(\.title)

        // Refresh Now leads the top group; Hide sits directly under it.
        XCTAssertEqual(Array(titles.prefix(1)), ["Refresh Now"])
        // Collapse Pinchos lives in the shared bottom group, below Reload Config.
        XCTAssertEqual(Array(titles.suffix(3)), ["Open Config", "Reload Config", "Quit Pinchos"])
        // No runtime state, diagnostics, or value summary appears.
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("State:") }))
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Value:") }))
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Last attempt:") }))
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Skipped ticks:") }))
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Scheduler:") }))
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Copy Full") }))
        XCTAssertFalse(titles.contains("full \u{240A} value \u{b7} failed \u{b7} showing last good value"))
    }

    func testLifecycleMenuPlacesDeclarativeActionsBeforeGlobalActions() async throws {
        let toml = """
        [item.codex]
        run = "echo value"

        [[item.codex.menu]]
        label = "Open usage"
        action = "open https://example.com/usage"
        """
        let config = try ConfigParser.parse(toml)
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: config)
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertEqual(Array(titles.prefix(2)), ["Refresh Now", "Open usage"])
        XCTAssertTrue(titles.contains("Open usage"))
        XCTAssertTrue(titles.contains("Refresh Now"))
        XCTAssertEqual(Array(titles.suffix(3)), ["Open Config", "Reload Config", "Quit Pinchos"])
    }

    func testLifecycleMenuInvokesDeclarativeActionsInOrder() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }
        let config = ItemConfig(
            name: "codex",
            run: "echo value",
            interval: .manual,
            actions: [
                ItemAction(title: "Open usage", kind: .command("echo usage")),
                ItemAction(title: "Refresh now", kind: .refresh)
            ]
        )

        await controller.apply(config: PinchosConfig(items: [config]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        factory.eventLog.clear()

        for title in ["Open usage", "Refresh now"] {
            let action = try XCTUnwrap(menu.items.first(where: { $0.title == title }))
            XCTAssertTrue(NSApplication.shared.sendAction(action.action!, to: action.target, from: action))
        }

        XCTAssertEqual(factory.eventLog.events, ["action:0", "action:1"])
    }

    func testLifecycleMenuShowsDeclarativeActionDiagnostics() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }
        let config = ItemConfig(
            name: "codex",
            run: "echo value",
            interval: .manual,
            actions: [ItemAction(title: "Fail action", kind: .command("exit 7"))]
        )
        await controller.apply(config: PinchosConfig(items: [config]))
        let execution = CommandExecution(
            terminalReason: .exited(code: 7),
            stdout: "",
            stderr: "action-error\n",
            stdoutBytesRead: 0,
            stderrBytesRead: 13,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.1
        )
        factory.created[0].actionSnapshotValues = [
            CommandRunnerSnapshot(isRunning: false, lastExecution: execution, skippedRefreshes: 2)
        ]

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Action \"Fail action\": waiting"))
        XCTAssertTrue(titles.contains("Action \"Fail action\": last exit code: 7"))
        XCTAssertTrue(titles.contains("Action \"Fail action\": stderr: action-error"))
        XCTAssertTrue(titles.contains("Action \"Fail action\": skipped invocations: 2"))
    }

    func testDisabledItemMenuDisablesExecutableActionsAndReportsDisabledState() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }
        let config = ItemConfig(
            name: "codex",
            run: "echo value",
            interval: .manual,
            actions: [
                ItemAction(title: "Open usage", kind: .command("echo usage")),
                ItemAction(title: "Refresh now", kind: .refresh)
            ],
            disabled: true
        )

        await controller.apply(config: PinchosConfig(items: [config]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        let openUsage = try XCTUnwrap(menu.items.first(where: { $0.title == "Open usage" }))
        let refreshNow = try XCTUnwrap(menu.items.first(where: { $0.title == "Refresh now" }))
        XCTAssertFalse(openUsage.isEnabled)
        XCTAssertFalse(refreshNow.isEnabled)
        XCTAssertTrue(titles.contains("Disabled: yes"))
    }

    func testDisabledItemWithoutDeclarativeActionsDisablesFallbackRefreshNow() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }
        let config = ItemConfig(name: "alpha", run: "echo alpha", interval: .scheduled(60), disabled: true)

        await controller.apply(config: PinchosConfig(items: [config]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])

        let refresh = try XCTUnwrap(menu.items.first(where: { $0.title == "Refresh Now" }))
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertTrue(menu.items.map(\.title).contains("Disabled: yes"))
    }

    func testEnabledItemMenuLeavesActionsEnabledAndOmitsDisabledState() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        let refresh = try XCTUnwrap(menu.items.first(where: { $0.title == "Refresh Now" }))
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertFalse(titles.contains("Disabled: yes"))
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

    func testModifyUpdatesOnlyTheChangedManagedItem() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [item("alpha"), item("beta")]))
        let alpha = try XCTUnwrap(factory.created.first(where: { $0.config.name == "alpha" }))
        let beta = try XCTUnwrap(factory.created.first(where: { $0.config.name == "beta" }))
        factory.eventLog.clear()

        await controller.apply(
            config: PinchosConfig(items: [item("alpha"), item("beta", run: "echo changed")])
        )

        XCTAssertTrue(factory.created.contains { $0 === alpha })
        XCTAssertTrue(factory.created.contains { $0 === beta })
        XCTAssertEqual(factory.eventLog.events, [
            "prepare-update:beta",
            "commit-update:beta"
        ])
        XCTAssertEqual(beta.config.commandConfig?.run, "echo changed")
    }

    func testIconSourceChangeUpdatesExistingItemInPlace() async {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [
            ItemConfig(name: "alpha", run: "echo alpha", interval: .scheduled(60), icon: "/tmp/a.svg")
        ]))
        let original = factory.created[0]
        factory.eventLog.clear()

        await controller.apply(config: PinchosConfig(items: [
            ItemConfig(name: "alpha", run: "echo alpha", interval: .scheduled(60), symbol: "chart.bar.fill")
        ]))

        XCTAssertTrue(factory.created[0] === original)
        XCTAssertEqual(factory.created.count, 1)
        XCTAssertEqual(factory.eventLog.events, [
            "prepare-update:alpha",
            "commit-update:alpha"
        ])
        XCTAssertEqual(original.config.command.iconSource, .symbol("chart.bar.fill"))
    }

    func testLifecycleMenuSurfacesUnavailableSymbolDiagnostic() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [
            ItemConfig(name: "alpha", run: "echo alpha", interval: .manual, symbol: "missing.symbol")
        ]))
        factory.created[0].iconDiagnosticNote = "symbol 'missing.symbol' is unavailable on this macOS version; rendering text-only"

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        XCTAssertTrue(menu.items.contains(where: {
            $0.title.contains("unavailable") && $0.title.contains("missing.symbol")
        }))
    }

    func testAddAndRemoveCommitAfterAllPreparation() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [item("alpha"), item("beta")]))
        let alpha = try XCTUnwrap(factory.created.first(where: { $0.config.name == "alpha" }))
        let beta = try XCTUnwrap(factory.created.first(where: { $0.config.name == "beta" }))
        factory.eventLog.clear()

        await controller.apply(
            config: PinchosConfig(items: [item("gamma"), item("alpha", run: "echo changed")])
        )

        XCTAssertTrue(factory.created.contains { $0 === alpha })
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

    func testCreatesNativeItemsInReverseConfigOrderForLeftToRightMenuBarOrder() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        let config = try ConfigParser.parse("""
        [item.zebra]
        run = "echo z"

        [item.apple]
        run = "echo a"
        """)
        XCTAssertEqual(config.items.map(\.name), ["zebra", "apple"])

        await controller.apply(config: config)

        XCTAssertEqual(factory.created.map(\.config.name), ["apple", "zebra"])
    }

    func testPrefixAdditionsCreateInReverseOrderWithoutRebuilding() async {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha"), item("beta")]))
        factory.eventLog.clear()

        await controller.apply(config: PinchosConfig(items: [
            item("gamma"),
            item("delta"),
            item("alpha"),
            item("beta")
        ]))

        XCTAssertEqual(factory.created.suffix(2).map(\.config.name), ["delta", "gamma"])
        XCTAssertEqual(factory.eventLog.events, ["activate:gamma", "activate:delta"])
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
        XCTAssertEqual(newItems.map(\.config.name), ["alpha", "beta"])
        XCTAssertTrue(newItems.allSatisfy { !$0.initiallyVisible })
        // prepareRemoval for old items is fanned out via `withTaskGroup`
        // (see LifecycleSettlement.swift), so alpha/beta may settle in
        // either order; only the deterministic, sequentially-driven suffix
        // (commit-removal, activate) has a fixed order.
        XCTAssertEqual(Set(factory.eventLog.events.prefix(2)), [
            "prepare-removal:alpha",
            "prepare-removal:beta"
        ])
        XCTAssertEqual(factory.eventLog.events.suffix(4), [
            "commit-removal:alpha",
            "commit-removal:beta",
            "activate:beta",
            "activate:alpha"
        ])
    }

    /// Issue #54: removing many items whose `prepareRemoval` each require T
    /// to settle must complete in approximately T, not N*T, proving
    /// cancellation across items is fired and awaited concurrently under one
    /// shared deadline rather than one item after another.
    func testReorderRebuildCancelsAllOldItemsConcurrentlyNotSequentially() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        let itemNames = ["alpha", "beta", "gamma", "delta"]
        await controller.apply(config: PinchosConfig(items: itemNames.map { item($0) }))
        for created in factory.created {
            created.settlementDelay = .milliseconds(150)
        }

        let clock = ContinuousClock()
        let started = clock.now
        // Reordering forces `rebuild(with:)`, which prepares every old item
        // for removal before replacing them.
        await controller.apply(config: PinchosConfig(items: itemNames.reversed().map { item($0) }))
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(
            elapsed, .milliseconds(150) * itemNames.count * 3 / 4,
            "4 items at 150ms settle time each must not sum to ~600ms if prepared concurrently"
        )
    }

    /// Same proof as above for `shutdownNow()`: tearing down N items that
    /// each take T to settle must complete near T, not N*T.
    func testShutdownTearsDownAllItemsConcurrentlyNotSequentially() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)

        let itemNames = ["alpha", "beta", "gamma", "delta"]
        await controller.apply(config: PinchosConfig(items: itemNames.map { item($0) }))
        for created in factory.created {
            created.settlementDelay = .milliseconds(150)
        }

        let clock = ContinuousClock()
        let started = clock.now
        await controller.shutdown()
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(
            elapsed, .milliseconds(150) * itemNames.count * 3 / 4,
            "4 items at 150ms settle time each must not sum to ~600ms during shutdown if torn down concurrently"
        )
    }

    /// Same proof for a live reload that both updates and removes items in
    /// one operation: `apply(diff:)` must fire and await both concurrently.
    func testReloadCancelsChangedAndRemovedItemsConcurrentlyNotSequentially() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [
            item("alpha"), item("beta"), item("gamma"), item("delta")
        ]))
        for created in factory.created {
            created.settlementDelay = .milliseconds(150)
        }

        let clock = ContinuousClock()
        let started = clock.now
        // alpha/beta change (prepareUpdate), gamma/delta are removed
        // (prepareRemoval): four settlement waits that must overlap.
        await controller.apply(config: PinchosConfig(items: [
            item("alpha", run: "echo changed-alpha"),
            item("beta", run: "echo changed-beta")
        ]))
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(
            elapsed, .milliseconds(150) * 4 * 3 / 4,
            "changed and removed items settling at 150ms each must overlap, not sum"
        )
    }

    func testLifecycleMenuBoundsAPathologicalValueAndOffersCopyFullOutput() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let hugeOutput = (1...5000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: hugeOutput,
            lastAttemptedAt: nil,
            lastUpdatedAt: Date(),
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        let valueTitle = try XCTUnwrap(titles.first(where: { $0.hasPrefix("Value: ") }))
        XCTAssertLessThan(valueTitle.utf8.count, 1024, "a pathological value must not become a pathological menu title")
        XCTAssertFalse(valueTitle.contains("\n"), "the menu title must never contain a raw newline")
        XCTAssertTrue(valueTitle.contains("5000 line"), "the truncation marker must report the true original line count")

        let copyItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Full Output" }))
        XCTAssertTrue(NSApplication.shared.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), hugeOutput, "copy must retrieve the exact retained text, not the preview")

        XCTAssertEqual(Array(titles.suffix(3)), ["Open Config", "Reload Config", "Quit Pinchos"], "global actions must stay reachable regardless of output size")
    }

    func testLifecycleMenuValuePreviewIsAccessibleWhenTruncated() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: String(repeating: "x", count: 64 * 1024),
            lastAttemptedAt: nil,
            lastUpdatedAt: Date(),
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let valueItem = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Value: ") }))

        XCTAssertNotNil(valueItem.accessibilityLabel())
        XCTAssertNotNil(valueItem.accessibilityHelp())
    }

    func testLifecycleMenuOmitsCopyActionsWhenOutputAndErrorAreEmpty() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "",
            lastAttemptedAt: nil,
            lastUpdatedAt: Date(),
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertFalse(titles.contains("Copy Full Output"))
        XCTAssertFalse(titles.contains("Copy Full Error"))
    }

    func testLifecycleMenuOffersCopyFullErrorWhenLastExecutionFailedWithStderr() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let execution = CommandExecution(
            terminalReason: .exited(code: 1),
            stdout: "",
            stderr: "boom\nsecond line\n",
            stdoutBytesRead: 0,
            stderrBytesRead: 18,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.01
        )
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: nil,
            lastAttemptedAt: Date(),
            lastUpdatedAt: nil,
            lastExecution: execution,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let copyItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Full Error" }))
        XCTAssertTrue(NSApplication.shared.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "boom\nsecond line\n")
    }

    func testLifecycleMenuSanitizesControlCharactersInValuePreviewAndKeepsGlobalActionsIntact() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let adversarial = "Open Config\u{0000}Reload Config\u{0007}Quit Pinchos\r\n" + String(repeating: "\r\n", count: 20)
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: adversarial,
            lastAttemptedAt: nil,
            lastUpdatedAt: Date(),
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)
        let valueTitle = try XCTUnwrap(titles.first(where: { $0.hasPrefix("Value: ") }))

        XCTAssertFalse(valueTitle.contains("\u{0000}"))
        XCTAssertFalse(valueTitle.contains("\n"))
        XCTAssertEqual(titles.filter { $0 == "Open Config" }.count, 1, "adversarial output must not fake a second global action")
        XCTAssertEqual(Array(titles.suffix(3)), ["Open Config", "Reload Config", "Quit Pinchos"])
    }

    func testLifecycleMenuOffersPerActionCopyOutputAndError() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }
        let config = ItemConfig(
            name: "codex",
            run: "echo value",
            interval: .manual,
            actions: [ItemAction(title: "Fail action", kind: .command("exit 7"))]
        )
        await controller.apply(config: PinchosConfig(items: [config]))
        let execution = CommandExecution(
            terminalReason: .exited(code: 7),
            stdout: "action stdout\n",
            stderr: "action-error\n",
            stdoutBytesRead: 14,
            stderrBytesRead: 13,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.1
        )
        factory.created[0].actionSnapshotValues = [
            CommandRunnerSnapshot(isRunning: false, lastExecution: execution, skippedRefreshes: 0)
        ]

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])

        let copyOutput = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy \"Fail action\" Output" }))
        XCTAssertTrue(NSApplication.shared.sendAction(copyOutput.action!, to: copyOutput.target, from: copyOutput))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "action stdout\n")

        let copyError = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy \"Fail action\" Error" }))
        XCTAssertTrue(NSApplication.shared.sendAction(copyError.action!, to: copyError.target, from: copyError))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "action-error\n")
    }

    /// Deterministic architectural half of the P4 "menu construction latency"
    /// budget (issue #53): rather than a wall-clock assertion (which this
    /// repo deliberately avoids in hosted CI -- see docs/performance.md),
    /// this proves the thing that actually bounds AppKit's per-open layout
    /// work is structural: the combined size of every menu item title stays
    /// a small, fixed budget no matter how large the retained output is,
    /// because every output-derived title routes through
    /// `DiagnosticPreviewFormatter` instead of embedding the raw string.
    /// Exercises the maximum allowed `max_output` value (`maxAllowedOutputBytes`)
    /// simultaneously across the primary value, primary stderr, and a
    /// command action's stdout/stderr -- the menu is still cheap to lay out,
    /// and the exact retained text for each stream remains reachable through
    /// its own Copy action.
    func testMenuConstructionCostIsBoundedIndependentOfMaxOutput() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }
        let config = ItemConfig(
            name: "codex",
            run: "echo value",
            interval: .manual,
            actions: [ItemAction(title: "Noisy action", kind: .command("false"))]
        )
        await controller.apply(config: PinchosConfig(items: [config]))

        let maximalValue = String(repeating: "v", count: maxAllowedOutputBytes)
        let maximalStderr = String(repeating: "e", count: maxAllowedOutputBytes)
        let execution = CommandExecution(
            terminalReason: .exited(code: 1),
            stdout: maximalValue,
            stderr: maximalStderr,
            stdoutBytesRead: maxAllowedOutputBytes,
            stderrBytesRead: maxAllowedOutputBytes,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.1
        )
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: maximalValue,
            lastAttemptedAt: Date(),
            lastUpdatedAt: Date(),
            lastExecution: execution,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )
        factory.created[0].actionSnapshotValues = [
            CommandRunnerSnapshot(isRunning: false, lastExecution: execution, skippedRefreshes: 0)
        ]

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])

        let totalTitleBytes = menu.items.reduce(0) { $0 + $1.title.utf8.count }
        XCTAssertLessThan(
            totalTitleBytes, 16 * 1024,
            "the combined size of every menu title must stay a small fixed budget regardless of a multi-megabyte max_output"
        )
        XCTAssertEqual(Array(menu.items.suffix(3).map(\.title)), ["Open Config", "Reload Config", "Quit Pinchos"])

        let copyOutput = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Full Output" }))
        NSApplication.shared.sendAction(copyOutput.action!, to: copyOutput.target, from: copyOutput)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string)?.utf8.count, maxAllowedOutputBytes)
    }

    func testInvalidReloadRetainsLastGoodItemsAndCorrectedReloadApplies() async {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let lastGoodItem = factory.created[0]
        factory.eventLog.clear()

        await controller.showParseError(String(describing: ConfigParseError(message: "item.alpha.intervall: unknown key", line: 4)))

        XCTAssertTrue(factory.created[0] === lastGoodItem)
        XCTAssertTrue(factory.eventLog.events.isEmpty)

        await controller.apply(config: PinchosConfig(items: [item("beta")]))

        XCTAssertEqual(factory.created.map(\.config.name), ["alpha", "beta"])
        XCTAssertEqual(factory.eventLog.events, [
            "prepare-removal:alpha",
            "commit-removal:alpha",
            "activate:beta"
        ])
    }
}
