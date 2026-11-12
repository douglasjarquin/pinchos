import Foundation

public enum CommandSourceRefreshPolicy: Equatable, Sendable {
    case manual
    case scheduled(TimeInterval)
}

public struct CommandSourceConfiguration: Equatable, Sendable {
    public let command: String
    public let timeout: TimeInterval
    let maxOutputBytes: Int
    public let refreshPolicy: CommandSourceRefreshPolicy
    public let staleAfter: TimeInterval?

    public init(
        command: String,
        timeout: TimeInterval,
        refreshPolicy: CommandSourceRefreshPolicy = .manual,
        staleAfter: TimeInterval? = nil
    ) {
        self.init(
            command: command,
            timeout: timeout,
            maxOutputBytes: 64 * 1024,
            refreshPolicy: refreshPolicy,
            staleAfter: staleAfter
        )
    }

    init(
        command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        refreshPolicy: CommandSourceRefreshPolicy = .manual,
        staleAfter: TimeInterval? = nil
    ) {
        self.command = command
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.refreshPolicy = refreshPolicy
        self.staleAfter = staleAfter
    }
}

public protocol CommandSourceRunner: AnyObject, Sendable {
    func runIfIdle() async -> CommandRunOutcome
    func awaitSettledExecution() async -> CommandExecution?
    func cancelActive() async
    func snapshot() async -> CommandRunnerSnapshot
    func recordSkippedRefresh() async
}

extension CommandSourceRunner {
    public func recordSkippedRefresh() async {}
}

extension CommandRunner: CommandSourceRunner {}

public enum CachedValueState: String, Equatable, Sendable {
    case unavailable
    case refreshing
    case fresh
    case stale
    case error
}

public struct CachedValue: Equatable, Sendable {
    public let value: String?
    public let state: CachedValueState
    public let lastAttemptedAt: Date?
    public let lastSuccessfulAt: Date?
    public let lastExecution: CommandExecution?
    public let diagnostic: String?

    public init(
        value: String? = nil,
        state: CachedValueState = .unavailable,
        lastAttemptedAt: Date? = nil,
        lastSuccessfulAt: Date? = nil,
        lastExecution: CommandExecution? = nil,
        diagnostic: String? = nil
    ) {
        self.value = value
        self.state = state
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.lastExecution = lastExecution
        self.diagnostic = diagnostic
    }

    public var isRefreshing: Bool { state == .refreshing }
    public var isAvailable: Bool { value != nil }
}

public protocol CommandSourceClock: Sendable {
    func now() -> Date
}

public struct SystemCommandSourceClock: CommandSourceClock {
    public init() {}

    public func now() -> Date { Date() }
}

public actor CommandSource {
    /// Automatic retries of a failed or stale source wait this long after the
    /// last attempt before menu-open or `refreshIfDue()` may start more work.
    /// Explicit `refresh()` / Refresh Now bypasses the delay.
    public static let retryInterval: TimeInterval = 30

    private let configuration: CommandSourceConfiguration
    private let runner: any CommandSourceRunner
    private let scheduler: CommandScheduler
    private let clock: any CommandSourceClock
    private var cachedValue = CachedValue()
    private var runnerStarted = false
    private var generation: UInt64 = 0
    /// At most one in-flight execution. Additional `refresh()` callers join
    /// this task instead of appending waiters.
    private var inFlight: Task<CachedValue, Never>?
    /// At most one follow-up after the in-flight execution, set by
    /// `requestRefresh()` during a burst. Cleared when consumed or cancelled.
    private var pendingRefresh = false

    public init(
        configuration: CommandSourceConfiguration,
        scheduler: CommandScheduler = .shared,
        clock: any CommandSourceClock = SystemCommandSourceClock(),
        runner: (any CommandSourceRunner)? = nil
    ) {
        self.configuration = configuration
        self.scheduler = scheduler
        self.clock = clock
        self.runner = runner ?? CommandRunner(
            command: configuration.command,
            timeout: configuration.timeout
        )
    }

    public func snapshot() -> CachedValue {
        guard cachedValue.state == .fresh,
              let staleAfter = configuration.staleAfter,
              let lastSuccessfulAt = cachedValue.lastSuccessfulAt,
              clock.now().timeIntervalSince(lastSuccessfulAt) >= staleAfter
        else {
            return cachedValue
        }
        cachedValue = CachedValue(
            value: cachedValue.value,
            state: .stale,
            lastAttemptedAt: cachedValue.lastAttemptedAt,
            lastSuccessfulAt: cachedValue.lastSuccessfulAt,
            lastExecution: cachedValue.lastExecution,
            diagnostic: cachedValue.diagnostic
        )
        return cachedValue
    }

    /// Whether an automatic refresh should start now. Explicit Refresh Now
    /// bypasses this gate. Fresh values never auto-refresh; stale, failed
    /// (with or without a last-good value), and never-attempted sources are
    /// due only after `retryInterval` has elapsed since the last attempt.
    public static func isAutomaticRefreshDue(
        snapshot: CachedValue,
        now: Date,
        retryInterval: TimeInterval = CommandSource.retryInterval
    ) -> Bool {
        switch snapshot.state {
        case .refreshing, .fresh:
            return false
        case .stale, .error, .unavailable:
            guard let lastAttemptedAt = snapshot.lastAttemptedAt else { return true }
            return now.timeIntervalSince(lastAttemptedAt) >= retryInterval
        }
    }

    public func isAutomaticRefreshDue() -> Bool {
        Self.isAutomaticRefreshDue(snapshot: snapshot(), now: clock.now())
    }

    public func refresh() async -> CachedValue {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.performExclusiveRefresh() }
        inFlight = task
        return await task.value
    }

    /// Starts a refresh if one is not already running. A burst while a
    /// refresh is in flight records at most one follow-up instead of
    /// stacking tasks.
    public func requestRefresh() {
        if inFlight != nil {
            pendingRefresh = true
            return
        }
        let task = Task { await self.performExclusiveRefresh() }
        inFlight = task
    }

    public func refreshIfDue() async -> CachedValue {
        guard isAutomaticRefreshDue() else { return snapshot() }
        return await refresh()
    }

    var hasInFlightRefreshForTesting: Bool { inFlight != nil }
    var hasPendingRefreshForTesting: Bool { pendingRefresh }

    private func performRefresh() async -> CachedValue {
        generation &+= 1
        let refreshGeneration = generation
        let attemptedAt = clock.now()
        cachedValue = CachedValue(
            value: cachedValue.value,
            state: .refreshing,
            lastAttemptedAt: attemptedAt,
            lastSuccessfulAt: cachedValue.lastSuccessfulAt,
            lastExecution: cachedValue.lastExecution,
            diagnostic: cachedValue.diagnostic
        )
        do {
            try await scheduler.acquirePermit()
        } catch {
            return snapshot()
        }
        guard refreshGeneration == generation, !Task.isCancelled else {
            await scheduler.releasePermit()
            return snapshot()
        }
        runnerStarted = true
        let outcome = await runner.runIfIdle()
        let execution = await runner.awaitSettledExecution()
        runnerStarted = false
        await scheduler.releasePermit()
        guard refreshGeneration == generation,
              case .completed = outcome,
              let execution
        else { return snapshot() }

        let successful = execution.terminalReason == .exited(code: 0)
        cachedValue = CachedValue(
            value: successful ? execution.stdout : cachedValue.value,
            state: successful ? .fresh : .error,
            lastAttemptedAt: attemptedAt,
            lastSuccessfulAt: successful ? clock.now() : cachedValue.lastSuccessfulAt,
            lastExecution: execution,
            diagnostic: successful ? nil : Self.diagnostic(for: execution)
        )
        return snapshot()
    }

    private func performExclusiveRefresh() async -> CachedValue {
        defer { inFlight = nil }
        var value = await performRefresh()
        if pendingRefresh {
            pendingRefresh = false
            value = await performRefresh()
        }
        return value
    }

    public func cancel() async {
        generation &+= 1
        pendingRefresh = false
        inFlight?.cancel()
        await runner.cancelActive()
    }

    public func runnerSnapshot() async -> CommandRunnerSnapshot {
        await runner.snapshot()
    }

    public func recordSkippedRefresh() async {
        guard inFlight != nil, runnerStarted else { return }
        await runner.recordSkippedRefresh()
    }

    private static func diagnostic(for execution: CommandExecution) -> String {
        let stderr = lastTrimmedLine(of: execution.stderr)
        if !stderr.isEmpty { return stderr }
        switch execution.terminalReason {
        case .exited(let code): return "exited with code \(code)"
        case .signaled(let signal): return "terminated by signal \(signal)"
        case .timedOut: return "timed out"
        case .cancelled: return "cancelled"
        case .launchFailed(let message): return message.isEmpty ? "launch failed" : message
        }
    }
}
