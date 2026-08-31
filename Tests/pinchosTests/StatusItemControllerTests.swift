import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
private final class ControllerEventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func clear() { events.removeAll() }
}

@MainActor
private final class TestManagedItem: ManagedItemLifecycle {
    private let log: ControllerEventLog
    private var pendingConfig: ItemConfig?
    private(set) var config: ItemConfig
    var iconDiagnosticNote: String?
    var cachedRuntimeSnapshot: ItemRuntimeSnapshot
    var runtimeSnapshotValue: ItemRuntimeSnapshot
    var settlementDelay: Duration?
    let ownedStatusItem: NSStatusItem?

    init(
        config: ItemConfig,
        log: ControllerEventLog,
        ownedStatusItem: NSStatusItem? = nil
    ) {
        self.config = config
        self.log = log
        self.ownedStatusItem = ownedStatusItem
        let empty = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: nil,
            lastAttemptedAt: nil,
            lastUpdatedAt: nil,
            lastExecution: nil,
            skippedRefreshes: 0
        )
        cachedRuntimeSnapshot = empty
        runtimeSnapshotValue = empty
    }

    func owns(statusItem: NSStatusItem) -> Bool { ownedStatusItem === statusItem }

    func activate() { log.append("activate:\(config.name)") }

    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async {
        log.append("prepare-update:\(config.name)")
        pendingConfig = config
        if let settlementDelay { try? await Task.sleep(for: settlementDelay) }
    }

    func commitPreparedUpdate() {
        config = pendingConfig!
        pendingConfig = nil
        log.append("commit-update:\(config.name)")
    }

    func prepareRemoval(deadline: ContinuousClock.Instant) async {
        log.append("prepare-removal:\(config.name)")
        if let settlementDelay { try? await Task.sleep(for: settlementDelay) }
    }

    func commitRemoval() { log.append("commit-removal:\(config.name)") }

    func tearDown(deadline: ContinuousClock.Instant) async {
        await prepareRemoval(deadline: deadline)
        commitRemoval()
    }

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        runtimeSnapshotValue.runnerSnapshot
    }

    func runtimeSnapshot() async -> ItemRuntimeSnapshot {
        log.append("snapshot:\(config.name)")
        return runtimeSnapshotValue
    }

    func refreshNow() { log.append("refresh:\(config.name)") }
}

@MainActor
private final class TestManagedItemFactory: ManagedItemFactory {
    let log = ControllerEventLog()
    private(set) var created: [TestManagedItem] = []

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        let item = TestManagedItem(config: config, log: log)
        created.append(item)
        log.append("create:\(config.name):\(initiallyVisible)")
        return item
    }
}

@MainActor
private final class NullStatusItemHost: StatusItemHost {
    private(set) var makeCount = 0
    private(set) var removedCount = 0
    private(set) var presentedMenus: [NSMenu] = []

    func makeStatusItem() -> NSStatusItem? {
        makeCount += 1
        return nil
    }

    func removeStatusItem(_ statusItem: NSStatusItem) { removedCount += 1 }

    func present(menu: NSMenu, on statusItem: NSStatusItem) {
        presentedMenus.append(menu)
    }
}

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private func item(_ name: String, run: String? = nil) -> ItemConfig {
        ItemConfig(name: name, run: run ?? "printf \(name)")
    }

    private func makeController(
        factory: TestManagedItemFactory,
        host: NullStatusItemHost = NullStatusItemHost(),
        configPath: String = "/tmp/pinchos-controller-tests/config.toml",
        onReload: @escaping () -> Void = {}
    ) -> StatusItemController {
        StatusItemController(
            configPath: configPath,
            onReload: onReload,
            itemFactory: factory,
            statusItemHost: host
        )
    }

    func testInitialApplyCreatesReverseNativeOrderAndActivatesDeclarationOrder() async {
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [item("a"), item("b"), item("c")]))

        XCTAssertEqual(factory.created.map { $0.config.name }, ["c", "b", "a"])
        XCTAssertEqual(factory.log.events, [
            "create:c:false", "create:b:false", "create:a:false",
            "activate:a", "activate:b", "activate:c",
        ])
    }

    func testChangedAndRemovedItemsSettleBeforeCommitAndAddedItemActivates() async {
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [item("a"), item("b")]))
        factory.log.clear()

        await controller.apply(config: PinchosConfig(items: [
            item("x"),
            item("a", run: "printf changed"),
        ]))

        XCTAssertEqual(factory.created.map { $0.config.name }, ["b", "a", "x"])
        XCTAssertTrue(factory.log.events.contains("prepare-update:a"))
        XCTAssertTrue(factory.log.events.contains("prepare-removal:b"))
        XCTAssertTrue(factory.log.events.contains("commit-update:a"))
        XCTAssertTrue(factory.log.events.contains("commit-removal:b"))
        XCTAssertTrue(factory.log.events.contains("activate:x"))
        XCTAssertLessThan(
            factory.log.events.firstIndex(of: "prepare-update:a")!,
            factory.log.events.firstIndex(of: "commit-update:a")!
        )
    }

    func testReorderRebuildsEveryNativeStatusItem() async {
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [item("a"), item("b")]))
        factory.log.clear()
        await controller.apply(config: PinchosConfig(items: [item("b"), item("a")]))

        XCTAssertEqual(factory.created.map { $0.config.name }, ["b", "a", "a", "b"])
        XCTAssertTrue(factory.log.events.contains("prepare-removal:a"))
        XCTAssertTrue(factory.log.events.contains("prepare-removal:b"))
        XCTAssertTrue(factory.log.events.contains("commit-removal:a"))
        XCTAssertTrue(factory.log.events.contains("commit-removal:b"))
    }

    func testParseFailureLeavesLastGoodItemsUntouched() async {
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [item("a")]))
        let original = factory.created[0]
        factory.log.clear()

        await controller.showParseError("line 4: item.a: unknown key 'click'")

        XCTAssertTrue(factory.created[0] === original)
        XCTAssertTrue(factory.log.events.isEmpty)
    }

    func testReloadSettlementAcrossItemsIsConcurrent() async {
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }

        await controller.apply(config: PinchosConfig(items: [item("a"), item("b"), item("c"), item("d")]))
        factory.created.forEach { $0.settlementDelay = .milliseconds(150) }

        let clock = ContinuousClock()
        let start = clock.now
        await controller.apply(config: PinchosConfig(items: [
            item("a", run: "printf changed-a"),
            item("b", run: "printf changed-b"),
        ]))
        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .milliseconds(450), "four 150ms settlements must overlap")
    }

    func testShutdownTearsDownEveryItem() async {
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        await controller.apply(config: PinchosConfig(items: [item("a"), item("b")]))
        factory.log.clear()

        await controller.shutdown()

        XCTAssertTrue(factory.log.events.contains("prepare-removal:a"))
        XCTAssertTrue(factory.log.events.contains("prepare-removal:b"))
        XCTAssertTrue(factory.log.events.contains("commit-removal:a"))
        XCTAssertTrue(factory.log.events.contains("commit-removal:b"))
    }

    func testCompactMenuContainsOnlyRefreshAndGlobalOperations() async {
        _ = NSApplication.shared
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }
        await controller.apply(config: PinchosConfig(items: [item("a")]))
        factory.log.clear()

        let menu = await controller.makeLifecycleMenu(
            forManagedItem: factory.created[0],
            revealsDiagnostics: false
        )

        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "Refresh Now", "Open Config", "Reload Config", "Quit Pinchos",
        ])
        XCTAssertFalse(factory.log.events.contains("snapshot:a"))

        let refresh = menu.items.first { $0.title == "Refresh Now" }!
        XCTAssertTrue(NSApplication.shared.sendAction(refresh.action!, to: refresh.target, from: refresh))
        XCTAssertTrue(factory.log.events.contains("refresh:a"))
    }

    func testDiagnosticsMenuBoundsPreviewAndCopiesExactOutputAndError() async throws {
        _ = NSApplication.shared
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in await controller.shutdown() }
        await controller.apply(config: PinchosConfig(items: [item("a")]))

        let output = (1...5_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let error = "boom\nsecond line\n"
        let execution = CommandExecution(
            terminalReason: .exited(code: 7),
            stdout: output,
            stderr: error,
            stdoutBytesRead: output.utf8.count,
            stderrBytesRead: error.utf8.count,
            stdoutTruncated: false,
            stderrTruncated: false,
            duration: 0.25
        )
        factory.created[0].runtimeSnapshotValue = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: output,
            lastAttemptedAt: Date(),
            lastUpdatedAt: Date(),
            lastExecution: execution,
            skippedRefreshes: 2
        )

        let menu = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])
        let titles = menu.items.map(\.title)
        let value = try XCTUnwrap(titles.first { $0.hasPrefix("Value: ") })
        XCTAssertLessThan(value.utf8.count, 1_024)
        XCTAssertFalse(value.contains("\n"))
        XCTAssertTrue(value.contains("5000 line"))
        XCTAssertEqual(Array(titles.suffix(3)), ["Open Config", "Reload Config", "Quit Pinchos"])

        let copyOutput = try XCTUnwrap(menu.items.first { $0.title == "Copy Full Output" })
        XCTAssertTrue(NSApplication.shared.sendAction(copyOutput.action!, to: copyOutput.target, from: copyOutput))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), output)

        let copyError = try XCTUnwrap(menu.items.first { $0.title == "Copy Full Error" })
        XCTAssertTrue(NSApplication.shared.sendAction(copyError.action!, to: copyError.target, from: copyError))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), error)
    }

    func testMenuConstructionNeverRunsConfiguredCommand() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-menu-command-\(UUID().uuidString)")
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
            try? FileManager.default.removeItem(at: marker)
        }
        await controller.apply(config: PinchosConfig(items: [
            item("a", run: "touch '\(marker.path)'")
        ]))

        _ = await controller.makeLifecycleMenu(forManagedItem: factory.created[0])

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(factory.log.events.contains("refresh:a"))
    }

    func testWriteExampleConfigUsesCanonicalSourceAndNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-controller-config-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("pinchos.toml").path
        let factory = TestManagedItemFactory()
        let controller = makeController(factory: factory, configPath: path)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        try controller.writeExampleConfig()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), ExampleConfig.text)

        try "custom".write(toFile: path, atomically: true, encoding: .utf8)
        try controller.writeExampleConfig()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "custom")
    }
}
