import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

@MainActor
final class RecoveryLifecycleTests: XCTestCase {
    func testEmptyConfigCreatesVisibleControlItem() async {
        let controller = StatusItemController(configPath: "/tmp/pinchos-test/pinchos.toml", onReload: {})

        await controller.apply(config: PinchosConfig(items: []))

        let item = reflectedStatusItem(from: controller)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.button?.title, "pinchos")

        await controller.shutdown()
    }

    func testConfiguredItemRemovesControlItem() async {
        let controller = StatusItemController(configPath: "/tmp/pinchos-test/pinchos.toml", onReload: {})
        let itemConfig = ItemConfig(name: "clock", run: "echo clock", interval: 60)

        await controller.apply(config: PinchosConfig(items: []))
        XCTAssertNotNil(reflectedStatusItem(from: controller))

        await controller.apply(config: PinchosConfig(items: [itemConfig]))

        XCTAssertNil(reflectedStatusItem(from: controller))
        await controller.shutdown()
    }

    func testMissingConfigWatcherNotifiesWhenFileAppears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-6-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let callback = expectation(description: "config watcher callback")
        let watcher = ConfigWatcher(path: configURL.path) {
            callback.fulfill()
        }

        watcher.start()
        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: configURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [callback], timeout: 3)
        watcher.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func reflectedStatusItem(from controller: StatusItemController) -> NSStatusItem? {
        let mirror = Mirror(reflecting: controller)
        return mirror.children.first { child in
            child.label == "warningItem"
        }?.value as? NSStatusItem
    }
}
