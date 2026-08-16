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
    private func makeHeadlessItem(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate? = nil,
        initiallyVisible: Bool = true,
        now: @escaping () -> Date = Date.init,
        timerFactory: @escaping (DispatchQueue) -> DispatchSourceTimer = { queue in
            DispatchSource.makeTimerSource(queue: queue)
        }
    ) -> ManagedItem {
        ManagedItem(
            config: config,
            menuDelegate: menuDelegate ?? NoopStatusItemMenuDelegate(),
            initiallyVisible: initiallyVisible,
            timerFactory: timerFactory,
            now: now,
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
        let timerCreations = CallbackCounter()
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "manual",
                run: "printf manual",
                interval: .manual
            ),
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: false,
            timerFactory: { _ in
                _ = timerCreations.increment()
                let timer = DispatchSource.makeTimerSource()
                timer.resume()
                timer.cancel()
                return timer
            }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
        }

        item.activate()
        _ = try await waitForExecution(item)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(timerCreations.value, 0)
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
}
