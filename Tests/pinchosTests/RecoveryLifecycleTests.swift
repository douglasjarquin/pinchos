import XCTest
@testable import pinchos
@testable import PinchosCore

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return valueStorage
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        valueStorage += 1
        return valueStorage
    }
}

@MainActor
private final class NoopStatusItemMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

final class RecoveryLifecycleTests: XCTestCase {
    @MainActor
    func testManualItemRunsOnceOnActivationWithoutPeriodicTimer() async throws {
        let item = ManagedItem(
            config: ItemConfig(
                name: "manual",
                run: "printf 'manual\\n'",
                interval: .manual
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.activate()
        let first = try await waitForExecution(item)
        XCTAssertEqual(first.lastExecution?.stdout, "manual\n")

        try await Task.sleep(for: .milliseconds(200))
        let settled = await item.runnerSnapshot()
        XCTAssertEqual(settled.skippedRefreshes, 0)
        XCTAssertEqual(settled.lastExecution?.stdout, "manual\n")
    }

    @MainActor
    func testManualRefreshKeepsLastGoodValueWhileAnotherRefreshRuns() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-manual-refresh-\(UUID().uuidString)")
        let item = ManagedItem(
            config: ItemConfig(
                name: "manual",
                run: "if [ ! -e '\(marker.path)' ]; then printf 'old\\n'; touch '\(marker.path)'; else sleep 0.3; printf 'new\\n'; fi",
                interval: .manual
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.refreshNow()
        _ = try await waitForExecution(item)
        XCTAssertEqual(item.statusItem.button?.title, "old")

        item.refreshNow()
        try await waitForRunning(item)
        item.refreshNow()
        _ = try await waitForSkippedRefresh(item)

        XCTAssertEqual(item.statusItem.button?.title, "old")
        try await waitForIdle(item)
        XCTAssertEqual(item.statusItem.button?.title, "new")
    }

    @MainActor
    private func waitForExecution(_ item: ManagedItem) async throws -> CommandRunnerSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let snapshot = await item.runnerSnapshot()
            if snapshot.lastExecution != nil {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "manual item did not perform its initial run"]
        )
    }

    @MainActor
    private func waitForRunning(_ item: ManagedItem) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await item.runnerSnapshot().isRunning {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "manual refresh did not become active"]
        )
    }

    @MainActor
    private func waitForSkippedRefresh(_ item: ManagedItem) async throws -> CommandRunnerSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let snapshot = await item.runnerSnapshot()
            if snapshot.skippedRefreshes > 0 {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "manual refresh was not coalesced while active"]
        )
    }

    @MainActor
    private func waitForIdle(_ item: ManagedItem) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !(await item.runnerSnapshot().isRunning) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "manual refresh did not settle"]
        )
    }

    @MainActor
    func testExampleConfigCreationReportsFileFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-6-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let configURL = blocker.appendingPathComponent("pinchos.toml")
        let controller = StatusItemController(configPath: configURL.path, onReload: {})
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try controller.writeExampleConfig())
    }

    func testMissingConfigWatcherNotifiesWhenFileAppears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-6-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let callback = expectation(description: "config watcher callback")
        let watcher = ConfigWatcher(path: configURL.path) {
            callback.fulfill()
        }
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: root)
        }

        watcher.start()
        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [item.clock]
        type = "command"
        run = "echo clock"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [callback], timeout: 3)
        let loaded = try ConfigParser.parse(String(contentsOf: configURL, encoding: .utf8))
        XCTAssertEqual(loaded.items.map(\.name), ["clock"])
    }

    func testRapidConfigWritesAreCoalescedIntoOneReloadNotification() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-7-debounce-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "initial".write(to: configURL, atomically: true, encoding: .utf8)

        let counter = CallbackCounter()
        let initialCallback = expectation(description: "initial config watcher callback")
        initialCallback.assertForOverFulfill = false
        let watcher = ConfigWatcher(path: configURL.path) {
            if counter.increment() == 1 {
                initialCallback.fulfill()
            }
        }
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: root)
        }

        watcher.start()
        await fulfillment(of: [initialCallback], timeout: 3)
        try await Task.sleep(for: .milliseconds(150))
        let settledCallbackCount = counter.value

        try "first".write(to: configURL, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(40))
        try "second".write(to: configURL, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(counter.value - settledCallbackCount, 1)
    }
}
