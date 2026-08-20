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
    var actionSnapshotValues: [CommandRunnerSnapshot?] = []
    var clickSnapshotValue: ClickDiagnosticsSnapshot?

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

    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot? {
        guard actionSnapshotValues.indices.contains(index) else { return nil }
        return actionSnapshotValues[index]
    }

    func clickSnapshot() async -> ClickDiagnosticsSnapshot? {
        clickSnapshotValue
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
        XCTAssertEqual(Array(menu.items.suffix(3).map(\.title)), ["Open Config", "Reload Config", "Quit Pinchos"])
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

    func testLifecycleMenuPlacesDeclarativeActionsBeforeGlobalActions() async throws {
        let toml = """
        [item.codex]
        type = "command"
        run = "echo value"

        [[item.codex.action]]
        title = "Open usage"
        run = "open https://example.com/usage"

        [[item.codex.action]]
        title = "Refresh now"
        refresh = true
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

        XCTAssertEqual(Array(titles.prefix(2)), ["Open usage", "Refresh now"])
        XCTAssertFalse(titles.contains("Refresh Now"))
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

        for action in menu.items.prefix(2) {
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

    func testLifecycleMenuOmitsClickSectionWhenNoClickConfigured() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Click Action:") }))
    }

    func testLifecycleMenuShowsNeverRunClickState() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        factory.created[0].clickSnapshotValue = ClickDiagnosticsSnapshot(
            runner: CommandRunnerSnapshot(isRunning: false, lastExecution: nil, skippedRefreshes: 0),
            lastAttemptedAt: nil,
            lastCompletedAt: nil
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Click Action: never run"))
    }

    func testLifecycleMenuShowsRunningClickStateWithoutTouchingPrimaryStatus() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "fresh",
            lastAttemptedAt: nil,
            lastUpdatedAt: nil,
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )
        factory.created[0].clickSnapshotValue = ClickDiagnosticsSnapshot(
            runner: CommandRunnerSnapshot(isRunning: true, lastExecution: nil, skippedRefreshes: 0),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastCompletedAt: nil
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Click Action: running"))
        XCTAssertTrue(titles.contains("Click Action: last attempt: 2023-11-14T22:13:20Z"))
        XCTAssertTrue(titles.contains("State: fresh"))
        XCTAssertTrue(titles.contains("Value: fresh"))
    }

    func testLifecycleMenuShowsSuccessfulClickDiagnosticsAndCopyActions() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let execution = CommandExecution(
            terminalReason: .exited(code: 0),
            stdout: "click output\n",
            stderr: "",
            stdoutBytesRead: 13,
            stderrBytesRead: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.05
        )
        factory.created[0].clickSnapshotValue = ClickDiagnosticsSnapshot(
            runner: CommandRunnerSnapshot(isRunning: false, lastExecution: execution, skippedRefreshes: 0),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastCompletedAt: Date(timeIntervalSince1970: 1_700_000_000.05)
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Click Action: completed"))
        XCTAssertTrue(titles.contains("Click Action: last exit code: 0"))
        XCTAssertTrue(titles.contains("Click Action: duration: 0.050s"))
        XCTAssertTrue(titles.contains("Click Action: stdout: 13 bytes"))
        XCTAssertTrue(titles.contains("Click Action: stderr: 0 bytes"))
        XCTAssertTrue(titles.contains("Click Action: last attempt: 2023-11-14T22:13:20Z"))

        let copyItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Click Output" }))
        XCTAssertTrue(NSApplication.shared.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "click output\n")
        XCTAssertNil(menu.items.first(where: { $0.title == "Copy Click Error" }))
    }

    func testLifecycleMenuShowsFailedClickDiagnosticsWithStderrPreviewAndCopyAction() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }

        await controller.apply(config: PinchosConfig(items: [item("alpha")]))
        let execution = CommandExecution(
            terminalReason: .exited(code: 7),
            stdout: "",
            stderr: "click failed\n",
            stdoutBytesRead: 0,
            stderrBytesRead: 13,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.02
        )
        factory.created[0].clickSnapshotValue = ClickDiagnosticsSnapshot(
            runner: CommandRunnerSnapshot(isRunning: false, lastExecution: execution, skippedRefreshes: 3),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastCompletedAt: Date(timeIntervalSince1970: 1_700_000_000.02)
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Click Action: error"))
        XCTAssertTrue(titles.contains("Click Action: last exit code: 7"))
        XCTAssertTrue(titles.contains("Click Action: stderr: click failed"))
        XCTAssertTrue(titles.contains("Click Action: skipped invocations: 3"))

        let copyItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Click Error" }))
        XCTAssertTrue(NSApplication.shared.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "click failed\n")
        XCTAssertNil(menu.items.first(where: { $0.title == "Copy Click Output" }))
    }

    func testLifecycleMenuDistinguishesSignalTimeoutCancelledAndLaunchFailure() async throws {
        let factory = FakeManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
        }
        await controller.apply(config: PinchosConfig(items: [item("alpha")]))

        func execution(_ reason: CommandTerminalReason) -> CommandExecution {
            CommandExecution(
                terminalReason: reason,
                stdout: "",
                stderr: "",
                stdoutBytesRead: 0,
                stderrBytesRead: 0,
                stdoutTruncated: false,
                stderrTruncated: false,
                duration: 0.01
            )
        }

        let cases: [(reason: CommandTerminalReason, state: String, detail: String)] = [
            (.signaled(signal: 9), "Click Action: error", "Click Action: last signal: 9"),
            (.timedOut, "Click Action: timed out", "Click Action: last result: timed out"),
            (.cancelled, "Click Action: cancelled", "Click Action: last result: cancelled"),
            (.launchFailed("shell missing"), "Click Action: error", "Click Action: last result: launch failed")
        ]

        for testCase in cases {
            factory.created[0].clickSnapshotValue = ClickDiagnosticsSnapshot(
                runner: CommandRunnerSnapshot(
                    isRunning: false,
                    lastExecution: execution(testCase.reason),
                    skippedRefreshes: 0
                ),
                lastAttemptedAt: nil,
                lastCompletedAt: nil
            )
            let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
            let titles = menu.items.map(\.title)
            XCTAssertTrue(titles.contains(testCase.state), "expected \(testCase.state) for \(testCase.reason)")
            XCTAssertTrue(titles.contains(testCase.detail), "expected \(testCase.detail) for \(testCase.reason)")
        }
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
