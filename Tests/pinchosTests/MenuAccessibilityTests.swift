import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
private final class AccessibilityFakeItem: ManagedItemLifecycle {
    private(set) var config: ItemConfig
    var iconDiagnosticNote: String?
    private(set) var isVisible = true
    var runtimeSnapshotValue: ItemRuntimeSnapshot?
    var menuRowValues: [Int: String] = [:]
    var menuRowFreshnessValues: [Int: ValueFreshness] = [:]
    var menuRowSnapshotValues: [CommandRunnerSnapshot?] = []
    var menuRowRuntimeSnapshotValues: [Int: ItemRuntimeSnapshot] = [:]
    private(set) var refreshCount = 0
    private(set) var invokedRows: [Int] = []

    init(config: ItemConfig) {
        self.config = config
    }

    func owns(statusItem: NSStatusItem) -> Bool { false }
    func activate() { isVisible = true }
    func setStatusItemVisible(_ visible: Bool) {}
    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async {
        self.config = config
    }
    func commitPreparedUpdate() {}
    func prepareRemoval(deadline: ContinuousClock.Instant) async {}
    func commitRemoval() {}
    func tearDown(deadline: ContinuousClock.Instant) async {}

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

    func menuRowValue(at index: Int) -> String? {
        if let value = menuRowValues[index] { return value }
        guard config.menu.indices.contains(index) else { return nil }
        return config.menu[index].value
    }

    func menuRowFreshness(at index: Int) -> ValueFreshness {
        if let freshness = menuRowFreshnessValues[index] { return freshness }
        return ValueFreshness.interpret(
            value: menuRowValue(at: index),
            isRefreshing: false,
            lastSuccessfulAt: nil,
            lastAttemptedAt: nil,
            lastExecutionFailed: false,
            freshnessInterval: config.menu.indices.contains(index) ? config.menu[index].cache : nil,
            now: Date()
        )
    }

    func menuRowRuntimeSnapshot(at index: Int) -> ItemRuntimeSnapshot? {
        menuRowRuntimeSnapshotValues[index]
    }

    func menuRowSnapshot(at index: Int) async -> CommandRunnerSnapshot? {
        guard menuRowSnapshotValues.indices.contains(index) else { return nil }
        return menuRowSnapshotValues[index]
    }

    func invokeMenuRow(at index: Int) {
        invokedRows.append(index)
    }

    func refreshNow() {
        refreshCount += 1
    }
}

@MainActor
private final class AccessibilityFakeFactory: ManagedItemFactory {
    private(set) var created: [AccessibilityFakeItem] = []

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        let item = AccessibilityFakeItem(config: config)
        created.append(item)
        return item
    }
}

@MainActor
private final class AccessibilityMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

@MainActor
private final class AccessibilityStatusItemHost: StatusItemHost {
    func makeStatusItem() -> NSStatusItem? { NSStatusItem() }
    func removeStatusItem(_ statusItem: NSStatusItem) { statusItem.menu = nil }
    func present(menu: NSMenu, on statusItem: NSStatusItem) {}
}

/// AppKit property assertions for issue #168: informational rows are not
/// executable, glyphs are never the only state signal, and recovery/global
/// controls stay reachable.
@MainActor
final class MenuAccessibilityTests: XCTestCase {
    private func makeController(factory: AccessibilityFakeFactory) -> StatusItemController {
        let controller = StatusItemController(
            configPath: "/tmp/pinchos-a11y-test.toml",
            onReload: {},
            itemFactory: factory,
            statusItemHost: AccessibilityStatusItemHost()
        )
        addTeardownBlock { @MainActor in await controller.shutdown() }
        return controller
    }

    private func sampleConfig() -> ItemConfig {
        ItemConfig(
            name: "clock",
            run: "echo 72",
            interval: .manual,
            menu: [
                MenuRowConfig(label: "Reset", value: "2026-09-07"),
                MenuRowConfig(label: "Usage", run: "echo 72", cache: 60),
                MenuRowConfig(label: "Open docs", action: "echo open"),
                MenuRowConfig(label: "Refresh site", run: "echo 72", action: "echo open"),
                .separator,
            ]
        )
    }

    func testInformationalRowsAreNotExecutableAndActionRowsAre() async throws {
        let factory = AccessibilityFakeFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [sampleConfig()]))
        factory.created[0].menuRowValues[1] = "72"
        factory.created[0].menuRowValues[3] = "72"
        factory.created[0].menuRowFreshnessValues[1] = ValueFreshness(
            state: .ageStale,
            isAgeExpired: true,
            isSchedulerDelayed: true
        )

        let menu = await controller.makeLifecycleMenu(
            forManagedItem: factory.created[0],
            revealsDiagnostics: false
        )
        let reset = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Reset:") }))
        let usage = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Usage:") }))
        let action = try XCTUnwrap(menu.items.first(where: { $0.title == "Open docs" }))
        let combined = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Refresh site:") }))
        let separator = try XCTUnwrap(menu.items.first(where: { $0.isSeparatorItem }))

        XCTAssertFalse(reset.isEnabled)
        XCTAssertNil(reset.action)
        XCTAssertNil(reset.target)
        XCTAssertEqual(reset.accessibilityLabel(), "Reset, 2026-09-07")

        XCTAssertFalse(usage.isEnabled)
        XCTAssertNil(usage.action)
        XCTAssertEqual(usage.title, "Usage: 72\(ValueFreshness.staleMarker)")
        XCTAssertEqual(usage.accessibilityLabel(), "Usage, 72, stale, scheduler delayed")
        XCTAssertFalse(usage.accessibilityLabel()?.contains(ValueFreshness.staleMarker) == true)
        XCTAssertFalse(usage.accessibilityLabel()?.contains(ValueFreshness.warningMarker) == true)

        XCTAssertTrue(action.isEnabled)
        XCTAssertNotNil(action.action)
        XCTAssertTrue(action.target === controller)
        XCTAssertEqual(action.accessibilityLabel(), "Open docs")

        XCTAssertTrue(combined.isEnabled)
        XCTAssertNotNil(combined.action)
        XCTAssertTrue(combined.target === controller)
        XCTAssertEqual(combined.accessibilityLabel(), "Refresh site, 72, fresh")

        XCTAssertTrue(separator.isSeparatorItem)
        XCTAssertNil(separator.action)
    }

    func testGlobalControlsRemainEnabledWithTargets() async throws {
        let factory = AccessibilityFakeFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [sampleConfig()]))

        let menu = await controller.makeLifecycleMenu(
            forManagedItem: factory.created[0],
            revealsDiagnostics: false
        )
        let refresh = try XCTUnwrap(menu.items.first(where: { $0.title == "Refresh Now" }))
        let collapse = try XCTUnwrap(menu.items.first(where: { $0.title == "Collapse Pinchos" }))
        let reload = try XCTUnwrap(menu.items.first(where: { $0.title == "Reload Config" }))
        let quit = try XCTUnwrap(menu.items.first(where: { $0.title == "Quit Pinchos" }))

        for item in [refresh, collapse, reload, quit] {
            XCTAssertTrue(item.isEnabled, item.title)
            XCTAssertNotNil(item.action, item.title)
            XCTAssertTrue(item.target === controller, item.title)
        }
        XCTAssertEqual(reload.keyEquivalent, "r")
        XCTAssertEqual(quit.keyEquivalent, "q")

        XCTAssertTrue(NSApplication.shared.sendAction(refresh.action!, to: refresh.target, from: refresh))
        XCTAssertEqual(factory.created[0].refreshCount, 1)
    }

    func testControlCharactersInMenuRowValuesAreSanitized() async throws {
        let factory = AccessibilityFakeFactory()
        let controller = makeController(factory: factory)
        let config = ItemConfig(
            name: "clock",
            run: "echo 72",
            interval: .manual,
            menu: [
                MenuRowConfig(label: "Reset", value: "ok\u{0000}go\nOpen Config"),
            ]
        )
        await controller.apply(config: PinchosConfig(items: [config]))

        let menu = await controller.makeLifecycleMenu(
            forManagedItem: factory.created[0],
            revealsDiagnostics: false
        )
        let reset = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Reset:") }))
        XCTAssertFalse(reset.title.contains("\u{0000}"))
        XCTAssertFalse(reset.title.contains("\n"))
        XCTAssertTrue(reset.title.contains("\u{2400}"))
        XCTAssertTrue(reset.title.contains("\u{240A}"))
        XCTAssertEqual(menu.items.filter { $0.title == "Open Config" }.count, 1)
        XCTAssertEqual(reset.accessibilityLabel(), "Reset, ok\u{2400}go\u{240A}Open Config")
        XCTAssertFalse(reset.isEnabled)
        XCTAssertNil(reset.action)
    }

    func testIconFallbackDiagnosticIsInformational() async throws {
        let factory = AccessibilityFakeFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [
            ItemConfig(name: "clock", run: "echo 72", interval: .manual, icon: "/missing.png")
        ]))
        factory.created[0].iconDiagnosticNote =
            "icon file '/missing.png' is missing or unreadable; rendering text-only"

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let iconRow = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Icon:") }))
        XCTAssertFalse(iconRow.isEnabled)
        XCTAssertNil(iconRow.action)
        XCTAssertTrue(iconRow.title.contains("missing or unreadable"))
        XCTAssertEqual(iconRow.accessibilityLabel(), iconRow.title)
    }

    func testCopyActionsStayExecutableWithHelp() async throws {
        let factory = AccessibilityFakeFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [sampleConfig()]))
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "72",
            lastAttemptedAt: Date(),
            lastUpdatedAt: Date(),
            lastExecution: CommandExecution(
                terminalReason: .exited(code: 0),
                stdout: "72\n",
                stderr: "warn\n",
                stdoutBytesRead: 3,
                stderrBytesRead: 5,
                stdoutTruncated: false,
                stderrTruncated: false,
                duration: 0.01
            ),
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let copyOutput = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Full Output" }))
        let copyError = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Full Error" }))
        for item in [copyOutput, copyError] {
            XCTAssertTrue(item.isEnabled)
            XCTAssertNotNil(item.action)
            XCTAssertTrue(item.target === controller)
            XCTAssertEqual(
                item.accessibilityHelp(),
                "Copies the complete retained text to the clipboard, unabridged."
            )
        }
    }

    func testCollapsedExpandAndSubmenuKeepSpokenState() async throws {
        let factory = AccessibilityFakeFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [sampleConfig()]))
        let attempt = Date(timeIntervalSince1970: 1_700_000_000)
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "72",
            lastAttemptedAt: attempt,
            lastUpdatedAt: attempt,
            lastExecution: CommandExecution(
                terminalReason: .exited(code: 1),
                stdout: "72",
                stderr: "boom",
                stdoutBytesRead: 2,
                stderrBytesRead: 4,
                stdoutTruncated: false,
                stderrTruncated: false,
                duration: 0.1
            ),
            staleAfter: 60,
            skippedRefreshes: 0,
            now: attempt.addingTimeInterval(1)
        )

        let expanded = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let collapse = try XCTUnwrap(expanded.items.first(where: { $0.title == "Collapse Pinchos" }))
        XCTAssertTrue(NSApplication.shared.sendAction(collapse.action!, to: collapse.target, from: collapse))

        let collapsed = await controller.makeCollapsedMenu()
        let row = try XCTUnwrap(collapsed.items.first(where: { $0.submenu != nil }))
        XCTAssertEqual(row.title, "72\(ValueFreshness.warningMarker)")
        XCTAssertEqual(row.accessibilityLabel(), "clock, 72, failed, showing last good value")
        XCTAssertFalse(row.accessibilityLabel()?.contains(ValueFreshness.warningMarker) == true)
        XCTAssertNotNil(row.submenu?.items.first(where: { $0.title == "Refresh Now" }))

        let expand = try XCTUnwrap(collapsed.items.first(where: { $0.title == "Expand Pinchos" }))
        XCTAssertTrue(expand.isEnabled)
        XCTAssertNotNil(expand.action)
        XCTAssertTrue(expand.target === controller)
    }

    func testStatusItemButtonLabelIncludesNameAndSpokenStateWithoutGlyphs() async throws {
        let item = ManagedItem(
            config: ItemConfig(name: "clock", run: "printf '72'", interval: .manual),
            menuDelegate: AccessibilityMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            statusItemFactory: {
                NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }
        item.activate()

        let ready = await waitUntil {
            item.renderedTitle == "72" && item.statusItem?.button?.title == "72"
        }
        XCTAssertTrue(ready)
        let button = try XCTUnwrap(item.statusItem?.button)
        XCTAssertEqual(button.accessibilityLabel(), "clock, 72, fresh")
        XCTAssertFalse(button.accessibilityLabel()?.contains(ValueFreshness.staleMarker) == true)
        XCTAssertFalse(button.accessibilityLabel()?.contains(ValueFreshness.warningMarker) == true)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}
