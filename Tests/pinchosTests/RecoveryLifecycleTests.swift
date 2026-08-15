import XCTest
@testable import pinchos
@testable import PinchosCore

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
}
