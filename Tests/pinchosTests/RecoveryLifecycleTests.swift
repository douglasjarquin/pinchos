import AppKit
import Darwin
import Foundation
import XCTest
@testable import PinchosCore
@testable import pinchos

@MainActor
private final class NoopStatusItemMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

final class RecoveryLifecycleTests: XCTestCase {
    @MainActor
    private func makeHeadlessItem(
        config: ItemConfig,
        initiallyVisible: Bool = true,
        scheduler: CommandScheduler = CommandScheduler(),
        iconRenderer: StatusItemIconRenderer = .system
    ) -> ManagedItem {
        ManagedItem(
            config: config,
            menuDelegate: NoopStatusItemMenuDelegate(),
            initiallyVisible: initiallyVisible,
            scheduler: scheduler,
            iconRenderer: iconRenderer,
            statusItemFactory: { nil }
        )
    }

    @MainActor
    func testManualItemRunsOnceOnActivationWithoutRegisteringATimer() async throws {
        let scheduler = CommandScheduler()
        let item = makeHeadlessItem(
            config: ItemConfig(name: "manual", run: "printf manual", interval: .manual),
            initiallyVisible: false,
            scheduler: scheduler
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.activate()
        let snapshot = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "manual" }

        XCTAssertEqual(snapshot.status, .fresh)
        XCTAssertEqual(item.renderedTitle, "manual")
        try await Task.sleep(for: .milliseconds(100))
        let diagnostics = await scheduler.diagnostics()
        XCTAssertEqual(diagnostics.registeredTimers, 0)
    }

    @MainActor
    func testManualRefreshKeepsLastGoodValueWhileNextRunIsActiveAndCoalescesOverlap() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-manual-refresh-\(UUID().uuidString)")
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "manual",
                run: "if [ ! -e '\(marker.path)' ]; then printf old; touch '\(marker.path)'; else sleep 0.3; printf new; fi",
                interval: .manual
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "old" }

        item.refreshNow()
        try await waitForRunning(item)
        item.refreshNow()
        _ = try await waitForSkippedRefresh(item)

        let running = await item.runtimeSnapshot()
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.fullOutput, "old")
        XCTAssertEqual(item.renderedTitle, "old")

        let settled = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "new" && !$0.isRunning }
        XCTAssertEqual(settled.status, .fresh)
        XCTAssertEqual(item.renderedTitle, "new")
    }

    @MainActor
    func testSuccessFailureAndRecoveryUseFixedLastGoodPolicy() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-recovery-\(UUID().uuidString)")
        let command = "count=$(cat '\(marker.path)' 2>/dev/null || echo 0); count=$((count + 1)); printf '%s' \"$count\" > '\(marker.path)'; if [ \"$count\" -eq 1 ]; then printf good; elif [ \"$count\" -eq 2 ]; then printf transient >&2; exit 7; else printf recovered; fi"
        let item = makeHeadlessItem(
            config: ItemConfig(name: "recovery", run: command, interval: .manual),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.refreshNow()
        let success = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "good" }
        let successDate = try XCTUnwrap(success.lastUpdatedAt)
        XCTAssertEqual(item.renderedTitle, "good")

        item.refreshNow()
        let failure = try await waitForRuntimeSnapshot(item) { $0.status == .error }
        XCTAssertEqual(failure.fullOutput, "good")
        XCTAssertEqual(failure.lastUpdatedAt, successDate)
        XCTAssertEqual(failure.lastExecution?.exitCode, 7)
        XCTAssertEqual(failure.errorSummary, "transient")
        XCTAssertEqual(item.renderedTitle, "good ⚠︎")

        item.refreshNow()
        let recovery = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "recovered" && $0.status == .fresh }
        XCTAssertNotEqual(recovery.lastUpdatedAt, successDate)
        XCTAssertEqual(item.renderedTitle, "recovered")
    }

    @MainActor
    func testFirstRunFailureHasDiagnosticsButNoSyntheticValue() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "failure",
                run: "printf 'first failure\\n' >&2; exit 9",
                interval: .manual
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        let state = try await waitForRuntimeSnapshot(item) { $0.status == .error }

        XCTAssertNil(state.fullOutput)
        XCTAssertNil(state.lastUpdatedAt)
        XCTAssertNotNil(state.lastAttemptedAt)
        XCTAssertEqual(state.lastExecution?.exitCode, 9)
        XCTAssertEqual(state.errorSummary, "first failure")
        XCTAssertEqual(item.renderedTitle, "– ⚠︎")
    }

    @MainActor
    func testRunningStateRecordsAttemptAndDoesNotInventOutput() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(name: "running", run: "sleep 0.3; printf done", interval: .manual),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        try await waitForRunning(item)
        let running = await item.runtimeSnapshot()

        XCTAssertEqual(running.status, .running)
        XCTAssertNotNil(running.lastAttemptedAt)
        XCTAssertNil(running.fullOutput)
        XCTAssertEqual(item.renderedToolTip, "Refreshing…")

        _ = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "done" }
        XCTAssertNil(item.renderedToolTip)
    }

    @MainActor
    func testLateOutputFromSameProcessGroupIsCommittedOnlyAfterSettlement() async throws {
        let item = makeHeadlessItem(
            config: ItemConfig(
                name: "late",
                run: "(sleep 0.3; printf 'late\\n') & exit 0",
                interval: .manual
            ),
            initiallyVisible: false
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        try await waitForRunning(item)
        let whileLingering = await item.runtimeSnapshot()
        XCTAssertTrue(whileLingering.isRunning)
        XCTAssertNil(whileLingering.fullOutput)

        let settled = try await waitForRuntimeSnapshot(item) { !$0.isRunning && $0.fullOutput != nil }
        XCTAssertEqual(settled.fullOutput, "late\n")
        XCTAssertEqual(item.renderedTitle, "late")
    }

    @MainActor
    func testRunChangeTerminatesLingeringDescendantAndRefreshesNewCommand() async throws {
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
        let childExitedAfterReload = await waitUntilGone(childPID)
        XCTAssertTrue(childExitedAfterReload, "reload left child process \(childPID) alive")
        item.commitPreparedUpdate()

        let snapshot = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "reloaded" }
        XCTAssertEqual(snapshot.status, .fresh)
        XCTAssertEqual(item.renderedTitle, "reloaded")
    }

    @MainActor
    func testShutdownTerminatesLingeringDescendant() async throws {
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
        defer { try? FileManager.default.removeItem(at: childPIDURL) }

        item.refreshNow()
        let childPID = try await waitForPID(at: childPIDURL)
        try await waitForRunning(item)

        await item.tearDown()

        let childExitedAfterShutdown = await waitUntilGone(childPID)
        XCTAssertTrue(childExitedAfterShutdown, "shutdown left child process \(childPID) alive")
    }

    @MainActor
    func testFormatAndIconChangesReuseLastOutputWithoutRerunningCommand() async throws {
        let counter = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-format-count-\(UUID().uuidString)")
        let command = "count=$(cat '\(counter.path)' 2>/dev/null || echo 0); count=$((count + 1)); printf '%s' \"$count\" > '\(counter.path)'; printf value"
        let renderer = StatusItemIconRenderer(
            loadFileImage: { _ in NSImage(size: NSSize(width: 1, height: 1)) },
            loadSymbolImage: { _ in NSImage(size: NSSize(width: 1, height: 1)) }
        )
        let item = makeHeadlessItem(
            config: ItemConfig(name: "format", run: command, interval: .manual, format: "old-{output}"),
            initiallyVisible: false,
            iconRenderer: renderer
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: counter)
        }

        item.refreshNow()
        _ = try await waitForRuntimeSnapshot(item) { $0.fullOutput == "value" }
        XCTAssertEqual(item.renderedTitle, "old-value")

        await item.prepareUpdate(config: ItemConfig(
            name: "format",
            run: command,
            interval: .manual,
            format: "new-{output}",
            symbol: "clock"
        ))
        item.commitPreparedUpdate()

        _ = try await waitForRuntimeSnapshot(item) { _ in item.renderedTitle == "new-value" }
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "1")
        XCTAssertNil(item.iconDiagnosticNote)
    }

    @MainActor
    private func waitForRuntimeSnapshot(
        _ item: ManagedItem,
        matching predicate: (ItemRuntimeSnapshot) -> Bool
    ) async throws -> ItemRuntimeSnapshot {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let snapshot = await item.runtimeSnapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "runtime snapshot did not reach expected state"]
        )
    }

    @MainActor
    private func waitForRunning(_ item: ManagedItem) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await item.runnerSnapshot().isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "item did not become active"]
        )
    }

    @MainActor
    private func waitForSkippedRefresh(_ item: ManagedItem) async throws -> CommandRunnerSnapshot {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let snapshot = await item.runnerSnapshot()
            if snapshot.skippedRefreshes > 0 { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "overlapping refresh was not coalesced"]
        )
    }

    @MainActor
    private func waitForPID(at url: URL) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let value = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "RecoveryLifecycleTests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for child PID"]
        )
    }

    @MainActor
    private func waitUntilGone(_ pid: Int32) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}
