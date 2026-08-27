import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

@MainActor
private final class StructuredOutputMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

@MainActor
final class StructuredOutputLifecycleTests: XCTestCase {
    func testJSONV1ProjectsTextTooltipStateVisibilityIconAndActions() async throws {
        let item = ManagedItem(
            config: ItemConfig(
                name: "quota",
                run: "printf '%s' '{\"version\":1,\"text\":\"81%\",\"tooltip\":\"Weekly quota\",\"state\":\"warning\",\"hidden\":true,\"actions\":[{\"title\":\"Refresh\",\"refresh\":true}]}'",
                interval: .manual,
                output: .jsonV1
            ),
            menuDelegate: StructuredOutputMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        let snapshot = try await waitForSnapshot(item) { $0.status == .warning }

        XCTAssertEqual(item.renderedTitle, "81% ⚠︎")
        XCTAssertEqual(item.renderedToolTip, "Weekly quota")
        XCTAssertFalse(item.isVisible)
        XCTAssertEqual(snapshot.structuredOutput?.actions, [ItemAction(title: "Refresh", kind: .refresh)])
    }

    func testMalformedJSONV1IsAnErrorWithUsefulDiagnostic() async throws {
        let item = ManagedItem(
            config: ItemConfig(
                name: "broken",
                run: "printf '%s' '{not json}'",
                interval: .manual,
                output: .jsonV1
            ),
            menuDelegate: StructuredOutputMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        let snapshot = try await waitForSnapshot(item) { $0.status == .error }

        XCTAssertTrue(snapshot.errorSummary?.contains("structured output") == true)
        XCTAssertTrue(item.renderedTitle.contains("⚠︎"))
    }

    func testJSONV1ActionsUseTheExistingCommandActionRunner() async throws {
        let item = ManagedItem(
            config: ItemConfig(
                name: "actions",
                run: "printf '%s' '{\"version\":1,\"text\":\"ready\",\"actions\":[{\"title\":\"Run\",\"run\":\"printf action\"}]}'",
                interval: .manual,
                output: .jsonV1
            ),
            menuDelegate: StructuredOutputMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        _ = try await waitForSnapshot(item) { $0.structuredOutput?.actions?.count == 1 }
        XCTAssertEqual(item.actions, [ItemAction(title: "Run", kind: .command("printf action"))])

        item.invokeAction(at: 0)
        let deadline = Date().addingTimeInterval(2)
        var actionSnapshot: CommandRunnerSnapshot?
        while Date() < deadline {
            actionSnapshot = await item.actionSnapshot(at: 0)
            if actionSnapshot?.lastExecution?.stdout == "action" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(actionSnapshot?.lastExecution?.stdout, "action")
    }

    func testPlainTextRemainsTheDefaultOutputMode() async throws {
        let item = ManagedItem(
            config: ItemConfig(
                name: "plain",
                run: "printf plain",
                interval: .manual
            ),
            menuDelegate: StructuredOutputMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        let snapshot = try await waitForSnapshot(item) { $0.fullOutput == "plain" }

        XCTAssertEqual(snapshot.status, .fresh)
        XCTAssertEqual(item.renderedTitle, "plain")
        XCTAssertNil(snapshot.structuredOutput)
    }

    func testTruncatedJSONV1IsRejectedByTheNormalCommandOutputBound() async throws {
        let item = ManagedItem(
            config: ItemConfig(
                name: "bounded",
                run: "printf '%s' '{\"version\":1,\"text\":\"this output is too large\"}'",
                interval: .manual,
                output: .jsonV1,
                maxOutputBytes: 16
            ),
            menuDelegate: StructuredOutputMenuDelegate(),
            initiallyVisible: false,
            scheduler: CommandScheduler(),
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        let snapshot = try await waitForSnapshot(item) { $0.status == .error }

        XCTAssertTrue(snapshot.lastExecution?.stdoutTruncated == true)
        XCTAssertTrue(snapshot.errorSummary?.contains("truncated") == true)
    }

    private func waitForSnapshot(
        _ item: ManagedItem,
        matching predicate: (ItemRuntimeSnapshot) -> Bool
    ) async throws -> ItemRuntimeSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let snapshot = await item.runtimeSnapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "StructuredOutputLifecycleTests", code: 1)
    }
}
