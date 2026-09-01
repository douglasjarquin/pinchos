import Foundation

/// Abstraction over monotonic time used by `CommandScheduler` so tests can
/// drive scheduling, coalescing, fairness, and wake behavior deterministically
/// instead of racing against wall-clock sleeps. Production code always uses
/// `SystemSchedulerClock`; `ManualSchedulerClock` is the test double.
public protocol SchedulerClock: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(until instant: ContinuousClock.Instant) async throws
}

public struct SystemSchedulerClock: SchedulerClock {
    private let clock = ContinuousClock()

    public init() {}

    public func now() -> ContinuousClock.Instant { clock.now }

    public func sleep(until instant: ContinuousClock.Instant) async throws {
        try await clock.sleep(until: instant)
    }
}

/// A single-shot settlement point shared between an actor-isolated "install
/// the continuation" step and a possibly-concurrent, non-isolated "resolve
/// it" call (a cancellation handler, a timer firing, or a permit becoming
/// available). Whichever side reaches `settle`/`install` first determines
/// the outcome; the loser is a safe no-op. This mirrors `EventRace` in
/// `CommandExecution.swift`, which solves the identical "cancellation may
/// race the continuation's installation" problem for process execution.
private final class SettleSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var pendingError: Error?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if settled {
            let error = pendingError
            lock.unlock()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func succeed() -> Bool { settle(error: nil) }

    @discardableResult
    func fail(_ error: Error) -> Bool { settle(error: error) }

    @discardableResult
    private func settle(error: Error?) -> Bool {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return false
        }
        settled = true
        pendingError = error
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return true }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
        return true
    }
}

/// Deterministic, manually-advanced clock for scheduler tests. Time never
/// moves except when a test calls `advance(by:)`, which resolves every sleep
/// whose deadline has been reached, in deadline order.
public final class ManualSchedulerClock: SchedulerClock, @unchecked Sendable {
    private let origin = ContinuousClock.now
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let slot: SettleSlot
    }
    private var waiters: [Waiter] = []

    public init() {}

    public func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return origin.advanced(by: elapsed)
    }

    public func sleep(until instant: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let targetElapsed = origin.duration(to: instant)
        guard !isAlreadyElapsed(targetElapsed) else { return }

        let id = UUID()
        let slot = SettleSlot()
        addWaiter(id: id, deadline: targetElapsed, slot: slot)

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    slot.install(continuation)
                }
            },
            onCancel: { [weak self] in
                slot.fail(CancellationError())
                self?.removeWaiter(id)
            }
        )
    }

    /// Advances virtual time by `duration` and resolves every pending sleep
    /// whose deadline has now been reached, in deadline order (earliest
    /// first) so ordering is deterministic for tests asserting fairness.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "ManualSchedulerClock only advances forward")
        lock.lock()
        elapsed += duration
        let due = waiters.filter { $0.deadline <= elapsed }.sorted { $0.deadline < $1.deadline }
        waiters.removeAll { $0.deadline <= elapsed }
        lock.unlock()
        for waiter in due {
            waiter.slot.succeed()
        }
    }

    private func removeWaiter(_ id: UUID) {
        lock.lock()
        waiters.removeAll { $0.id == id }
        lock.unlock()
    }

    private func isAlreadyElapsed(_ targetElapsed: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return elapsed >= targetElapsed
    }

    private func addWaiter(id: UUID, deadline: Duration, slot: SettleSlot) {
        lock.lock()
        waiters.append(Waiter(id: id, deadline: deadline, slot: slot))
        lock.unlock()
    }
}

/// One application-scoped scheduling and execution-bounding service shared
/// by every `ManagedItem`. It replaces per-item `DispatchQueue` +
/// `DispatchSourceTimer` pairs with a single shared deadline driver, and
/// bounds how many Pinchos-managed command sessions (scheduled refreshes,
/// manual refreshes, and declarative command actions) may be actively
/// running at once, regardless of how many items are configured.
///
/// Policy, in one place:
/// - **Bounded concurrency**: at most `maxActiveSessions` sessions run at
///   once, process-wide. Requests beyond that queue FIFO.
/// - **Fairness**: permits are granted strictly in request order. Combined
///   with the caller-side contract that each item may have at most one
///   outstanding permit request per work kind (see `ManagedItem`), no
///   single item or work kind can accumulate a growing share of the queue,
///   so every item is guaranteed bounded wait proportional to queue depth,
///   not to any other item's request rate.
/// - **Coalescing**: callers are expected to collapse a new request into an
///   already-outstanding one instead of enqueuing a second waiter; this
///   scheduler exposes `recordCoalesced()` purely for diagnostics.
/// - **Shared timing**: `registerRecurring`/`cancelTimer` maintain one
///   internal deadline set and one driver task, not one timer per item.
///   After a long sleep, a recurring registration's next deadline is
///   advanced past "now" in a single step instead of firing once per missed
///   interval.
public actor CommandScheduler {
    /// Opaque handle identifying one registration (a recurring timer or a
    /// permit-queue slot) so it can be cancelled later. Callers create their
    /// own token up front (rather than receiving one back from an async
    /// call) so registration/cancellation can be issued from synchronous
    /// call sites without forcing every `ManagedItem` lifecycle method to
    /// become `async`.
    public struct ItemToken: Hashable, Sendable {
        private let id = UUID()
        public init() {}
    }

    public struct Diagnostics: Equatable, Sendable {
        public let maxActiveSessions: Int
        public let activeSessions: Int
        public let queuedSessions: Int
        public let coalescedCount: Int
        public let delayedAcquisitions: Int
        public let registeredTimers: Int
    }

    /// `min(4, activeProcessorCount)` is a conservative baseline: enough
    /// parallelism that a handful of items never serialize behind each
    /// other, while keeping a many-item configuration from spawning dozens
    /// of concurrent shells, pipes, and blocking drain/wait workers at once.
    public static let defaultMaxActiveSessions = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

    static let allowedMaxActiveSessionsRange = 1...32

    /// The process-wide default instance used by production `ManagedItem`s
    /// that don't have one explicitly injected (mirrors `OutputMemoryBudget.shared`).
    public static let shared = CommandScheduler()

    private let clock: any SchedulerClock
    private var maxActiveSessions: Int
    private var activeSessions = 0
    private var coalescedCount = 0
    private var delayedAcquisitions = 0

    private struct Waiter {
        let id: UUID
        let slot: SettleSlot
    }
    private var waiters: [Waiter] = []

    private struct TimerEntry {
        var nextDeadline: ContinuousClock.Instant
        let interval: Duration
        let fire: @Sendable () -> Void
    }
    private var timers: [ItemToken: TimerEntry] = [:]
    private var driverTask: Task<Void, Never>?

    public init(clock: any SchedulerClock = SystemSchedulerClock()) {
        self.maxActiveSessions = CommandScheduler.defaultMaxActiveSessions
        self.clock = clock
    }

    init(maxActiveSessions: Int, clock: any SchedulerClock = SystemSchedulerClock()) {
        self.maxActiveSessions = Self.clamp(maxActiveSessions)
        self.clock = clock
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, allowedMaxActiveSessionsRange.lowerBound), allowedMaxActiveSessionsRange.upperBound)
    }

    // MARK: - Permits

    /// Acquires one of the bounded global permits, suspending in FIFO order
    /// if none are immediately available. Throws `CancellationError` if the
    /// calling task is cancelled before a permit is granted; in that case no
    /// permit is held and the caller must not call `releasePermit()`.
    public func acquirePermit() async throws {
        try Task.checkCancellation()
        if activeSessions < maxActiveSessions {
            activeSessions += 1
            return
        }
        delayedAcquisitions += 1
        let id = UUID()
        let slot = SettleSlot()
        waiters.append(Waiter(id: id, slot: slot))
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    slot.install(continuation)
                }
            },
            onCancel: { [weak self] in
                slot.fail(CancellationError())
                let scheduler = self
                Task { await scheduler?.removeWaiter(id) }
            }
        )
    }

    /// Releases a permit previously granted by `acquirePermit()`. Must be
    /// called exactly once per successful `acquirePermit()` call, after the
    /// complete owned command session (including any settlement the caller
    /// performs) has finished.
    public func releasePermit() {
        guard activeSessions > 0 else { return }
        activeSessions -= 1
        admitWaitersIfPossible()
    }

    /// Diagnostic-only: records that a caller collapsed a new request into
    /// one already outstanding (e.g. a scheduled tick arriving while the
    /// item's previous refresh is still waiting for a permit) instead of
    /// enqueuing a second waiter.
    public func recordCoalesced() {
        coalescedCount += 1
    }

    private func admitWaitersIfPossible() {
        while activeSessions < maxActiveSessions, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiter.slot.succeed() {
                activeSessions += 1
            }
        }
    }

    private func removeWaiter(_ id: UUID) {
        waiters.removeAll { $0.id == id }
    }

    // MARK: - Configuration

    func updateMaxActiveSessions(_ newLimit: Int) {
        maxActiveSessions = Self.clamp(newLimit)
        admitWaitersIfPossible()
    }

    public func diagnostics() -> Diagnostics {
        Diagnostics(
            maxActiveSessions: maxActiveSessions,
            activeSessions: activeSessions,
            queuedSessions: waiters.count,
            coalescedCount: coalescedCount,
            delayedAcquisitions: delayedAcquisitions,
            registeredTimers: timers.count
        )
    }

    // MARK: - Shared timing

    /// Registers (or replaces) a recurring deadline under `token`. Firing
    /// hops back through `fire` on every deadline; callers are responsible
    /// for re-entering their own isolation domain (`fire` runs on whatever
    /// executor the scheduler's single driver task happens to run on).
    public func registerRecurring(
        token: ItemToken,
        interval: TimeInterval,
        initialDelay: TimeInterval = 0,
        fire: @escaping @Sendable () -> Void
    ) {
        precondition(interval > 0, "recurring interval must be positive")
        let deadline = clock.now().advanced(by: .seconds(initialDelay))
        timers[token] = TimerEntry(nextDeadline: deadline, interval: .seconds(interval), fire: fire)
        restartDriver()
    }

    public func cancelTimer(_ token: ItemToken) {
        guard timers.removeValue(forKey: token) != nil else { return }
        restartDriver()
    }

    private func restartDriver() {
        driverTask?.cancel()
        guard !timers.isEmpty else {
            driverTask = nil
            return
        }
        driverTask = Task { [weak self] in
            await self?.runDriverLoop()
        }
    }

    private func runDriverLoop() async {
        while !Task.isCancelled {
            guard let nextDeadline = timers.values.map(\.nextDeadline).min() else { return }
            do {
                try await clock.sleep(until: nextDeadline)
            } catch {
                return
            }
            fireDueTimers()
        }
    }

    /// Fires every timer whose deadline has passed and advances each one's
    /// next deadline past `now` in a single step (rather than once per
    /// missed interval), so waking from a long sleep produces exactly one
    /// tick per recurring registration instead of replaying every interval
    /// that elapsed while asleep.
    private func fireDueTimers() {
        let now = clock.now()
        var due: [@Sendable () -> Void] = []
        for (token, entry) in timers {
            guard entry.nextDeadline <= now else { continue }
            due.append(entry.fire)
            var next = entry.nextDeadline.advanced(by: entry.interval)
            while next <= now {
                next = next.advanced(by: entry.interval)
            }
            var updated = entry
            updated.nextDeadline = next
            timers[token] = updated
        }
        for fire in due {
            fire()
        }
    }
}
