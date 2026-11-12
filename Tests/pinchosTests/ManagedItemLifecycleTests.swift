import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

@MainActor
private final class NoopMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

/// A gate that holds every caller of `wait()` until `open()` is called, and
/// counts how many callers arrived.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// Drives a real headless `ManagedItem` through its lifecycle transitions:
/// live, preparing an update, holding a prepared update, preparing removal,
/// and retired. Commands touch marker files so each assertion is about what
/// actually ran, not about internal state.
final class ManagedItemLifecycleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-item-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func marker(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func config(
        run: String,
        menu: [MenuRowConfig] = []
    ) -> ItemConfig {
        ItemConfig(name: "item", run: run, interval: .manual, menu: menu)
    }

    /// A refresh command that records it ran by creating `markerName`.
    private func touching(_ markerName: String, output: String) -> String {
        "touch '\(marker(markerName).path)'; printf \(output)"
    }

    @MainActor
    private func makeItem(config: ItemConfig) -> ManagedItem {
        let item = ManagedItem(
            config: config,
            menuDelegate: NoopMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            sourceRegistry: CommandSourceRegistry(),
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }
        return item
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// Gives any work that was wrongly accepted time to start a process.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Update

    @MainActor
    func testRefreshDuringPreparedUpdateIsDroppedAndRefreshAfterCommitRunsNewConfig() async throws {
        let item = makeItem(config: config(run: touching("old", output: "old")))

        await item.prepareUpdate(config: config(run: touching("new", output: "new")))
        item.refreshNow()
        await settle()
        XCTAssertFalse(exists(marker("old")), "a refresh during a prepared update ran the outgoing command")
        XCTAssertFalse(exists(marker("new")), "a refresh during a prepared update ran before commit")

        item.commitPreparedUpdate()
        item.refreshNow()
        let refreshed = await waitUntil { await item.runtimeSnapshot().fullOutput == "new" }
        XCTAssertTrue(refreshed, "a refresh after commit did not run the new command")
        XCTAssertFalse(exists(marker("old")))
    }

    @MainActor
    func testHeldActionReleasedWhileUpdateIsPreparedDoesNotRunReplacedRunner() async throws {
        try await assertHeldActionDoesNotRunReplacedRunner(releaseAfterCommit: false)
    }

    @MainActor
    func testHeldActionReleasedAfterCommitDoesNotRunReplacedRunner() async throws {
        try await assertHeldActionDoesNotRunReplacedRunner(releaseAfterCommit: true)
    }

    @MainActor
    private func assertHeldActionDoesNotRunReplacedRunner(releaseAfterCommit: Bool) async throws {
        let oldAction = marker("old-action")
        let newAction = marker("new-action")
        let item = makeItem(config: config(
            run: "printf value",
            menu: [MenuRowConfig(label: "Act", action: "touch '\(oldAction.path)'")]
        ))
        let gate = Latch()
        item.actionInvocationTestGate = { await gate.wait() }

        item.invokeMenuRow(at: 0)
        let held = await waitUntil { await gate.arrivals == 1 }
        XCTAssertTrue(held, "the action never reached the test gate")

        await item.prepareUpdate(config: config(
            run: "printf value",
            menu: [MenuRowConfig(label: "Act", action: "touch '\(newAction.path)'")]
        ))
        if releaseAfterCommit {
            item.commitPreparedUpdate()
        }
        await gate.open()
        let drained = await waitUntil { item.pendingActionInvocationCountForTesting == 0 }
        XCTAssertTrue(drained, "the held action never finished")
        if !releaseAfterCommit {
            item.commitPreparedUpdate()
        }
        await settle()
        XCTAssertFalse(exists(oldAction), "the held action ran the replaced runner")
        XCTAssertFalse(exists(newAction), "the held action ran a runner it was never accepted for")

        item.actionInvocationTestGate = nil
        item.invokeMenuRow(at: 0)
        let ranNew = await waitUntil { self.exists(newAction) }
        XCTAssertTrue(ranNew, "an action invoked after commit did not run the new runner")
        XCTAssertFalse(exists(oldAction))
    }

    @MainActor
    func testSecondPrepareUpdateWhileFirstIsSettlingIsRejected() async throws {
        let item = makeItem(config: config(run: "printf original"))
        let settlement = Latch()
        item.cancellationSettlementDelayForTesting = { role in
            if role == "primary" {
                await settlement.wait()
            }
        }

        let first = Task { @MainActor in
            await item.prepareUpdate(config: self.config(run: "printf first"))
        }
        let firstSettling = await waitUntil { await settlement.arrivals == 1 }
        XCTAssertTrue(firstSettling, "the first update never reached settlement")

        var secondReturned = false
        let second = Task { @MainActor in
            await item.prepareUpdate(config: self.config(run: "printf second"))
            secondReturned = true
        }
        let rejectedPromptly = await waitUntil(timeout: 1) { secondReturned }
        XCTAssertTrue(rejectedPromptly, "a second prepareUpdate waited on the first instead of being rejected")

        await settlement.open()
        await first.value
        await second.value
        item.cancellationSettlementDelayForTesting = nil
        let settlementArrivals = await settlement.arrivals
        XCTAssertEqual(settlementArrivals, 1, "the rejected update still cancelled runners")

        item.commitPreparedUpdate()
        XCTAssertEqual(item.commandConfig.run, "printf first")
        item.refreshNow()
        let refreshed = await waitUntil { await item.runtimeSnapshot().fullOutput == "first" }
        XCTAssertTrue(refreshed, "the committed update was not the first one")
    }

    @MainActor
    func testCommitPreparedUpdateAfterRemovalBeganDoesNothing() async throws {
        let item = makeItem(config: config(run: touching("old", output: "old")))

        await item.prepareUpdate(config: config(run: touching("new", output: "new")))
        await item.prepareRemoval()
        item.commitPreparedUpdate()

        XCTAssertEqual(item.commandConfig.run, touching("old", output: "old"))
        item.refreshNow()
        await settle()
        XCTAssertFalse(exists(marker("old")))
        XCTAssertFalse(exists(marker("new")))

        item.commitRemoval()
        try await assertRetired(item)
    }

    // MARK: - Removal

    @MainActor
    func testRemovalFromLiveRetiresItem() async throws {
        let item = makeRetirementCandidate()

        await item.prepareRemoval()
        item.commitRemoval()

        try await assertRetired(item)
    }

    @MainActor
    func testRemovalWhileUpdateIsSettlingRetiresItem() async throws {
        let item = makeRetirementCandidate()
        let settlement = Latch()
        item.cancellationSettlementDelayForTesting = { role in
            if role == "primary" {
                await settlement.wait()
            }
        }

        let update = Task { @MainActor in
            await item.prepareUpdate(config: self.config(run: self.touching("updated", output: "updated")))
        }
        let updateSettling = await waitUntil { await settlement.arrivals == 1 }
        XCTAssertTrue(updateSettling, "the update never reached settlement")
        let removal = Task { @MainActor in await item.prepareRemoval() }
        await settlement.open()
        await update.value
        await removal.value
        item.cancellationSettlementDelayForTesting = nil

        item.commitPreparedUpdate()
        XCTAssertEqual(item.commandConfig.run, touching("refresh", output: "value"))
        item.commitRemoval()

        try await assertRetired(item)
        XCTAssertFalse(exists(marker("updated")))
    }

    @MainActor
    func testRemovalFromPreparedUpdateRetiresItem() async throws {
        let item = makeRetirementCandidate()

        await item.prepareUpdate(config: config(run: touching("updated", output: "updated")))
        await item.prepareRemoval()
        item.commitRemoval()

        try await assertRetired(item)
        XCTAssertFalse(exists(marker("updated")))
    }

    @MainActor
    func testEveryCallOnARetiredItemIsANoOp() async throws {
        let item = makeRetirementCandidate()

        await item.tearDown()
        await item.tearDown()
        await item.prepareRemoval()
        item.commitRemoval()

        try await assertRetired(item)
    }

    @MainActor
    private func makeRetirementCandidate() -> ManagedItem {
        makeItem(config: config(
            run: touching("refresh", output: "value"),
            menu: [MenuRowConfig(label: "Act", action: "touch '\(marker("action").path)'")]
        ))
    }

    /// A retired item starts no work and ignores every further lifecycle call.
    @MainActor
    private func assertRetired(
        _ item: ManagedItem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let configBefore = item.commandConfig

        item.activate()
        item.refreshNow()
        item.invokeMenuRow(at: 0)
        await item.prepareUpdate(config: config(run: touching("retired-update", output: "x")))
        item.commitPreparedUpdate()
        item.refreshNow()
        await settle()

        XCTAssertEqual(item.commandConfig, configBefore, "a retired item accepted an update", file: file, line: line)
        XCTAssertEqual(item.pendingActionInvocationCountForTesting, 0, file: file, line: line)
        for name in ["old", "new", "refresh", "action", "retired-update"] {
            XCTAssertFalse(exists(marker(name)), "a retired item ran work that touched \(name)", file: file, line: line)
        }
        let snapshot = await item.runnerSnapshot()
        XCTAssertFalse(snapshot.isRunning, file: file, line: line)
        XCTAssertNil(snapshot.lastExecution, "a retired item ran its command", file: file, line: line)
    }
}
