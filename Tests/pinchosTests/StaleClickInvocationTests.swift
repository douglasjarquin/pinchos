import Darwin
import XCTest
@testable import pinchos
@testable import PinchosCore

/// A deterministic rendezvous point that pauses a `ManagedItem` click/action
/// invocation task right after it has been accepted but before it re-checks
/// lifecycle state and starts its captured runner. Tests arm the gate, wait for
/// `armed` to flip (proving the invocation reached the checkpoint), perform a
/// config reload or removal, and then release the gate to resume the task -
/// letting the reload/removal race land in the acceptance-to-start window on
/// every run instead of depending on scheduler timing.
private final class InvocationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isArmed = false
    private var isReleased = false

    var armed: Bool {
        withLock { isArmed }
    }

    func wait() async {
        let alreadyReleased = withLock {
            isArmed = true
            return isReleased
        }
        guard !alreadyReleased else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.install(continuation)
        }
    }

    func release() {
        let pendingContinuation = withLock {
            isReleased = true
            let existing = continuation
            continuation = nil
            return existing
        }
        pendingContinuation?.resume()
    }

    private func install(_ continuation: CheckedContinuation<Void, Never>) {
        let shouldResumeImmediately = withLock {
            if isReleased {
                return true
            }
            self.continuation = continuation
            return false
        }
        if shouldResumeImmediately {
            continuation.resume()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
private final class NoopStatusItemMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

final class StaleClickInvocationTests: XCTestCase {
    @MainActor
    private func makeHeadlessItem(config: ItemConfig) -> ManagedItem {
        ManagedItem(
            config: config,
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false,
            statusItemFactory: { nil }
        )
    }

    private func tempMarker(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-47-\(name)-\(UUID().uuidString)")
    }

    // MARK: - Core race: queued click under command A must not run after a reload commits command B.

    @MainActor
    func testQueuedClickUnderOldCommandNeverRunsAfterReloadCommitsNewCommand() async throws {
        let markerA = tempMarker("stale-a")
        let markerB = tempMarker("stale-b")
        let gate = InvocationGate()
        let item = makeHeadlessItem(config: ItemConfig(
            name: "stale-click",
            run: "printf unused",
            interval: .manual,
            click: "touch '\(markerA.path)'"
        ))
        item.clickInvocationTestGate = { await gate.wait() }
        addTeardownBlock { @MainActor in
            item.clickInvocationTestGate = nil
            await item.tearDown()
            try? FileManager.default.removeItem(at: markerA)
            try? FileManager.default.removeItem(at: markerB)
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForGateArmed(gate)

        await item.prepareUpdate(config: ItemConfig(
            name: "stale-click",
            run: "printf unused",
            interval: .manual,
            click: "touch '\(markerB.path)'"
        ))
        item.commitPreparedUpdate()

        gate.release()
        try await waitForPendingClickInvocationsToDrain(item)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerA.path),
            "queued click ran the command from the superseded configuration"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerB.path),
            "queued click ran the replacement command instead of being dropped once superseded"
        )

        item.processClick(eventType: .leftMouseUp)
        try await waitForFile(markerB)
    }

    // MARK: - Removing click before the queued invocation starts prevents any click command from executing.

    @MainActor
    func testQueuedClickDoesNotRunAfterReloadRemovesClickEntirely() async throws {
        let markerA = tempMarker("removed-a")
        let gate = InvocationGate()
        let item = makeHeadlessItem(config: ItemConfig(
            name: "removed-click",
            run: "printf unused",
            interval: .manual,
            click: "touch '\(markerA.path)'"
        ))
        item.clickInvocationTestGate = { await gate.wait() }
        addTeardownBlock { @MainActor in
            item.clickInvocationTestGate = nil
            await item.tearDown()
            try? FileManager.default.removeItem(at: markerA)
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForGateArmed(gate)

        await item.prepareUpdate(config: ItemConfig(
            name: "removed-click",
            run: "printf unused",
            interval: .manual,
            click: nil
        ))
        item.commitPreparedUpdate()

        gate.release()
        try await waitForPendingClickInvocationsToDrain(item)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerA.path),
            "queued click ran after its command was removed from the configuration"
        )
    }

    // MARK: - Changing only click execution context (environment) invalidates the old queued invocation.

    @MainActor
    func testQueuedClickIsInvalidatedByExecutionContextChangeEvenWithIdenticalCommandText() async throws {
        let markerA = tempMarker("context-a")
        let markerB = tempMarker("context-b")
        let gate = InvocationGate()
        let clickScript = "touch \"$MARKER_PATH\""
        let item = makeHeadlessItem(config: ItemConfig(
            name: "context-click",
            run: "printf unused",
            interval: .manual,
            environment: ["MARKER_PATH": markerA.path],
            click: clickScript
        ))
        item.clickInvocationTestGate = { await gate.wait() }
        addTeardownBlock { @MainActor in
            item.clickInvocationTestGate = nil
            await item.tearDown()
            try? FileManager.default.removeItem(at: markerA)
            try? FileManager.default.removeItem(at: markerB)
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForGateArmed(gate)

        await item.prepareUpdate(config: ItemConfig(
            name: "context-click",
            run: "printf unused",
            interval: .manual,
            environment: ["MARKER_PATH": markerB.path],
            click: clickScript
        ))
        item.commitPreparedUpdate()

        gate.release()
        try await waitForPendingClickInvocationsToDrain(item)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerA.path),
            "queued click ran with the environment captured before the reload"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerB.path),
            "queued click ran with the replacement environment instead of being dropped"
        )

        item.processClick(eventType: .leftMouseUp)
        try await waitForFile(markerB)
    }

    // MARK: - A presentation-only change does not discard an accepted click.

    @MainActor
    func testQueuedClickStillRunsAfterPresentationOnlyReload() async throws {
        let markerA = tempMarker("presentation")
        let gate = InvocationGate()
        let item = makeHeadlessItem(config: ItemConfig(
            name: "presentation-click",
            run: "printf unused",
            interval: .manual,
            format: "old-{output}",
            click: "touch '\(markerA.path)'"
        ))
        item.clickInvocationTestGate = { await gate.wait() }
        addTeardownBlock { @MainActor in
            item.clickInvocationTestGate = nil
            await item.tearDown()
            try? FileManager.default.removeItem(at: markerA)
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForGateArmed(gate)

        await item.prepareUpdate(config: ItemConfig(
            name: "presentation-click",
            run: "printf unused",
            interval: .manual,
            format: "new-{output}",
            click: "touch '\(markerA.path)'"
        ))
        item.commitPreparedUpdate()

        gate.release()
        try await waitForFile(markerA)
    }

    // MARK: - A click queued during isPreparingUpdate/isPreparingRemoval is rejected outright.

    @MainActor
    func testClickIsRejectedWhileAnUpdateIsBeingPrepared() async throws {
        let markerA = tempMarker("during-update")
        let item = makeHeadlessItem(config: ItemConfig(
            name: "during-update",
            run: "printf unused",
            interval: .manual,
            click: "touch '\(markerA.path)'"
        ))
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: markerA)
        }

        await item.prepareUpdate(config: ItemConfig(
            name: "during-update",
            run: "printf unused",
            interval: .manual,
            click: "touch '\(markerA.path)'"
        ))

        item.processClick(eventType: .leftMouseUp)
        XCTAssertEqual(item.pendingClickInvocationCountForTesting, 0, "click was queued while an update was being prepared")

        item.commitPreparedUpdate()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerA.path), "rejected click still ran its command")
    }

    @MainActor
    func testClickIsRejectedWhileRemovalIsBeingPrepared() async throws {
        let markerA = tempMarker("during-removal")
        let item = makeHeadlessItem(config: ItemConfig(
            name: "during-removal",
            run: "printf unused",
            interval: .manual,
            click: "touch '\(markerA.path)'"
        ))
        defer { try? FileManager.default.removeItem(at: markerA) }

        await item.prepareRemoval()

        item.processClick(eventType: .leftMouseUp)
        XCTAssertEqual(item.pendingClickInvocationCountForTesting, 0, "click was queued while removal was being prepared")

        await item.tearDown()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerA.path), "rejected click still ran its command")
    }

    // MARK: - An already-running old click command is cancelled, descendants included, before an update commits.

    @MainActor
    func testConfigReloadCancelsAlreadyRunningClickAndItsDescendantBeforeCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-47-running-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clickPIDURL = root.appendingPathComponent("click.pid")
        let clickCommand = "(trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(clickPIDURL.path)'; wait \"$child\""
        let item = makeHeadlessItem(config: ItemConfig(
            name: "running-click-reload",
            run: "printf unused",
            interval: .manual,
            click: clickCommand
        ))
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: root)
        }

        item.processClick(eventType: .leftMouseUp)
        let clickPID = try await waitForPID(at: clickPIDURL)
        try await waitForClickRunning(item)

        await item.prepareUpdate(config: ItemConfig(
            name: "running-click-reload",
            run: "printf unused",
            interval: .manual,
            click: "printf replaced"
        ))
        let descendantGone = await waitUntilGone(clickPID)
        XCTAssertTrue(descendantGone, "config reload left the running click's descendant \(clickPID) alive")
        item.commitPreparedUpdate()

        let snapshot = await item.clickSnapshot()
        XCTAssertEqual(snapshot?.isRunning, false)
    }

    // MARK: - Repeated clicks still share one runner gate and record skipped invocations rather than overlapping.

    @MainActor
    func testRepeatedClicksShareOneRunnerGateAndRecordSkips() async throws {
        let marker = tempMarker("repeated-click")
        let item = makeHeadlessItem(config: ItemConfig(
            name: "repeated-click",
            run: "printf unused",
            interval: .manual,
            click: "sleep 0.3; touch '\(marker.path)'"
        ))
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForClickRunning(item)
        item.processClick(eventType: .leftMouseUp)

        try await waitForPendingClickInvocationsToDrain(item)
        let snapshot = await item.clickSnapshot()
        XCTAssertEqual(snapshot?.skippedRefreshes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - Test helpers

    @MainActor
    private func waitForGateArmed(_ gate: InvocationGate) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if gate.armed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(
            domain: "StaleClickInvocationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "queued click invocation never reached the test gate"]
        )
    }

    @MainActor
    private func waitForPendingClickInvocationsToDrain(_ item: ManagedItem) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if item.pendingClickInvocationCountForTesting == 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(
            domain: "StaleClickInvocationTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "click invocation bookkeeping never drained"]
        )
    }

    @MainActor
    private func waitForClickRunning(_ item: ManagedItem) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await item.clickSnapshot()?.isRunning == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "StaleClickInvocationTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "click did not become active"]
        )
    }

    @MainActor
    private func waitForFile(_ file: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "StaleClickInvocationTests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "expected click command did not run: \(file.path)"]
        )
    }

    @MainActor
    private func waitForPID(at url: URL) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let value = try? String(contentsOf: url),
                let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "StaleClickInvocationTests",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(url.path)"]
        )
    }

    @MainActor
    private func waitUntilGone(_ pid: Int32) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}
