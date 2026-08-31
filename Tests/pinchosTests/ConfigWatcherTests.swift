import Foundation
import XCTest
@testable import pinchos

private final class WatcherCallbackCounter: @unchecked Sendable {
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

final class ConfigWatcherTests: XCTestCase {
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

        let counter = WatcherCallbackCounter()
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

    func testMissingConfigWatcherDoesNotRetryPeriodicallyWhileFilesystemIsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-idle-\(UUID().uuidString)", isDirectory: true)
        // Create a private empty ancestor so the watcher attaches here instead of
        // the shared system temp directory (which receives unrelated write events
        // from other tests and would force spurious reattach).
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let attempts = WatcherCallbackCounter()
        let watcher = ConfigWatcher(
            path: configURL.path,
            onChange: {},
            onAttachAttempt: { _ = attempts.increment() }
        )
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: root)
        }

        watcher.start()
        try await Task.sleep(for: .milliseconds(200))
        let attemptsAfterInitialAttach = attempts.value
        XCTAssertEqual(attemptsAfterInitialAttach, 1, "start() should attach exactly once for a missing config")

        // The old implementation retried every 500ms; wait several multiples of
        // that and confirm the attempt count is still flat with nothing on disk
        // having changed.
        try await Task.sleep(for: .milliseconds(1_600))
        XCTAssertEqual(
            attempts.value,
            attemptsAfterInitialAttach,
            "watcher must not re-open while the filesystem is unchanged"
        )
    }

    func testDeeplyMissingAncestorChainStillNotifiesOnceFullyCreated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-deep-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("a/b/c/pinchos.toml")
        let callback = expectation(description: "deep ancestor config watcher callback")
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
        try "value = 1".write(to: configURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [callback], timeout: 3)
    }

    func testAtomicReplaceTriggersCallbackAndLeavesReplacementWatched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-atomic-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "initial".write(to: configURL, atomically: true, encoding: .utf8)

        let counter = WatcherCallbackCounter()
        let initialCallback = expectation(description: "initial callback")
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
        let afterInitial = counter.value

        // Simulate the temp-file + rename atomic-save pattern common editors use.
        try "replaced".write(to: configURL, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, counter.value == afterInitial {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(counter.value, afterInitial, "atomic replace should trigger a reload callback")

        // The replacement file must still be the one being watched: another
        // write after the replace should also trigger a callback.
        let afterReplace = counter.value
        try await Task.sleep(for: .milliseconds(150))
        try "written-after-replace".write(to: configURL, atomically: false, encoding: .utf8)

        let secondDeadline = Date().addingTimeInterval(3)
        while Date() < secondDeadline, counter.value == afterReplace {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(counter.value, afterReplace, "writes to the replacement file should still be watched")
    }

    func testDeleteThenRecreateNotifiesWithoutPeriodicRetryInBetween() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-delete-recreate-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "initial".write(to: configURL, atomically: true, encoding: .utf8)

        let counter = WatcherCallbackCounter()
        let attempts = WatcherCallbackCounter()
        let initialCallback = expectation(description: "initial callback")
        initialCallback.assertForOverFulfill = false
        let watcher = ConfigWatcher(
            path: configURL.path,
            onChange: {
                if counter.increment() == 1 {
                    initialCallback.fulfill()
                }
            },
            onAttachAttempt: { _ = attempts.increment() }
        )
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: root)
        }

        watcher.start()
        await fulfillment(of: [initialCallback], timeout: 3)
        try await Task.sleep(for: .milliseconds(150))

        try FileManager.default.removeItem(at: configURL)
        // Give the delete event time to be delivered and settle onto the parent
        // directory watch, then confirm the watcher stays idle while the file
        // remains absent, rather than retrying on a timer.
        try await Task.sleep(for: .milliseconds(200))
        let attemptsWhileMissing = attempts.value
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(
            attempts.value,
            attemptsWhileMissing,
            "watcher must not poll while the config stays deleted"
        )

        let afterDelete = counter.value
        try "recreated".write(to: configURL, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, counter.value == afterDelete {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(counter.value, afterDelete, "recreating the config should trigger a reload callback")
    }

    func testRenamingParentDirectoryAwayAndRecreatingIsHandled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-rename-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configDir = root.appendingPathComponent("pinchos")
        let configURL = configDir.appendingPathComponent("pinchos.toml")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "initial".write(to: configURL, atomically: true, encoding: .utf8)

        let counter = WatcherCallbackCounter()
        let initialCallback = expectation(description: "initial callback")
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
        let afterInitial = counter.value

        let renamedDir = root.appendingPathComponent("pinchos-moved")
        try FileManager.default.moveItem(at: configDir, to: renamedDir)
        try await Task.sleep(for: .milliseconds(300))

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "recreated-after-parent-rename".write(to: configURL, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, counter.value == afterInitial {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(counter.value, afterInitial, "recreating the renamed-away parent directory should be picked up")
    }

    func testStartCalledTwiceDoesNotDuplicateNotifications() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-double-start-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let counter = WatcherCallbackCounter()
        let watcher = ConfigWatcher(path: configURL.path) {
            _ = counter.increment()
        }
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: root)
        }

        watcher.start()
        watcher.start()
        try await Task.sleep(for: .milliseconds(150))

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "value = 1".write(to: configURL, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, counter.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.value, 1, "double start() must not register duplicate sources")
    }

    func testStopPreventsAlreadyScheduledDebounceCallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-stop-debounce-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "initial".write(to: configURL, atomically: true, encoding: .utf8)

        let counter = WatcherCallbackCounter()
        let initialCallback = expectation(description: "initial callback")
        initialCallback.assertForOverFulfill = false
        let watcher = ConfigWatcher(path: configURL.path) {
            if counter.increment() == 1 {
                initialCallback.fulfill()
            }
        }

        watcher.start()
        await fulfillment(of: [initialCallback], timeout: 3)
        try await Task.sleep(for: .milliseconds(150))
        let afterInitial = counter.value

        // Trigger the ~0.25s debounce, then stop before it can fire.
        try "changed".write(to: configURL, atomically: false, encoding: .utf8)
        watcher.stop()

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(counter.value, afterInitial, "stop() must cancel already-scheduled debounce callbacks")

        try? FileManager.default.removeItem(at: root)
    }

    func testRepeatedStartStopDeleteRecreateKeepsDescriptorCountStable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-descriptor-stress-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        func openDescriptorCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }

        try await Task.sleep(for: .milliseconds(30))
        let baseline = openDescriptorCount()
        XCTAssertGreaterThanOrEqual(baseline, 0)

        for iteration in 0..<8 {
            let counter = WatcherCallbackCounter()
            let callback = expectation(description: "cycle \(iteration) callback")
            let watcher = ConfigWatcher(path: configURL.path) {
                _ = counter.increment()
                callback.fulfill()
            }
            watcher.start()
            try "cycle-\(iteration)".write(to: configURL, atomically: true, encoding: .utf8)
            await fulfillment(of: [callback], timeout: 3)
            watcher.stop()
            try? FileManager.default.removeItem(at: configURL)
            try await Task.sleep(for: .milliseconds(30))
        }

        try? FileManager.default.removeItem(at: root)
        try await Task.sleep(for: .milliseconds(50))
        let settled = openDescriptorCount()
        XCTAssertLessThanOrEqual(
            settled,
            baseline + 2,
            "repeated start/stop/delete/recreate cycles must not leak descriptors"
        )
    }
}
