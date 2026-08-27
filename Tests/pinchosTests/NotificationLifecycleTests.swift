import AppKit
import XCTest
@testable import pinchos
@testable import PinchosCore

@MainActor
private final class RecordingNotificationSink: ItemNotificationSink {
    private(set) var notifications: [ItemNotification] = []

    func send(_ notification: ItemNotification) {
        notifications.append(notification)
    }
}

@MainActor
private final class NotificationMenuDelegate: StatusItemMenuDelegate {
    func showLifecycleMenu(for statusItem: NSStatusItem) {}
}

@MainActor
private func waitForNotificationSnapshot(
    _ item: ManagedItem,
    where predicate: (ItemRuntimeSnapshot) -> Bool
) async throws -> ItemRuntimeSnapshot {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let snapshot = await item.runtimeSnapshot()
        if predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "NotificationLifecycleTests", code: 1)
}

@MainActor
private func waitForNotifications(
    _ sink: RecordingNotificationSink,
    count: Int
) async throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if sink.notifications.count >= count {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "NotificationLifecycleTests", code: 2)
}

final class NotificationLifecycleTests: XCTestCase {
    @MainActor
    func testFailureAndRecoveryNotificationsAreTransitionOrientedAndSurviveConfigUpdate() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-notification-\(UUID().uuidString)")
        let sink = RecordingNotificationSink()
        let item = ManagedItem(
            config: ItemConfig(
                name: "service-health",
                run: "count=$(cat '\(marker.path)' 2>/dev/null || echo 0); count=$((count + 1)); printf '%s' \"$count\" > '\(marker.path)'; if [ \"$count\" -eq 1 ]; then printf 'healthy'; elif [ \"$count\" -le 3 ]; then printf 'failure detail' >&2; exit 7; else printf 'recovered'; fi",
                interval: .manual,
                onError: .keepLast,
                notifyOn: [.failure, .recovery],
                notifyCooldown: 900
            ),
            menuDelegate: NotificationMenuDelegate(),
            initiallyVisible: false,
            notificationSink: sink,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in
            await item.tearDown()
            try? FileManager.default.removeItem(at: marker)
        }

        item.refreshNow()
        _ = try await waitForNotificationSnapshot(item) { $0.status == .fresh }
        XCTAssertEqual(sink.notifications, [])

        item.refreshNow()
        let failure = try await waitForNotificationSnapshot(item) { $0.status == .error }
        try await waitForNotifications(sink, count: 1)
        XCTAssertEqual(sink.notifications.map(\.event), [.failure])
        XCTAssertEqual(sink.notifications[0].itemName, "service-health")
        XCTAssertTrue(sink.notifications[0].body.contains("failure detail"))
        XCTAssertLessThanOrEqual(sink.notifications[0].body.count, 220)

        item.refreshNow()
        _ = try await waitForNotificationSnapshot(item) {
            $0.status == .error && $0.lastAttemptedAt != nil && $0.lastAttemptedAt != failure.lastAttemptedAt
        }
        try await waitForNotifications(sink, count: 1)
        XCTAssertEqual(sink.notifications.map(\.event), [.failure])

        await item.prepareUpdate(config: ItemConfig(
            name: "service-health",
            run: "count=$(cat '\(marker.path)' 2>/dev/null || echo 0); count=$((count + 1)); printf '%s' \"$count\" > '\(marker.path)'; if [ \"$count\" -eq 4 ]; then printf 'recovered'; else printf 'failure detail' >&2; exit 7; fi",
            interval: .manual,
            format: "{output}",
            onError: .keepLast,
            notifyOn: [.failure, .recovery],
            notifyCooldown: 900
        ))
        item.commitPreparedUpdate()

        item.refreshNow()
        _ = try await waitForNotificationSnapshot(item) {
            $0.status == .fresh && $0.fullOutput == "recovered" && $0.lastAttemptedAt != failure.lastAttemptedAt
        }
        try await waitForNotifications(sink, count: 2)
        XCTAssertEqual(sink.notifications.map(\.event), [.failure, .recovery])
        XCTAssertEqual(sink.notifications[1].itemName, "service-health")
    }

    @MainActor
    func testStalePresentationDoesNotEmitFailureNotification() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let sink = RecordingNotificationSink()
        let item = ManagedItem(
            config: ItemConfig(
                name: "stale-health",
                run: "printf healthy",
                interval: .manual,
                staleAfter: 60,
                notifyOn: [.failure, .recovery]
            ),
            menuDelegate: NotificationMenuDelegate(),
            initiallyVisible: false,
            now: { now },
            notificationSink: sink,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        _ = try await waitForNotificationSnapshot(item) { $0.status == .fresh }
        now = now.addingTimeInterval(60)

        let stale = await item.runtimeSnapshot()

        XCTAssertEqual(stale.status, .stale)
        XCTAssertTrue(sink.notifications.isEmpty)
    }

    @MainActor
    func testSuccessfulStructuredErrorStateDoesNotEmitFailureNotification() async throws {
        let sink = RecordingNotificationSink()
        let item = ManagedItem(
            config: ItemConfig(
                name: "reported-error",
                run: "printf '%s' '{\"version\":1,\"state\":\"error\",\"text\":\"degraded\"}'",
                interval: .manual,
                output: .jsonV1,
                notifyOn: [.failure, .recovery]
            ),
            menuDelegate: NotificationMenuDelegate(),
            initiallyVisible: false,
            notificationSink: sink,
            statusItemFactory: { nil }
        )
        addTeardownBlock { @MainActor in await item.tearDown() }

        item.refreshNow()
        let snapshot = try await waitForNotificationSnapshot(item) {
            $0.status == .error && $0.lastExecution?.exitCode == 0
        }

        XCTAssertNil(snapshot.outputDiagnostic)
        XCTAssertTrue(sink.notifications.isEmpty)
    }
}
