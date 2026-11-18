import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

/// Trust boundary (#163): menu items built by the real controller for a real
/// `ManagedItem` must not run commands a reload swapped in while that menu
/// was open, and a menu built after the reload must work.
@MainActor
final class StaleMenuTargetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-stale-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRefreshNowFromAMenuBuiltBeforeSourceReplacementIsRejected() async throws {
        let (controller, factory) = makeController()
        let old = marker("old-primary")
        let new = marker("new-primary")
        let oldRow = marker("old-row")
        let newRow = marker("new-row")
        await controller.apply(config: config(
            run: "touch '\(old.path)'; printf old",
            menu: [MenuRowConfig(label: "Usage", run: "touch '\(oldRow.path)'; printf old")]
        ))
        let item = try XCTUnwrap(factory.created.first)
        let staleMenu = controller.makeLifecycleMenuImmediately(forManagedItem: item)
        let staleRefresh = try XCTUnwrap(staleMenu.items.first { $0.title == "Refresh Now" })

        await controller.apply(config: config(
            run: "touch '\(new.path)'; printf new",
            menu: [MenuRowConfig(label: "Usage", run: "touch '\(newRow.path)'; printf new")]
        ))
        // Opening a menu or committing a reload may refresh values on its
        // own; let that settle so only the click below can create markers.
        await item.awaitPrimaryRefreshForTesting()
        await settle()
        try clear(old, new, oldRow, newRow)

        XCTAssertTrue(NSApplication.shared.sendAction(staleRefresh.action!, to: staleRefresh.target, from: staleRefresh))
        await settle()
        for path in [old, new, oldRow, newRow] {
            XCTAssertFalse(exists(path), "stale Refresh Now ran \(path.lastPathComponent)")
        }

        let currentMenu = controller.makeLifecycleMenuImmediately(forManagedItem: item)
        let currentRefresh = try XCTUnwrap(currentMenu.items.first { $0.title == "Refresh Now" })
        XCTAssertTrue(NSApplication.shared.sendAction(currentRefresh.action!, to: currentRefresh.target, from: currentRefresh))
        let ran = await waitUntil { self.exists(new) && self.exists(newRow) }
        XCTAssertTrue(ran, "Refresh Now from a menu built after the reload did not run the current sources")
        XCTAssertFalse(exists(old))
        XCTAssertFalse(exists(oldRow))
    }

    func testRefreshNowSurvivesAReloadThatKeepsTheSources() async throws {
        let (controller, factory) = makeController()
        let ran = marker("primary")
        let run = "touch '\(ran.path)'; printf v"
        await controller.apply(config: config(run: run, menu: []))
        let item = try XCTUnwrap(factory.created.first)

        let menu = controller.makeLifecycleMenuImmediately(forManagedItem: item)
        let refresh = try XCTUnwrap(menu.items.first { $0.title == "Refresh Now" })
        await controller.apply(config: PinchosConfig(items: [
            ItemConfig(name: "item", run: run, interval: .manual, format: "{output}!", menu: [])
        ]))
        await item.awaitPrimaryRefreshForTesting()
        await settle()
        try clear(ran)

        XCTAssertTrue(NSApplication.shared.sendAction(refresh.action!, to: refresh.target, from: refresh))
        let refreshed = await waitUntil { self.exists(ran) }
        XCTAssertTrue(refreshed, "a presentation-only reload invalidated Refresh Now")
    }

    func testActionRowFromAMenuBuiltBeforeRowReorderIsRejected() async throws {
        let (controller, factory) = makeController()
        let deploy = marker("deploy")
        let wipe = marker("wipe")
        let deployRow = MenuRowConfig(label: "Deploy", action: "touch '\(deploy.path)'")
        let wipeRow = MenuRowConfig(label: "Wipe", action: "touch '\(wipe.path)'")
        await controller.apply(config: config(run: "printf v", menu: [deployRow, wipeRow]))
        let item = try XCTUnwrap(factory.created.first)

        let staleMenu = controller.makeLifecycleMenuImmediately(forManagedItem: item)
        let staleDeploy = try XCTUnwrap(staleMenu.items.first { $0.title == "Deploy" })

        await controller.apply(config: config(run: "printf v", menu: [wipeRow, deployRow]))
        XCTAssertTrue(NSApplication.shared.sendAction(staleDeploy.action!, to: staleDeploy.target, from: staleDeploy))
        await settle()
        XCTAssertFalse(exists(wipe), "a stale Deploy row ran Wipe")
        XCTAssertFalse(exists(deploy), "a stale row ran after its configuration was replaced")

        let currentMenu = controller.makeLifecycleMenuImmediately(forManagedItem: item)
        let currentDeploy = try XCTUnwrap(currentMenu.items.first { $0.title == "Deploy" })
        XCTAssertTrue(NSApplication.shared.sendAction(currentDeploy.action!, to: currentDeploy.target, from: currentDeploy))
        let ran = await waitUntil { self.exists(deploy) }
        XCTAssertTrue(ran, "Deploy from a menu built after the reload did not run")
        XCTAssertFalse(exists(wipe))
    }

    // MARK: - Helpers

    private func makeController() -> (StatusItemController, RecordingItemFactory) {
        let scheduler = CommandScheduler()
        let factory = RecordingItemFactory(scheduler: scheduler)
        let controller = StatusItemController(
            configPath: root.appendingPathComponent("pinchos.toml").path,
            onReload: {},
            itemFactory: factory,
            scheduler: scheduler,
            statusItemHost: DetachedStatusItemHost()
        )
        addTeardownBlock { @MainActor in await controller.shutdown() }
        return (controller, factory)
    }

    private func config(run: String, menu: [MenuRowConfig]) -> PinchosConfig {
        PinchosConfig(items: [ItemConfig(name: "item", run: run, interval: .manual, menu: menu)])
    }

    private func marker(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func clear(_ urls: URL...) throws {
        for url in urls where exists(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Gives wrongly accepted work time to start a process.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }
}

@MainActor
private final class RecordingItemFactory: ManagedItemFactory {
    let scheduler: CommandScheduler
    let sourceRegistry = CommandSourceRegistry()
    private(set) var created: [ManagedItem] = []

    init(scheduler: CommandScheduler) {
        self.scheduler = scheduler
    }

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        let item = ManagedItem(
            config: config,
            menuDelegate: menuDelegate,
            initiallyVisible: initiallyVisible,
            scheduler: scheduler,
            sourceRegistry: sourceRegistry
        )
        created.append(item)
        return item
    }
}

@MainActor
private final class DetachedStatusItemHost: StatusItemHost {
    func makeStatusItem() -> NSStatusItem? { NSStatusItem() }
    func removeStatusItem(_ item: NSStatusItem) { item.menu = nil }
    func present(menu: NSMenu, on statusItem: NSStatusItem) {}
}
