import Foundation

/// Fixed presentation policy for a cached command value.
///
/// Age is always `now - lastSuccessfulAt` against the *consumer's* interval
/// (`item.interval` or row `cache`). Shared-source consumers therefore agree
/// on the success timestamp and still diverge on freshness when their
/// intervals differ. Manual consumers pass a nil interval and do not age.
/// Command success in Pinchos is the only clock; this type never invents a
/// timestamp.
public struct ValueFreshness: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case unavailable
        case fresh
        case ageStale
        case refreshing
        case failedWithValue
        case failedWithoutValue
    }

    /// Trailing bar/menu markers. Text-presentation VS15 so they stay
    /// monochrome in the menu bar instead of emoji.
    public static let staleMarker = " ⌛︎"
    public static let warningMarker = " ⚠︎"

    public let state: State
    public let isAgeExpired: Bool
    public let isSchedulerDelayed: Bool

    public init(state: State, isAgeExpired: Bool, isSchedulerDelayed: Bool) {
        self.state = state
        self.isAgeExpired = isAgeExpired
        self.isSchedulerDelayed = isSchedulerDelayed
    }

    public var marker: String {
        switch state {
        case .ageStale:
            return Self.staleMarker
        case .refreshing:
            return isAgeExpired ? Self.staleMarker : ""
        case .failedWithValue, .failedWithoutValue:
            return Self.warningMarker
        case .unavailable, .fresh:
            return ""
        }
    }

    public var spokenState: String {
        switch state {
        case .unavailable:
            return "unavailable"
        case .fresh:
            return "fresh"
        case .ageStale:
            return isSchedulerDelayed ? "stale, scheduler delayed" : "stale"
        case .refreshing:
            return isAgeExpired ? "stale, refreshing" : "refreshing"
        case .failedWithValue:
            return "failed, showing last good value"
        case .failedWithoutValue:
            return "failed"
        }
    }

    public var runtimeStatus: ItemRuntimeStatus {
        switch state {
        case .unavailable:
            return .unavailable
        case .fresh:
            return .fresh
        case .ageStale:
            return .stale
        case .refreshing:
            return .running
        case .failedWithValue, .failedWithoutValue:
            return .error
        }
    }

    public func spokenDescription(valueText: String?) -> String {
        switch state {
        case .unavailable, .failedWithoutValue:
            return spokenState
        case .fresh, .ageStale, .refreshing, .failedWithValue:
            let trimmed = valueText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return spokenState
            }
            return "\(trimmed), \(spokenState)"
        }
    }

    /// Visible value for a submenu row. Never-attempted and in-flight rows
    /// without a last-good keep `Loading…`. A failed first attempt is `–`.
    public func rowValueText(current: String?) -> String {
        if let current, !current.isEmpty {
            return current
        }
        switch state {
        case .refreshing, .unavailable:
            return "Loading…"
        case .failedWithoutValue, .fresh, .ageStale, .failedWithValue:
            return "–"
        }
    }

    public static func interpret(
        value: String?,
        isRefreshing: Bool,
        lastSuccessfulAt: Date?,
        lastAttemptedAt: Date?,
        lastExecutionFailed: Bool,
        freshnessInterval: TimeInterval?,
        now: Date
    ) -> ValueFreshness {
        let isAgeExpired: Bool
        if let freshnessInterval, let lastSuccessfulAt {
            isAgeExpired = now.timeIntervalSince(lastSuccessfulAt) >= freshnessInterval
        } else {
            isAgeExpired = false
        }

        let hasLaterAttempt: Bool
        if let lastAttemptedAt, let lastSuccessfulAt {
            hasLaterAttempt = lastAttemptedAt > lastSuccessfulAt
        } else {
            hasLaterAttempt = lastAttemptedAt != nil && lastSuccessfulAt == nil
        }

        let isSchedulerDelayed = isAgeExpired && !isRefreshing && !lastExecutionFailed && !hasLaterAttempt

        let state: State
        if isRefreshing {
            state = .refreshing
        } else if lastExecutionFailed {
            state = value == nil ? .failedWithoutValue : .failedWithValue
        } else if value == nil {
            state = .unavailable
        } else if isAgeExpired {
            state = .ageStale
        } else {
            state = .fresh
        }

        return ValueFreshness(
            state: state,
            isAgeExpired: isAgeExpired,
            isSchedulerDelayed: isSchedulerDelayed
        )
    }
}
