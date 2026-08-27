import Foundation

public struct ItemNotificationConfig: Equatable, Sendable {
    public let events: Set<ItemNotificationEvent>
    public let cooldown: TimeInterval?

    public init(
        events: Set<ItemNotificationEvent> = [],
        cooldown: TimeInterval? = nil
    ) {
        self.events = events
        self.cooldown = cooldown
    }
}

public struct NotificationTransitionTracker: Equatable, Sendable {
    private var isFailed = false
    private var lastFailureNotificationAt: Date?

    public init() {}

    public mutating func record(
        isFailure: Bool,
        at date: Date,
        policy: ItemNotificationConfig
    ) -> ItemNotificationEvent? {
        if isFailure {
            guard !isFailed else { return nil }
            isFailed = true
            guard policy.events.contains(.failure) else { return nil }
            if let cooldown = policy.cooldown,
                let lastFailureNotificationAt,
                date.timeIntervalSince(lastFailureNotificationAt) < cooldown
            {
                return nil
            }
            self.lastFailureNotificationAt = date
            return .failure
        }

        guard isFailed else { return nil }
        isFailed = false
        guard policy.events.contains(.recovery) else { return nil }
        return .recovery
    }
}
