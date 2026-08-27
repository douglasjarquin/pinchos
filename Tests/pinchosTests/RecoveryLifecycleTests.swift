import AppKit
import Darwin
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
    /// A fresh `CommandScheduler` per test (rather than `.shared`) so
    /// diagnostics assertions like "no timer got registered" can't be
    /// polluted by another test's items.
    @MainActor
    private func makeHeadlessItem(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate? = nil,
        initiallyVisible: Bool = true,
        now: @escaping () -> Date = Date.init,
        scheduler: CommandScheduler = CommandScheduler(),
        notificationSink: ItemNotificationSink? = nil
    ) -> ManagedItem {
        ManagedItem(
            config: config,
            menuDelegate: menuDelegate ?? NoopStatusItemMenuDelegate(),
            initiallyVisible: initiallyVisible,
            scheduler: scheduler,
            now: now,
            notificationSink: notificationSink,
            statusItemFactory: { nil }
        )
    }

    @MainActor
    func testManualItemRunsOnceOnActivationWithoutPeriodicTimer() async throws {
        let item = makeHeadlessItem(
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
    func testManualActivationDoesNotCreatePeriodicTimer() async throws {
        let scheduler = CommandScheduler()
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "manual",
                run: "printf manual",
                interval: .manual
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false,
            scheduler: scheduler
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.activate()
        _ = try await waitForExecution(item)
        try await Task.sleep(for: .milliseconds(200))

        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.registeredTimers, 0)
    }

    @MainActor
    func testManualRefreshKeepsLastGoodValueWhileAnotherRefreshRuns() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-manual-refresh-\(UUID().uuidString)")
        let item = makeHeadlessItem(
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
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "old\n" && item.renderedTitle == "old"
        }

        item.refreshNow()
        try await waitForRunning(item)
        item.refreshNow()
        _ = try await waitForSkippedRefresh(item)

        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.isRunning && snapshot.fullOutput == "old\n" && item.renderedTitle == "old"
        }
        try await waitForIdle(item)
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "new\n" && item.renderedTitle == "new"
        }
        XCTAssertEqual(item.renderedTitle, "new")
    }

    @MainActor
    func testSuccessFailureRecoveryTracksIndependentAttemptAndSuccessState() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-11-recovery-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "recovery",
                run: "count=$(cat '\(marker.path)' 2>/dev/null || echo 0); count=$((count + 1)); printf '%s' \"$count\" > '\(marker.path)'; if [ \"$count\" -eq 1 ]; then printf 'good\\n'; elif [ \"$count\" -eq 2 ]; then printf 'transient diagnostic\\n' >&2; exit 7; else printf 'recovered\\n'; fi",
                interval: .manual,
                onError: .keepLast,
                tooltip: "{status}|{output}|{error}"
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.refreshNow()
        let success = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.lastUpdatedAt != nil
        }
        let firstAttempt = try XCTUnwrap(success.lastAttemptedAt)
        let firstUpdate = try XCTUnwrap(success.lastUpdatedAt)
        XCTAssertEqual(success.status, .fresh)
        XCTAssertEqual(success.fullOutput, "good\n")
        XCTAssertEqual(success.lastExecution?.exitCode, 0)

        item.refreshNow()
        let failure = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .error && snapshot.lastAttemptedAt != firstAttempt
        }
        XCTAssertGreaterThan(try XCTUnwrap(failure.lastAttemptedAt), firstAttempt)
        XCTAssertEqual(failure.lastUpdatedAt, firstUpdate)
        XCTAssertEqual(failure.fullOutput, "good\n")
        XCTAssertEqual(failure.lastExecution?.exitCode, 7)
        XCTAssertEqual(failure.errorSummary, "transient diagnostic")
        XCTAssertEqual(item.renderedToolTip, "error|good\n|transient diagnostic")

        item.refreshNow()
        let recovery = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh && snapshot.fullOutput == "recovered\n"
        }
        XCTAssertGreaterThan(try XCTUnwrap(recovery.lastAttemptedAt), try XCTUnwrap(failure.lastAttemptedAt))
        XCTAssertGreaterThan(try XCTUnwrap(recovery.lastUpdatedAt), firstUpdate)
        XCTAssertEqual(recovery.fullOutput, "recovered\n")
        XCTAssertEqual(recovery.lastExecution?.exitCode, 0)
        XCTAssertEqual(item.renderedToolTip, "fresh|recovered\n|")
    }

    @MainActor
    func testFirstRunFailureHasAttemptAndErrorButNoLastGoodValue() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "first-failure",
                run: "printf 'first failure\\n' >&2; exit 9",
                interval: .manual,
                onError: .keepLast,
                tooltip: "{status}|{output}|{updated_at}|{attempted_at}|{error}"
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        let state = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .error
        }

        XCTAssertNil(state.fullOutput)
        XCTAssertNil(state.lastUpdatedAt)
        XCTAssertNotNil(state.lastAttemptedAt)
        XCTAssertEqual(state.lastExecution?.exitCode, 9)
        XCTAssertEqual(state.errorSummary, "first failure")
        XCTAssertEqual(item.renderedToolTip?.components(separatedBy: "|").prefix(3).joined(separator: "|"), "error||")
    }

    @MainActor
    func testStaleAfterUsesInjectedClockAndTurnsStaleAtThreshold() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "stale",
                run: "printf 'fresh\\n'",
                interval: .manual,
                staleAfter: 60
            ),
            initiallyVisible: false,
            now: { now }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        let fresh = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh
        }
        XCTAssertFalse(fresh.isStale)

        now = now.addingTimeInterval(60)
        let stale = await item.runtimeSnapshot()
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertTrue(item.renderedTitle.hasSuffix("⌛︎"))
    }

    @MainActor
    func testExtremeStaleAfterDoesNotTrapDuringPresentationScheduling() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "extreme-stale",
                run: "printf 'value'",
                interval: .manual,
                staleAfter: TimeInterval(Int.max) * 3_600
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        let snapshot = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh && snapshot.fullOutput == "value"
        }

        XCTAssertFalse(snapshot.isStale)
        XCTAssertEqual(item.renderedTitle, "value")
    }

    @MainActor
    func testRunningRefreshPreservesConfiguredTooltipAndRecordsAttemptStart() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "running",
                run: "sleep 0.4; printf running",
                interval: .manual,
                tooltip: "Value={output}; Status={status}; Attempted={attempted_at}"
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        try await waitForRunning(item)
        let tooltipBeforeRuntimeObservation = item.renderedToolTip
        let running = await item.runtimeSnapshot()

        XCTAssertEqual(running.status, .running)
        XCTAssertNotNil(running.lastAttemptedAt)
        XCTAssertTrue(tooltipBeforeRuntimeObservation?.contains("Status=running") == true)
        XCTAssertNotEqual(tooltipBeforeRuntimeObservation, "Refreshing...")

        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh && snapshot.fullOutput == "running"
        }
    }

    @MainActor
    func testLateStdoutFromLingeringDescendantUpdatesFinalOutputAndTimestamp() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "late-output",
                run: "(sleep 0.3; printf 'late\\n') & exit 0",
                interval: .manual
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        try await waitForRunning(item)

        // The shell already exited, but a same-group descendant is still
        // writing output. The item must not have committed anything from the
        // preliminary shell exit while that descendant lingers.
        let whileLingering = await item.runtimeSnapshot()
        XCTAssertTrue(whileLingering.isRunning)
        XCTAssertNil(whileLingering.fullOutput)
        XCTAssertNil(whileLingering.lastUpdatedAt)

        let settled = try await waitForRuntimeSnapshot(item) { snapshot in
            !snapshot.isRunning && snapshot.fullOutput != nil
        }
        XCTAssertEqual(settled.fullOutput, "late\n")
        XCTAssertNotNil(settled.lastUpdatedAt)
        XCTAssertEqual(settled.status, .fresh)
        XCTAssertEqual(item.renderedTitle, "late")
    }

    @MainActor
    func testConfigReloadTerminatesLingeringDescendantBeforeReplacingRunner() async throws {
        let childPIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-reload-child-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "reload",
                run: "(trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; exit 0",
                interval: .manual
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: childPIDURL)
        }

        item.refreshNow()
        let childPID = try await waitForPID(at: childPIDURL)
        try await waitForRunning(item)

        await item.prepareUpdate(config: ItemConfig(
            name: "reload",
            run: "printf reloaded",
            interval: .manual
        ))
        let reloadChildGone = await waitUntilGone(childPID)
        XCTAssertTrue(reloadChildGone, "config reload left child process \(childPID) alive")
        item.commitPreparedUpdate()

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh && snapshot.fullOutput == "reloaded"
        }
    }

    @MainActor
    func testItemShutdownTerminatesLingeringDescendant() async throws {
        let childPIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-shutdown-child-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "shutdown",
                run: "(trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; exit 0",
                interval: .manual
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: childPIDURL)
        }

        item.refreshNow()
        let childPID = try await waitForPID(at: childPIDURL)
        try await waitForRunning(item)

        await item.tearDown()

        let shutdownChildGone = await waitUntilGone(childPID)
        XCTAssertTrue(shutdownChildGone, "item shutdown left child process \(childPID) alive")
        let snapshot = await item.runnerSnapshot()
        XCTAssertFalse(snapshot.isRunning)
    }

    @MainActor
    func testItemShutdownCancelsMainClickAndDeclarativeActionRunners() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-shutdown-runners-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mainPIDURL = root.appendingPathComponent("main.pid")
        let clickPIDURL = root.appendingPathComponent("click.pid")
        let actionPIDURL = root.appendingPathComponent("action.pid")
        let command: (URL) -> String = { marker in
            "(trap '' TERM INT; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(marker.path)'; wait \"$child\""
        }
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "shutdown-runners",
                run: command(mainPIDURL),
                interval: .manual,
                click: command(clickPIDURL),
                actions: [ItemAction(title: "Run action", kind: .command(command(actionPIDURL)))]
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: root)
        }

        item.refreshNow()
        item.processClick(eventType: .leftMouseUp)
        item.invokeAction(at: 0)

        let mainPID = try await waitForPID(at: mainPIDURL)
        let clickPID = try await waitForPID(at: clickPIDURL)
        let actionPID = try await waitForPID(at: actionPIDURL)
        try await waitForRunning(item)
        try await waitForActionRunning(item, at: 0)

        await item.tearDown()

        let mainGone = await waitUntilGone(mainPID)
        let clickGone = await waitUntilGone(clickPID)
        let actionGone = await waitUntilGone(actionPID)
        let runnerSnapshot = await item.runnerSnapshot()
        let actionSnapshot = await item.actionSnapshot(at: 0)
        XCTAssertTrue(mainGone, "item shutdown left main descendant \(mainPID) alive")
        XCTAssertTrue(clickGone, "item shutdown left click descendant \(clickPID) alive")
        XCTAssertTrue(actionGone, "item shutdown left action descendant \(actionPID) alive")
        XCTAssertFalse(runnerSnapshot.isRunning)
        XCTAssertFalse(actionSnapshot?.isRunning ?? true)
    }

    /// Issue #54: a single item's primary, click, and action runner
    /// cancellation must be initiated concurrently rather than one after
    /// another. Real runner cancellation is normally too fast (SIGKILL
    /// settles almost immediately) to distinguish concurrent from serial
    /// execution, so this test uses the item's test-only settlement-delay
    /// seam to give each of the three roles a controllable, equal settle
    /// time and asserts the whole teardown completes near that one settle
    /// time, not the sum of all three.
    @MainActor
    func testItemShutdownCancelsPrimaryClickAndActionRunnersConcurrentlyNotSequentially() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "concurrent-cancel",
                run: "printf primary",
                interval: .manual,
                click: "printf clicked",
                actions: [ItemAction(title: "Run action", kind: .command("printf action"))]
            ),
            initiallyVisible: false
        )
        let perRoleSettle: Duration = .milliseconds(150)
        item.cancellationSettlementDelayForTesting = { _ in
            try? await Task.sleep(for: perRoleSettle)
        }

        let clock = ContinuousClock()
        let started = clock.now
        await item.tearDown()
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(
            elapsed, perRoleSettle * 2,
            "primary/click/action settling at 150ms each must overlap, not sum to ~450ms"
        )
    }

    /// A per-item lifecycle operation must still respect the shared
    /// operation-level deadline: if settlement cannot complete in time, the
    /// call returns near the deadline (not near the slower settle time) and
    /// reports the outstanding runner identities rather than hanging.
    @MainActor
    func testPrepareRemovalReturnsNearTheDeadlineWhenARunnerCannotSettleInTime() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "deadline-bound",
                run: "printf primary",
                interval: .manual,
                click: "printf clicked"
            ),
            initiallyVisible: false
        )
        item.cancellationSettlementDelayForTesting = { role in
            if role == "click" {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        var reportedTimeouts: [LifecycleSettlementTimeout] = []
        item.lifecycleSettlementTimeoutHandlerForTesting = { timeouts in
            reportedTimeouts = timeouts
        }

        let clock = ContinuousClock()
        let started = clock.now
        await item.prepareRemoval(deadline: clock.now.advanced(by: .milliseconds(150)))
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(2), "prepareRemoval must not block past its shared deadline")
        XCTAssertEqual(reportedTimeouts.map(\.identity), ["deadline-bound:click"])

        item.cancellationSettlementDelayForTesting = nil
        item.commitRemoval()
    }

    @MainActor
    func testQueuedClickDoesNotStartAfterRemovalBegins() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-queued-click-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "queued-click",
                run: "printf unused",
                interval: .manual,
                click: "printf '%s' \"$$\" > '\(marker.path)'"
            ),
            initiallyVisible: false
        )

        item.processClick(eventType: .leftMouseUp)
        await item.tearDown()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testQueuedClickDoesNotRunObsoleteCommandAfterClickReload() async throws {
        let obsoleteMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-obsolete-click-\(UUID().uuidString)")
        let replacementMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-replacement-click-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: obsoleteMarker)
            try? FileManager.default.removeItem(at: replacementMarker)
        }

        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "stale-click",
                run: "printf unused",
                interval: .manual,
                click: "printf obsolete > '\(obsoleteMarker.path)'"
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        let gateEntered = expectation(description: "queued click reached test gate")
        var releaseContinuation: CheckedContinuation<Void, Never>?
        item.clickInvocationTestGate = {
            gateEntered.fulfill()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuation = continuation
            }
        }

        item.processClick(eventType: .leftMouseUp)
        await fulfillment(of: [gateEntered], timeout: 2)

        await item.prepareUpdate(
            config: ItemConfig(
                name: "stale-click",
                run: "printf unused",
                interval: .manual,
                click: "printf replacement > '\(replacementMarker.path)'"
            )
        )
        item.commitPreparedUpdate()

        releaseContinuation?.resume()
        releaseContinuation = nil
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: obsoleteMarker.path),
            "queued click must not execute the pre-reload click command"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: replacementMarker.path),
            "queued obsolete click must not start the replacement command either"
        )
    }

    @MainActor
    func testStaleScheduleAfterConfigReloadUsesLastSuccessfulUpdate() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "stale-reload",
                run: "printf value",
                interval: .manual,
                staleAfter: 5
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh && snapshot.fullOutput == "value"
        }
        try await Task.sleep(for: .milliseconds(1_200))

        await item.prepareUpdate(config: ItemConfig(
            name: "stale-reload",
            run: "printf value",
            interval: .manual,
            staleAfter: 2
        ))
        item.commitPreparedUpdate()

        let freshAfterReload = await item.runtimeSnapshot()
        XCTAssertEqual(freshAfterReload.status, .fresh)
        try await Task.sleep(for: .milliseconds(1_100))

        let stale = await item.runtimeSnapshot()
        XCTAssertEqual(stale.status, .stale)
        XCTAssertTrue(stale.isStale)
        XCTAssertTrue(item.renderedTitle.hasSuffix("⌛︎"))
    }

    @MainActor
    func testScheduledRefreshAndManualRefreshShareTheExecutionGate() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "scheduled",
                run: "sleep 0.3; printf scheduled",
                interval: .scheduled(1)
            ),
            menuDelegate: NoopStatusItemMenuDelegate()
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        try await waitForRunning(item)
        item.refreshNow()
        let snapshot = try await waitForSkippedRefresh(item)

        XCTAssertEqual(snapshot.skippedRefreshes, 1)
        try await waitForIdle(item)
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "scheduled" && item.renderedTitle == "scheduled"
        }
        XCTAssertEqual(item.renderedTitle, "scheduled")
    }

    @MainActor
    func testManualItemDoesNotRefreshAfterRunnerConfigurationUpdate() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "manual",
                run: "printf old",
                interval: .manual
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.activate()
        _ = try await waitForExecution(item)
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "old" && item.renderedTitle == "old"
        }

        await item.prepareUpdate(config: ItemConfig(
            name: "manual",
            run: "printf updated",
            interval: .manual
        ))
        item.commitPreparedUpdate()

        _ = try await waitForRuntimeSnapshot(item) { _ in
            item.renderedTitle == "old"
        }
    }

    @MainActor
    func testFormatUpdateRecomputesExistingSuccessfulTitle() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "format",
                run: "printf value",
                interval: .manual,
                format: "old-{output}"
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value" && item.renderedTitle == "old-value"
        }

        await item.prepareUpdate(config: ItemConfig(
            name: "format",
            run: "printf value",
            interval: .manual,
            format: "new-{output}"
        ))
        item.commitPreparedUpdate()

        _ = try await waitForRuntimeSnapshot(item) { _ in
            item.renderedTitle == "new-value"
        }
        XCTAssertEqual(item.renderedTitle, "new-value")
    }

    @MainActor
    func testRefreshOnClickTriggersRefreshWhenNoClickActionIsConfigured() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-refresh-click-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click",
                run: "if [ ! -e '\(marker.path)' ]; then printf old; touch '\(marker.path)'; else sleep 0.2; printf clicked; fi",
                interval: .manual,
                refreshOnClick: true
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
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "old" && item.renderedTitle == "old"
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForRunning(item)
        try await waitForIdle(item)
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "clicked" && item.renderedTitle == "clicked"
        }
        XCTAssertEqual(item.renderedTitle, "clicked")
    }

    @MainActor
    func testConfiguredClickActionTakesPrecedenceOverRefreshOnClick() async throws {
        let runMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-run-click-\(UUID().uuidString)")
        let clickMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-action-click-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click",
                run: "if [ ! -e '\(runMarker.path)' ]; then printf old; touch '\(runMarker.path)'; else printf refreshed; fi",
                interval: .manual,
                click: "touch '\(clickMarker.path)'",
                refreshOnClick: true
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: runMarker)
            try? FileManager.default.removeItem(at: clickMarker)
        }

        item.refreshNow()
        _ = try await waitForExecution(item)
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "old" && item.renderedTitle == "old"
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForFile(clickMarker)
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "old" && item.renderedTitle == "old"
        }
    }

    @MainActor
    func testItemWithNoClickCommandExposesNoClickDiagnostics() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(name: "no-click", run: "printf value", interval: .manual),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        let snapshot = await item.clickSnapshot()
        XCTAssertNil(snapshot)
    }

    @MainActor
    func testClickDiagnosticsRecordSuccessWithoutAlteringPrimaryState() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click-success",
                run: "printf primary",
                interval: .manual,
                click: "printf 'clicked\\n'"
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "primary" && item.renderedTitle == "primary"
        }

        item.processClick(eventType: .leftMouseUp)
        let clickSnapshot = try await waitForClickExecution(item)

        XCTAssertFalse(clickSnapshot.runner.isRunning)
        XCTAssertEqual(clickSnapshot.runner.lastExecution?.terminalReason, .exited(code: 0))
        XCTAssertEqual(clickSnapshot.runner.lastExecution?.stdout, "clicked\n")
        XCTAssertNotNil(clickSnapshot.lastAttemptedAt)
        XCTAssertNotNil(clickSnapshot.lastCompletedAt)

        let primary = await item.runtimeSnapshot()
        XCTAssertEqual(primary.fullOutput, "primary")
        XCTAssertEqual(item.renderedTitle, "primary")
    }

    @MainActor
    func testClickDiagnosticsRecordFailureWithoutAlteringPrimaryState() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click-failure",
                run: "printf primary",
                interval: .manual,
                click: "printf 'boom' 1>&2; exit 3"
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "primary" && item.renderedTitle == "primary"
        }

        item.processClick(eventType: .leftMouseUp)
        let clickSnapshot = try await waitForClickExecution(item)

        XCTAssertEqual(clickSnapshot.runner.lastExecution?.terminalReason, .exited(code: 3))
        XCTAssertEqual(clickSnapshot.runner.lastExecution?.stderr, "boom")

        let primary = await item.runtimeSnapshot()
        XCTAssertEqual(primary.status, .fresh)
        XCTAssertEqual(primary.fullOutput, "primary")
        XCTAssertEqual(item.renderedTitle, "primary")
        XCTAssertNil(primary.errorSummary)
    }

    /// Two clicks issued back-to-back (no intervening await) while a first
    /// click already holds the scheduler permit and is running both land
    /// while this item's one-outstanding-permit-request-per-work-kind
    /// bound is in effect: the second coalesces into the third's still-
    /// pending permit request (recorded on the scheduler, not the runner),
    /// so exactly one of the two extra clicks actually reaches the runner
    /// and increments its `skippedRefreshes`, not both.
    @MainActor
    func testRepeatedClicksWhileActiveIncrementSkippedInvocationCount() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-click-skip-\(UUID().uuidString)")
        let scheduler = CommandScheduler()
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click-skip",
                run: "printf primary",
                interval: .manual,
                click: "touch '\(marker.path)'; sleep 0.3"
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false,
            scheduler: scheduler
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.processClick(eventType: .leftMouseUp)
        try await waitForFile(marker)
        item.processClick(eventType: .leftMouseUp)
        item.processClick(eventType: .leftMouseUp)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let snapshot = await item.clickSnapshot(), snapshot.runner.skippedRefreshes > 0 {
                XCTAssertEqual(snapshot.runner.skippedRefreshes, 1)
                let diagnostics = await scheduler.diagnostics()
                XCTAssertGreaterThanOrEqual(diagnostics.coalescedCount, 1)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("repeated clicks did not increment the skipped invocation count")
    }

    @MainActor
    func testClickDiagnosticsAreRetainedAcrossPresentationOnlyReload() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click-retain",
                run: "printf primary",
                interval: .manual,
                click: "printf clicked"
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.processClick(eventType: .leftMouseUp)
        let before = try await waitForClickExecution(item)

        await item.prepareUpdate(config: ItemConfig(
            name: "click-retain",
            run: "printf primary",
            interval: .manual,
            format: "value: {output}",
            click: "printf clicked"
        ))
        item.commitPreparedUpdate()

        let after = await item.clickSnapshot()
        XCTAssertEqual(after?.runner.lastExecution, before.runner.lastExecution)
        XCTAssertEqual(after?.lastAttemptedAt, before.lastAttemptedAt)
        XCTAssertEqual(after?.lastCompletedAt, before.lastCompletedAt)
    }

    @MainActor
    func testClickDiagnosticsResetWhenClickCommandChanges() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click-reset",
                run: "printf primary",
                interval: .manual,
                click: "printf clicked"
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.processClick(eventType: .leftMouseUp)
        _ = try await waitForClickExecution(item)

        await item.prepareUpdate(config: ItemConfig(
            name: "click-reset",
            run: "printf primary",
            interval: .manual,
            click: "printf reconfigured"
        ))
        item.commitPreparedUpdate()

        let afterReset = await item.clickSnapshot()
        XCTAssertNotNil(afterReset)
        XCTAssertNil(afterReset?.runner.lastExecution)
        XCTAssertNil(afterReset?.lastAttemptedAt)
        XCTAssertNil(afterReset?.lastCompletedAt)
        XCTAssertEqual(afterReset?.runner.skippedRefreshes, 0)
    }

    @MainActor
    func testClickDiagnosticsAreRemovedWhenClickCommandIsRemoved() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "click-remove",
                run: "printf primary",
                interval: .manual,
                click: "printf clicked"
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.processClick(eventType: .leftMouseUp)
        _ = try await waitForClickExecution(item)

        await item.prepareUpdate(config: ItemConfig(
            name: "click-remove",
            run: "printf primary",
            interval: .manual
        ))
        item.commitPreparedUpdate()

        let afterRemoval = await item.clickSnapshot()
        XCTAssertNil(afterRemoval)
    }

    @MainActor
    func testBuiltInRefreshActionUsesItemRunnerAndSharesItsBusyGate() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "refresh-action",
                run: "sleep 0.25; printf refreshed",
                interval: .manual,
                actions: [ItemAction(title: "Refresh now", kind: .refresh)]
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.invokeAction(at: 0)
        try await waitForRunning(item)
        let actionSnapshot = await item.actionSnapshot(at: 0)
        XCTAssertNil(actionSnapshot)

        item.invokeAction(at: 0)
        let skipped = try await waitForSkippedRefresh(item)
        XCTAssertEqual(skipped.skippedRefreshes, 1)

        try await waitForIdle(item)
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "refreshed" && snapshot.status == .fresh
        }
    }

    @MainActor
    func testCommandActionInheritsEnvironmentAndSkipsRepeatedInvocation() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "command-action",
                run: "printf unused",
                interval: .manual,
                environment: ["PINCHOS_ACTION_VALUE": "configured"],
                actions: [
                    ItemAction(
                        title: "Run action",
                        kind: .command("printf '%s' \"$PINCHOS_ACTION_VALUE\"; sleep 0.25")
                    )
                ]
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.invokeAction(at: 0)
        try await waitForActionRunning(item, at: 0)
        item.invokeAction(at: 0)
        let skipped = try await waitForActionSkipped(item, at: 0)
        XCTAssertEqual(skipped.skippedRefreshes, 1)

        let completed = try await waitForActionExecution(item, at: 0)
        XCTAssertEqual(completed.lastExecution?.terminalReason, .exited(code: 0))
        XCTAssertEqual(completed.lastExecution?.stdout, "configured")
    }

    @MainActor
    func testCommandActionFailureRetainsDiagnosticsForMenuProjection() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "failed-action",
                run: "printf unused",
                interval: .manual,
                actions: [
                    ItemAction(
                        title: "Fail action",
                        kind: .command("printf 'action-error\\n' >&2; exit 7")
                    )
                ]
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.invokeAction(at: 0)
        let snapshot = try await waitForActionExecution(item, at: 0)

        XCTAssertEqual(snapshot.lastExecution?.terminalReason, .exited(code: 7))
        XCTAssertEqual(snapshot.lastExecution?.stderr, "action-error\n")
    }

    @MainActor
    func testFailedRefreshClearsRunningFeedback() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "manual",
                run: "exit 1",
                interval: .manual,
                errorText: "ERR"
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        let state = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .error
        }

        XCTAssertEqual(state.errorSummary, "1")
        XCTAssertEqual(item.renderedTitle, "ERR ⚠︎")
        XCTAssertTrue(item.renderedToolTip?.contains("Status: error") == true)
    }

    @MainActor
    func testMaxLengthTruncatesRenderedTitleButKeepsFullOutputForTooltipAndDiagnostics() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "max-length",
                run: "printf 'hello world'",
                interval: .manual,
                maxLength: 5
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        let snapshot = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "hello world"
        }

        XCTAssertEqual(item.renderedTitle, "hell\u{2026}")
        XCTAssertEqual(snapshot.fullOutput, "hello world")
        XCTAssertTrue(item.renderedToolTip?.contains("hello world") == true)
    }

    @MainActor
    func testMaxLengthTruncationPreservesGraphemeClustersInRenderedTitle() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "max-length-emoji",
                run: "printf '🇺🇸hi'",
                interval: .manual,
                maxLength: 2
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "🇺🇸hi"
        }

        // A naive UTF-16/scalar-based truncation would split the two-scalar
        // flag emoji; grapheme-cluster counting must keep it intact.
        XCTAssertEqual(item.renderedTitle, "🇺🇸\u{2026}")
    }

    @MainActor
    func testHideWhenEmptyHidesOnEmptySuccessAndRestoresOnLaterNonEmptySuccess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-hide-when-empty-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "hide-empty",
                run: "if [ -e '\(marker.path)' ]; then printf 'value\\n'; else printf ''; fi",
                interval: .manual,
                hideWhenEmpty: true
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.activate()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh && snapshot.fullOutput == ""
        }
        XCTAssertFalse(item.isVisible)

        try Data().write(to: marker)
        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value\n"
        }
        XCTAssertTrue(item.isVisible)
    }

    @MainActor
    func testHideOnErrorHidesCompletedFailureIncludingFirstRunAndRestoresAfterRecovery() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-hide-on-error-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "hide-on-error",
                run: "if [ -e '\(marker.path)' ]; then printf good; else exit 1; fi",
                interval: .manual,
                hideOnError: true
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.activate()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .error
        }
        XCTAssertFalse(item.isVisible)

        try Data().write(to: marker)
        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .fresh
        }
        XCTAssertTrue(item.isVisible)
    }

    @MainActor
    func testHideOnErrorAndHideWhenEmptyNeverHideAnItemBeforeItsFirstAttempt() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "pre-attempt",
                run: "sleep 0.3; exit 1",
                interval: .manual,
                hideWhenEmpty: true,
                hideOnError: true
            ),
            initiallyVisible: true
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        try await waitForRunning(item)
        // Still mid-flight with no completed execution yet: hide policies must not apply.
        XCTAssertTrue(item.isVisible)

        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.status == .error
        }
        XCTAssertFalse(item.isVisible)
    }

    @MainActor
    func testDisabledItemStaysVisibleButPreventsScheduledInitialManualClickAndActionExecution() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-disabled-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "disabled",
                run: "touch '\(marker.path)'; printf ran",
                interval: .manual,
                click: "touch '\(marker.path)'",
                actions: [ItemAction(title: "Run", kind: .command("touch '\(marker.path)'"))],
                disabled: true
            ),
            initiallyVisible: true
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        XCTAssertTrue(item.isVisible)

        item.refreshNow()
        item.processClick(eventType: .leftMouseUp)
        item.invokeAction(at: 0)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(item.isVisible)
        let snapshot = await item.runnerSnapshot()
        XCTAssertNil(snapshot.lastExecution)
    }

    @MainActor
    func testTogglingDisabledThroughLiveReloadCancelsActiveWorkWithoutLeakingChildProcess() async throws {
        let childPIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-disabled-reload-child-\(UUID().uuidString)")
        let command = "(trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait \"$child\""
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "disable-reload",
                run: command,
                interval: .manual
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: childPIDURL)
        }

        item.refreshNow()
        let childPID = try await waitForPID(at: childPIDURL)
        try await waitForRunning(item)

        await item.prepareUpdate(config: ItemConfig(
            name: "disable-reload",
            run: command,
            interval: .manual,
            disabled: true
        ))
        let gone = await waitUntilGone(childPID)
        XCTAssertTrue(gone, "toggling disabled left child process \(childPID) alive")
        item.commitPreparedUpdate()

        let snapshot = await item.runnerSnapshot()
        XCTAssertFalse(snapshot.isRunning)
    }

    @MainActor
    func testReEnablingADisabledItemThroughLiveReloadAllowsRefreshAgain() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "re-enable",
                run: "printf value",
                interval: .manual,
                disabled: true
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        try await Task.sleep(for: .milliseconds(100))
        var snapshot = await item.runnerSnapshot()
        XCTAssertNil(snapshot.lastExecution)

        await item.prepareUpdate(config: ItemConfig(
            name: "re-enable",
            run: "printf value",
            interval: .manual,
            disabled: false
        ))
        item.commitPreparedUpdate()

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value"
        }
        snapshot = await item.runnerSnapshot()
        XCTAssertEqual(snapshot.lastExecution?.stdout, "value")
    }

    @MainActor
    func testIconOnlyClearsDisplayedTitleWhenIconLoadsButKeepsFullTitleAndTooltip() async throws {
        let iconURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-icon-only-\(UUID().uuidString).png")
        try writeTestIcon(to: iconURL)
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "icon-only",
                run: "printf value",
                interval: .manual,
                icon: iconURL.path,
                iconOnly: true
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: iconURL)
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value"
        }

        XCTAssertEqual(item.renderedTitle, "value")
        XCTAssertEqual(item.renderedButtonTitle, "")
        XCTAssertTrue(item.renderedToolTip?.contains("value") == true)
    }

    @MainActor
    func testIconOnlyFallsBackToTextWhenConfiguredIconIsUnreadable() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "icon-only-missing",
                run: "printf value",
                interval: .manual,
                icon: "/nonexistent/path/to/pinchos-test-icon.png",
                iconOnly: true
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value"
        }

        XCTAssertEqual(item.renderedButtonTitle, "value")
    }

    @MainActor
    func testUnavailableSymbolFallsBackToTextWithoutCrashingIncludingIconOnly() async throws {
        let renderer = StatusItemIconRenderer(
            loadFileImage: { NSImage(contentsOfFile: $0) },
            loadSymbolImage: { _ in nil }
        )
        let item = ManagedItem(
            config: ItemConfig(
                name: "missing-symbol",
                run: "printf value",
                interval: .manual,
                symbol: "pinchos.definitely.not.a.real.symbol",
                iconOnly: true
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            iconRenderer: renderer,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value"
        }

        XCTAssertFalse(item.iconIsLoaded)
        XCTAssertEqual(item.renderedButtonTitle, "value")
        XCTAssertTrue(item.iconDiagnosticNote?.contains("unavailable") == true)
    }

    @MainActor
    func testKnownSymbolWithIconOnlyClearsDisplayedTitleThroughRendererSeam() async throws {
        let renderer = StatusItemIconRenderer(
            loadFileImage: { _ in nil },
            loadSymbolImage: { name in
                XCTAssertEqual(name, "chart.bar.fill")
                return NSImage(size: NSSize(width: 32, height: 32))
            }
        )
        let item = ManagedItem(
            config: ItemConfig(
                name: "symbol-only",
                run: "printf value",
                interval: .manual,
                symbol: "chart.bar.fill",
                iconOnly: true
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            iconRenderer: renderer,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value"
        }

        XCTAssertTrue(item.iconIsLoaded)
        XCTAssertEqual(item.renderedTitle, "value")
        XCTAssertEqual(item.renderedButtonTitle, "")
        XCTAssertNil(item.iconDiagnosticNote)
    }

    @MainActor
    func testIconSourceReloadPreservesIdentityTimerRunnerAndLastOutput() async throws {
        let scheduler = CommandScheduler()
        let iconURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-icon-reload-\(UUID().uuidString).png")
        try writeTestIcon(to: iconURL)
        let renderer = StatusItemIconRenderer(
            loadFileImage: { NSImage(contentsOfFile: $0) },
            loadSymbolImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }
        )
        let item = ManagedItem(
            config: ItemConfig(
                name: "reload-icon",
                run: "printf value",
                interval: .manual,
                icon: iconURL.path
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false,
            scheduler: scheduler,
            iconRenderer: renderer,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: iconURL)
        }

        item.activate()
        _ = try await waitForRuntimeSnapshot(item) { snapshot in
            snapshot.fullOutput == "value"
        }
        let outputBefore = try await waitForRuntimeSnapshot(item) { $0.fullOutput != nil }
        let executionBefore = await item.runnerSnapshot()
        let timersBefore = await scheduler.diagnostics().registeredTimers

        await item.prepareUpdate(config: ItemConfig(
            name: "reload-icon",
            run: "printf value",
            interval: .manual,
            symbol: "chart.bar.fill"
        ))
        item.commitPreparedUpdate()

        let outputAfter = await item.runtimeSnapshot()
        let executionAfter = await item.runnerSnapshot()
        let timersAfter = await scheduler.diagnostics().registeredTimers

        XCTAssertEqual(outputAfter.fullOutput, outputBefore.fullOutput)
        XCTAssertEqual(executionAfter.lastExecution?.stdout, executionBefore.lastExecution?.stdout)
        XCTAssertEqual(timersAfter, timersBefore)
        XCTAssertTrue(item.iconIsLoaded)
        XCTAssertEqual(item.commandConfig.iconSource, .symbol("chart.bar.fill"))
    }

    private func writeTestIcon(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "RecoveryLifecycleTests",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "failed to synthesize a test icon"]
            )
        }
        try png.write(to: url)
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
            domain: "RecoveryLifecycleTests",
            code: 13,
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

    @MainActor
    private func waitForRuntimeSnapshot(
        _ item: ManagedItem,
        matching predicate: (ItemRuntimeSnapshot) -> Bool
    ) async throws -> ItemRuntimeSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let snapshot = await item.runtimeSnapshot()
            if predicate(snapshot) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "runtime snapshot did not reach the expected state"]
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
    private func waitForActionRunning(_ item: ManagedItem, at index: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await item.actionSnapshot(at: index)?.isRunning == true {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "command action did not become active"]
        )
    }

    @MainActor
    private func waitForActionSkipped(_ item: ManagedItem, at index: Int) async throws -> CommandRunnerSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let snapshot = await item.actionSnapshot(at: index), snapshot.skippedRefreshes > 0 {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "repeated command action was not coalesced while active"]
        )
    }

    @MainActor
    private func waitForActionExecution(_ item: ManagedItem, at index: Int) async throws -> CommandRunnerSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let snapshot = await item.actionSnapshot(at: index), snapshot.lastExecution != nil {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: "command action did not finish"]
        )
    }

    @MainActor
    private func waitForClickExecution(_ item: ManagedItem) async throws -> ClickDiagnosticsSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let snapshot = await item.clickSnapshot(),
                snapshot.runner.lastExecution != nil,
                snapshot.lastCompletedAt != nil,
                !snapshot.runner.isRunning
            {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: "click command did not finish"]
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
    private func waitForFile(_ file: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "configured click action did not run"]
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

    func testMissingConfigWatcherDoesNotRetryPeriodicallyWhileFilesystemIsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue-51-idle-\(UUID().uuidString)", isDirectory: true)
        // Create a private empty ancestor so the watcher attaches here instead of
        // the shared system temp directory (which receives unrelated write events
        // from other tests and would force spurious reattach).
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let attempts = CallbackCounter()
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

        let counter = CallbackCounter()
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

        let counter = CallbackCounter()
        let attempts = CallbackCounter()
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

        let counter = CallbackCounter()
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
        let counter = CallbackCounter()
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

        let counter = CallbackCounter()
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
            let counter = CallbackCounter()
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
