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

final class RecoveryLifecycleTests: XCTestCase {
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
