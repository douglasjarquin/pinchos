import XCTest
@testable import PinchosCore

final class NotificationTests: XCTestCase {
    func testNotificationsAreOptInByDefault() throws {
        let item = try ConfigParser.parse("""
        [item.example]
        run = "check-status"
        """).items[0].command

        XCTAssertTrue(item.notifyOn.isEmpty)
        XCTAssertNil(item.notifyCooldown)
    }

    func testNotificationConfigurationIsRejectedByTheCanonicalSchema() throws {
        let toml = """
        [item.example]
        run = "check-status"
        notify_on = ["failure", "recovery"]
        notify_cooldown = "15m"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            XCTAssertTrue((error as? ConfigParseError)?.message.contains("unknown key") == true)
        }
    }

    func testNotificationTransitionsDeduplicateFailuresAndHonorCooldown() {
        let policy = ItemNotificationConfig(
            events: [.failure, .recovery],
            cooldown: 900
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var tracker = NotificationTransitionTracker()

        XCTAssertEqual(tracker.record(isFailure: true, at: start, policy: policy), .failure)
        XCTAssertNil(tracker.record(isFailure: true, at: start.addingTimeInterval(1), policy: policy))
        XCTAssertEqual(tracker.record(isFailure: false, at: start.addingTimeInterval(2), policy: policy), .recovery)
        XCTAssertNil(tracker.record(isFailure: true, at: start.addingTimeInterval(3), policy: policy))
        XCTAssertEqual(tracker.record(isFailure: false, at: start.addingTimeInterval(904), policy: policy), .recovery)
        XCTAssertEqual(tracker.record(isFailure: true, at: start.addingTimeInterval(905), policy: policy), .failure)
    }

    func testRejectsInvalidNotificationPolicyValues() {
        let invalidConfigs = [
            "notify_on = \"failure\"",
            "notify_on = [\"warning\"]",
            "notify_cooldown = 15",
            "notify_cooldown = \"0s\""
        ]

        for field in invalidConfigs {
            let toml = """
            [item.example]
            run = "check-status"
            \(field)
            """
            XCTAssertThrowsError(try ConfigParser.parse(toml), "expected \(field) to reject")
        }
    }
}
